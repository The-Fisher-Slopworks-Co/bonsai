#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f .env ]]; then
  echo "GITLAB_ROOT_PASSWORD=$(openssl rand -hex 16)Aa1!" > .env
fi
docker compose --env-file .env up -d
deadline=$(( $(date +%s) + ${WAIT_SECONDS:-1200} ))
until [[ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8929/users/sign_in)" == "200" ]]; do
  if (( $(date +%s) > deadline )); then echo "GitLab did not start in time" >&2; exit 1; fi
  sleep 10
done
echo "GitLab is up at http://localhost:8929"
