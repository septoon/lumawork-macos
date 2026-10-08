# lumawork-macos

Отвечай кратко и конкретно, по-русски. Сначала результат, затем проверки и следующие шаги.

- Это самостоятельное нативное macOS-приложение «Инженер», не Catalyst и не iPad app. Минимальная ОС — macOS 15.6.1, базовая машина — MacBook Air M1 / 8 ГБ.
- Начинай с `docs/superpowers/plans/2026-10-08-engineer-macos.md`, особенно с раздела передачи в новый чат. Все внесённые изменения, решения, результаты проверок и gaps сразу заноси в этот план.
- Проект независим: собственный `EngineerMac.xcodeproj` и `Packages/EngineerCore`. Никаких зависимостей от iOS checkout, изменения iOS-кода или копирования Secrets.xcconfig.
- Сохраняй прежние серверные контракты, бизнес-термины, raw values, правила фильтрации и расчётов. iOS/backend sources допустимы только как read-only reference; их путь указан в плане.
- До правки изучи реальный поток данных и существующие patterns. Исправляй причину; не переписывай рабочее и не добавляй ненужные абстракции, зависимости или skeleton screens.
- Перед переносом домена расширяй синтетические contract fixtures. Никаких реальных tokens, персональных данных или сетевых запросов из unit tests.
- Состояние сессии и сетевых данных принадлежит приложению; selection/filters/drafts — окну. Late responses должны проходить проверки user/epoch. Loading/offline/empty/error/auth — разные состояния.
- SwiftUI/AppKit UI должен быть нативным, компактным, semantic colors и доступным с клавиатуры. API macOS 26+ только с availability guards.
- После правок запускай минимальную релевантную проверку. Сборка не доказывает runtime, Touch ID, sandbox, multiwindow или производительность. Тяжёлые/визуальные проверки — только при необходимости.
- Сборка: `./scripts/build-macos.sh`; tests: `./scripts/test-engineer-core.sh`; запуск: `./script/build_and_run.sh` (также Codex Run).
- Commit/push, деплой, публикация, миграции и опасные операции — только по прямому поручению пользователя. Git remote: `https://github.com/septoon/lumawork-macos.git`. Пользователь поручил commit/push 08.10.2026; сохранять это разрешение для текущей реализации. В конце показывай status/diff и предлагай commit/push лишь когда это уместно.
