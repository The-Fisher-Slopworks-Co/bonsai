#!/bin/bash

# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The Fisher Slopworks Co

set -euo pipefail
cd "$(dirname "$0")"
URL=http://localhost:8929
API=$URL/api/v4
NAME=${1:-demo}
source .env

set_env() {
  local key=$1 value=$2
  grep -v "^$key=" .env > .env.tmp || true
  echo "$key=$value" >> .env.tmp
  mv .env.tmp .env
}

if [[ -z "${ROOT_TOKEN:-}" ]] || [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $ROOT_TOKEN" $API/user)" != "200" ]]; then
  ROOT_TOKEN="glpat-root$(openssl rand -hex 12)"
  docker compose --env-file .env exec -T gitlab gitlab-rails runner "
    t = User.find_by_username('root').personal_access_tokens.create!(scopes: ['api', 'sudo', 'admin_mode'], name: 'bonsai-seed', expires_at: 360.days.from_now) { |pat| pat.set_token('$ROOT_TOKEN') }
  " >/dev/null
  set_env ROOT_TOKEN "$ROOT_TOKEN"
fi
root() { curl -sf -H "PRIVATE-TOKEN: $ROOT_TOKEN" "$@"; }

root -X PUT "$API/application/settings?signup_enabled=false&allow_local_requests_from_web_hooks_and_services=true" >/dev/null

USER_ID=$(root "$API/users?username=bonsai" | jq '.[0].id // empty')
if [[ -z "$USER_ID" ]]; then
  USER_ID=$(root -X POST "$API/users" -d username=bonsai -d name=Bonsai -d email=bonsai@example.com \
    -d "password=$(openssl rand -hex 16)Aa1!" -d skip_confirmation=true | jq .id)
fi
if [[ -z "${BONSAI_TOKEN:-}" ]] || [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $BONSAI_TOKEN" $API/user)" != "200" ]]; then
  BONSAI_TOKEN=$(root -X POST "$API/users/$USER_ID/personal_access_tokens" -d name=Bonsai -d "scopes[]=api" \
    -d "expires_at=$(date -v+300d +%Y-%m-%d)" | jq -r .token)
  set_env BONSAI_TOKEN "$BONSAI_TOKEN"
fi
user() { curl -sf -H "PRIVATE-TOKEN: $BONSAI_TOKEN" "$@"; }

GROUP_ID=$(root "$API/groups?search=bonsai-test" | jq '[.[] | select(.path=="bonsai-test")][0].id // empty')
if [[ -z "$GROUP_ID" ]]; then
  GROUP_ID=$(root -X POST "$API/groups" -d name=bonsai-test -d path=bonsai-test -d visibility=private | jq .id)
fi
root -X POST "$API/groups/$GROUP_ID/members" -d user_id=$USER_ID -d access_level=50 >/dev/null 2>&1 || true

if ! docker compose --env-file .env exec -T runner test -s /etc/gitlab-runner/config.toml 2>/dev/null \
   || ! docker compose --env-file .env exec -T runner grep -q token /etc/gitlab-runner/config.toml; then
  RUNNER_TOKEN=$(root -X POST "$API/user/runners" -d runner_type=instance_type -d run_untagged=true -d description=bonsai-shell | jq -r .token)
  docker compose --env-file .env exec -T runner gitlab-runner register --non-interactive \
    --url http://gitlab:8929 --clone-url http://gitlab:8929 --token "$RUNNER_TOKEN" --executor shell >/dev/null
fi

OLD=$(user "$API/projects?search=$NAME&membership=true" | jq --arg p "bonsai-test/$NAME" '[.[] | select(.path_with_namespace==$p)][0].id // empty')
if [[ -n "$OLD" ]]; then
  user -X DELETE "$API/projects/$OLD" >/dev/null
  root -X DELETE "$API/projects/$OLD?permanently_remove=true&full_path=bonsai-test/$NAME" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $BONSAI_TOKEN" "$API/projects/$OLD")" == "404" ]] && break
    sleep 2
  done
fi
PROJECT_ID=$(user -X POST "$API/projects" -d name=$NAME -d path=$NAME -d namespace_id=$GROUP_ID \
  -d visibility=private -d initialize_with_readme=false | jq .id)

WORK=$(mktemp -d /tmp/bonsai-seed.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q -b main
git config user.name Seed && git config user.email seed@example.com && git config commit.gpgsign false
mkdir -p src tests scripts
cat > Makefile <<'MK'
.PHONY: test
test:
	sh tests/run.sh
MK
printf '#!/bin/sh\necho "setup done"\n' > scripts/setup.sh && chmod +x scripts/setup.sh
printf '#!/bin/sh\necho $(($1 + $2))\n' > src/add.sh
cat > tests/run.sh <<'SH'
#!/bin/sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL $1: expected $3, got $2"; fail=1; fi; }
check "add 2 2" "$(sh src/add.sh 2 2)" 4
check "add 1 5" "$(sh src/add.sh 1 5)" 6
[ $fail = 0 ] && echo "test result: ok" || { echo "test result: FAILED"; exit 1; }
SH
cat > .gitlab-ci.yml <<'CI'
test:
  script:
    - sh tests/run.sh
CI
printf 'Demo\n\nVersion: 1\n' > README.md
git add -A && git commit -qm "Initial commit"
BASE=$(git rev-parse HEAD)

git checkout -q -b feature/behind "$BASE"
echo "notes" > NOTES.md && git add -A && git commit -qm "Add notes"
git checkout -q -b feature/conflict "$BASE"
printf 'Demo\n\nVersion: 2-branch\n' > README.md && git commit -qam "Bump version on branch"
git checkout -q -b feature/failing-test "$BASE"
printf '#!/bin/sh\necho $(($1 - $2))\n' > src/add.sh && git commit -qam "Rewrite add"

git checkout -q main
printf 'Demo\n\nVersion: 2-main\n' > README.md && git commit -qam "Bump version on main"
echo "changelog" > CHANGELOG.md && git add -A && git commit -qm "Add changelog"

REMOTE="http://oauth2:$BONSAI_TOKEN@localhost:8929/bonsai-test/$NAME.git"
git push -q "$REMOTE" main feature/behind feature/conflict feature/failing-test 2>/dev/null
cd - >/dev/null

mr() { user -X POST "$API/projects/$PROJECT_ID/merge_requests" -d source_branch=$1 -d target_branch=main --data-urlencode "title=$2" >/dev/null; }
mr feature/behind "Add notes"
mr feature/conflict "Bump version"
mr feature/failing-test "Rewrite add"

set_env PROJECT_ID "$PROJECT_ID"
echo "$PROJECT_ID"
