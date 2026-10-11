# Bonsai — правила для Claude Code

Нативное macOS-приложение на Swift. Макеты — канвас Claude Design «Bonsai» (https://claude.ai/artifact/P1SAHFK3bHzvTYsAoiTokG; артборды и заметки по дизайну).

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

- После каждого изменения `xcodebuild build` и `xcodebuild test` проходят.
- Тексты интерфейса бери дословно из `BZ_STRINGS` в макетах, оба языка. Не придумывай новые формулировки, не добавляй подсказки и пояснения, которых нет в макетах.
- Следуй HIG: системные шрифты и цвета, стандартные контролы, стандартные размеры листов и алертов. Никаких кастомных «красивостей» сверх макетов.

## Запреты

- Не менять тесты, чтобы они прошли. Падает тест — чини код.
- Не отключать проверку TLS глобально, не хранить токен нигде, кроме Keychain, не логировать токен.
- Не делать `git push` в чужие репозитории. Живой GitLab для проверки только локальный, в Docker (`tests/gitlab/`). К рабочему GitLab пользователя не подключаться.
- Не добавлять TODO, закомментированный код, пустые заглушки «на потом». Нет функции — нет кнопки.
- Не трогать файлы вне папки проекта, кроме установки инструментов через Homebrew и Docker-томов.

## Команды

- Сборка: `xcodegen generate && xcodebuild -scheme Bonsai -configuration Debug build | tail -40`
- Тесты: `xcodebuild -scheme Bonsai test | tail -60`
- Запуск для ручной проверки: `open build/Debug/Bonsai.app` (путь из `project.yml`).

## Коммиты

Короткие, на английском, в настоящем времени: `Add GitLab client`, `Implement rebase stage`. Один коммит на законченный кусок работы.
