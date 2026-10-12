# Bonsai — rules for Claude Code

A native macOS app in Swift.

## Stack

- Swift 6, SwiftUI for all windows and sheets; AppKit only where SwiftUI can't (NSStatusItem for the menu bar, NSAlert when needed, Terminal via AppleScript).
- Minimum macOS 26, Xcode 27.
- The project is described in `project.yml` (XcodeGen); `.xcodeproj` is generated and not committed. If XcodeGen is unavailable, create the `.xcodeproj` once and commit it.
- Dependencies: Swift Package Manager only, and only when there is truly no way around them. GitLab API, git and Keychain are done in-house with URLSession, Process and Security.framework.
- Tests: Swift Testing (`import Testing`), target `BonsaiTests`. Network in tests is mocked via `URLProtocol`, git via temporary repositories in `/tmp`.

## Structure

```
Bonsai/
  App/            entry point, windows, menu bar
  Features/       per screen: Connect, Projects, MergeRequests, Settings, ProjectSettings, ClaudeFix
  Core/           GitLabClient, GitRunner, Pipeline (MR state machine), ClaudeRunner, Scheduler, Store
  Resources/      Localizable.xcstrings (ru, en), Assets
BonsaiTests/
```

The pipeline logic (`Core/Pipeline`) knows nothing about the UI and is fully covered by tests. The UI holds no business logic.

## How to work

- `tools/check.sh` passes before every commit.
- Code style is swift-format (`.swift-format`), unused code is caught by Periphery (`.periphery.yml`), compiler warnings are errors.
- An SPDX header in every new file that can hold a comment, otherwise `tools/check.sh reuse` fails. `REUSE.toml` covers only comment-less formats (JSON, Markdown, PNG, `.xcstrings`, `.swift-format`) and `Info.plist`, which XcodeGen overwrites. `#`-comment files get the same two lines with `#`:
  ```swift
  // SPDX-License-Identifier: AGPL-3.0-or-later
  // Copyright (C) 2026 The Fisher Slopworks Co
  ```
- Take UI texts verbatim from `BZ_STRINGS` in the mockups, both languages. Don't invent new wording, don't add hints or explanations that aren't in the mockups.
- Follow the HIG: system fonts and colors, standard controls, standard sheet and alert sizes. No custom embellishments beyond the mockups.

## Prohibitions

- Don't change tests to make them pass. A test fails — fix the code.
- Don't disable TLS verification globally, don't store the token anywhere but the Keychain, don't log the token.
- Don't `git push` to other people's repositories. A live GitLab for verification is local only, in Docker (`tests/gitlab/`). Don't connect to the user's work GitLab.
- Don't add TODOs, commented-out code, or empty "later" stubs. No feature — no button.
- Don't touch files outside the project folder, except installing tools via Homebrew and Docker volumes.

## Commands

- Gate: `tools/check.sh` = format + unused + reuse + test; a single step: `tools/check.sh format`.
- Pre-commit: `lefthook install` sets up a hook with the same gate; `LEFTHOOK=0 git commit` skips it once.
- Tools: `brew install xcodegen periphery lefthook`, `uv` for `reuse`.
- Formatting: `xcrun swift-format format -i --recursive Bonsai BonsaiTests tools/icon`.
- Build: `xcodegen generate && xcodebuild -scheme Bonsai -configuration Debug build | tail -40`
- Tests: `tools/test.sh`
- Run for manual testing: `open build.noindex/Debug/Bonsai.app` (path from `project.yml`).


## Definition of done

- **Issues and pull requests are written in English** — title and body, whatever language the task was discussed in.
- **Never commit to main.** Every task starts on a fresh branch off `origin/main`, named `<type>/<short-task>` — `fix/`, `feat/`, `refactor/`, `chore/`.
- **One task = one branch = one PR.** Past ~300 changed lines, split it into several PRs. `size:XL` or `size:XXL` means split the PR, not "explain why it is large".
- **PR title is the squash commit subject:** conventional commit with a scope, enforced by `.github/workflows/pr-title.yml`.
  - Type: `feat` `fix` `refactor` `chore` `docs` `test` `ci` `perf` `revert`.
  - Scope (required): a top-level `Bonsai/` module — `app` `core` `features` `resources` — or `tests` `tools` `deps` `github`. A new module means adding it to the `scopes:` list in that workflow.
  - Subject: lowercase start, imperative, no trailing period.
  - The body describes this PR alone, following the PR template.
- **No AI attribution.** No `Assisted-by:` / `Co-Authored-By: <LLM>` trailers and no "Generated with …" lines. The PR body becomes the squash commit body, so the PR title workflow fails a PR that carries one.
- **Before opening:** `tools/check.sh` green, then open the PR and report its URL.
- **Never merge locally.** Merging happens on GitHub, squash only.
