# Bonsai

A macOS menu bar app that keeps your GitLab merge requests rebased on their target branch: it runs the project's tests, pushes with `--force-with-lease` and watches CI. When tests or CI fail it can ask [Claude Code](https://claude.com/claude-code) for a fix, which is pushed only after you review the diff.

## Run it

Needs macOS 26 and Xcode 27, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen). `tools/check.sh` also needs [Periphery](https://github.com/peripheryapp/periphery) and [uv](https://docs.astral.sh/uv/).

```bash
brew install xcodegen periphery lefthook
lefthook install   # pre-commit runs tools/check.sh
xcodegen generate
xcodebuild -scheme Bonsai -configuration Debug build
open build/Debug/Bonsai.app
```

To try it without a real GitLab, start one in Docker with `tests/gitlab/up.sh`, seed a project with three merge requests with `tests/gitlab/seed.sh demo`, and connect to <http://localhost:8929> with `BONSAI_TOKEN` from `tests/gitlab/.env`.

## License

[AGPL-3.0-or-later](LICENSE)
