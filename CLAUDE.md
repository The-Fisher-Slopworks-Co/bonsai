# Bonsai — правила для Claude Code

Нативное macOS-приложение на Swift. Макеты — канвас Claude Design «Bonsai» артборды и заметки по дизайну).

## Стек

- Swift 6, SwiftUI для всех окон и листов; AppKit только там, где SwiftUI не умеет (NSStatusItem для строки меню, NSAlert при необходимости, Terminal через AppleScript).
- Минимальная macOS 26, Xcode 27.
- Проект описан в `project.yml` (XcodeGen); `.xcodeproj` генерируется и не коммитится. Если XcodeGen недоступен, создай `.xcodeproj` один раз и коммить его.
- Зависимости: только Swift Package Manager, и только если без них действительно нельзя. GitLab API, git и Keychain делаем сами на URLSession, Process и Security.framework.
- Тесты: Swift Testing (`import Testing`), таргет `BonsaiTests`. Сеть в тестах мокается через `URLProtocol`, git через временные репозитории в `/tmp`.

## Структура

```
Bonsai/
  App/            точка входа, окна, строка меню
  Features/       по экранам: Connect, Projects, MergeRequests, Settings, ProjectSettings, ClaudeFix
  Core/           GitLabClient, GitRunner, Pipeline (стейт-машина MR), ClaudeRunner, Scheduler, Store
  Resources/      Localizable.xcstrings (ru, en), Assets
BonsaiTests/
```

Логика пайплайна (`Core/Pipeline`) не знает про UI и полностью покрыта тестами. UI не содержит бизнес-логики.

## Как работать

- Перед каждым коммитом `tools/check.sh` проходит.
- Стиль кода — swift-format (`.swift-format`), неиспользуемый код ловит Periphery (`.periphery.yml`), предупреждения компилятора — ошибки.
- Лицензия всех файлов задаётся в `REUSE.toml`, SPDX-заголовки в файлы не добавляются.
- Тексты интерфейса бери дословно из `BZ_STRINGS` в макетах, оба языка. Не придумывай новые формулировки, не добавляй подсказки и пояснения, которых нет в макетах.
- Следуй HIG: системные шрифты и цвета, стандартные контролы, стандартные размеры листов и алертов. Никаких кастомных «красивостей» сверх макетов.

## Запреты

- Не менять тесты, чтобы они прошли. Падает тест — чини код.
- Не отключать проверку TLS глобально, не хранить токен нигде, кроме Keychain, не логировать токен.
- Не делать `git push` в чужие репозитории. Живой GitLab для проверки только локальный, в Docker (`tests/gitlab/`). К рабочему GitLab пользователя не подключаться.
- Не добавлять TODO, закомментированный код, пустые заглушки «на потом». Нет функции — нет кнопки.
- Не трогать файлы вне папки проекта, кроме установки инструментов через Homebrew и Docker-томов.

## Команды

- Гейт: `tools/check.sh` = format + unused + reuse + test; один шаг: `tools/check.sh format`.
- Pre-commit: `lefthook install` ставит хук с тем же гейтом; `LEFTHOOK=0 git commit` пропускает его один раз.
- Инструменты: `brew install xcodegen periphery lefthook`, `uv` для `reuse`.
- Форматирование: `xcrun swift-format format -i --recursive Bonsai BonsaiTests tools/icon`.
- Сборка: `xcodegen generate && xcodebuild -scheme Bonsai -configuration Debug build | tail -40`
- Тесты: `tools/test.sh`
- Запуск для ручной проверки: `open build/Debug/Bonsai.app` (путь из `project.yml`).

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
