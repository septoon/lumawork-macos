# «Инженер» для macOS — спецификация и план реализации

> **Актуальная задача / передача 08.10.2026:** минимальное окружение подготовлено, в новом чате пользователь поручил продолжить реализацию. Добавлены auth/storage/lifecycle основа этапа 2 и desktop shell этапа 3. Реальный SO login подтверждён пользователем и текущим UI. Добавлена первая рабочая часть этапа 4: маршрут POS/АРМ, локальный черновик, server send/reconciliation и архив; карта/ГСМ/топливо впереди. Прочитайте раздел 24 перед продолжением. Все изменения и проверки вносить в этот план. 08.10.2026 пользователь ответил «делай» на предложение первого локального commit и следующего desktop-shell этапа. Первый local commit выполнен. Позже 08.10.2026 пользователь создал `septoon/lumawork-macos` и прямо поручил связать проект, commit/push и продолжать работу. Публикация бинарника и VPS не поручены. Чекбоксы отмечаются по фактическому результату.
>
> **Приоритет уточнения:** приложение полностью отдельное и независимое, с тем же серверным контрактом. Указания ниже об извлечении shared code в iOS, common package обеих платформ и изменении iOS target являются исходной схемой и **заменены этим уточнением**; iOS/backend используются только read-only. Новые файлы принадлежат этому Mac-проекту.

**Цель:** создать самостоятельное нативное macOS-приложение «Инженер» с функциональным охватом существующего iOS-приложения, новым desktop UI и прежними серверными контрактами.

**Архитектура (уточнение пользователя 08.10.2026):** отдельное независимое приложение и репозиторий `/Users/tigrandarcinan/projects/github/luma-work/lumawork-macos`, native macOS target на SwiftUI с узкими AppKit-адаптерами. Собственный локальный Swift package `Packages/EngineerCore` внутри нового проекта. Прежние серверные контракты сохраняются; зависимости от iOS checkout и изменения его кода запрещены. Данные и сетевые задачи принадлежат сессии Mac-приложения; выборки, выделение и редакторские черновики — конкретному окну.

**Стек:** установленный Xcode 26.3; Swift в совместимом с существующим проектом языковом режиме; SwiftUI, AppKit, Foundation, Observation, Security, LocalAuthentication, WebKit, MapKit, Quick Look/PDFKit, UserNotifications, Charts, ImageIO/Vision по фактической необходимости.

**Спецификация:** разделы 1–16 этого же файла. Порядок реализации, файлы и проверки — разделы 17–23. Инвентаризация маршрутов — приложение A.

**Дата анализа:** 08.10.2026. **Read-only iOS baseline commit:** `051b022`; новый Mac Git-репозиторий пока без commits и remote. До создания документа рабочее дерево было чистым. Анализ касается локальных исходников и локальной копии backend; текущий production runtime и пользовательские данные в этой задаче не проверялись.

## 1. Обязательные ограничения

- Настоящий macOS target; не Mac Catalyst, не запуск iPad-приложения на Mac, не оболочка над сайтом и не Electron.
- Минимальная версия по требованию пользователя — **macOS Sequoia 15.6.1**. Базовая машина — **MacBook Air M1 (2020), 8 ГБ RAM**. На macOS 26 и новее поддерживается нативный Liquid Glass; функциональный охват на 15.6.1 сохраняется полностью.
- Не переносить iOS `ContentView`, `AppSidebarShell`, `AppScreen`, `AppCard` и жесты как desktop UI.
- Названия разделов, смысл полей, условия запросов, правила расчётов и доступы сохраняются.
- Серверные URLs, HTTP-методы, заголовки авторизации, JSON-ключи, enum raw values, формы файловой загрузки и SSE остаются прежними. Новые backend endpoints и миграции не являются частью этого проекта.
- **Заменено прямым указанием пользователя:** приложение независимое, без cross-repo зависимости и изменения iOS. Внутри Mac domain/transport implementation едины для всех Mac surfaces; parity с iOS доказывается fixtures/контрактными тестами. Требование единого package обеих платформ более не применяется.
- iOS source/project/package settings не изменять. Baseline iOS остаётся источником контрактов и parity reference; сборка iOS нужна при baseline, а не после каждой Mac-only правки.
- Никаких секретов в новом target, документах, тестовых fixtures или release-артефактах. `Secrets.xcconfig` не копировать в package/resources.
- Offline-состояние, пустой результат, загрузка, ошибка сети, отсутствие разрешения и истёкшая авторизация различаются.
- Сборка не считается доказательством работоспособности файловых диалогов, нескольких окон, Touch ID, подписания, фоновых загрузок или производительности.
- Не вводить новые бизнес-функции под видом desktop-адаптации: массовые серверные операции, глобальный поиск по всем доменам, новые отчёты, AI-tools и фоновый daemon не нужны для паритета.

### Принятые проектные решения

Минимальная ОС и визуальное направление заданы пользователем. Остальные параметры — предлагаемые решения реализации, а не факты о готовом приложении:

| Решение | Значение и причина |
| --- | --- |
| Минимальная ОС | macOS Sequoia 15.6.1; `MACOSX_DEPLOYMENT_TARGET = 15.6.1`. Новые API macOS 26 доступны только через availability guards |
| Оформление новых ОС | Системный Liquid Glass на macOS 26+; стандартное macOS-оформление на 15.6.1, те же данные, команды и плотность |
| Базовая машина | MacBook Air M1 (2020), 8 ГБ RAM; производительность и память проверять на этой конфигурации |
| Архитектуры | Apple Silicon и Intel, если все реально подключённые зависимости и подпись проходят проверку; Intel нельзя объявлять поддержанным по одному arm64 build |
| Основной target/scheme | `EngineerMac` в отдельном `EngineerMac.xcodeproj` внутри `lumawork-macos` (уточнение пользователя 08.10.2026) |
| Имя для пользователя | «Инженер»; отдельный proposed bundle ID `septon.LumaWork.mac`, регистрацию проверить перед подписанием |
| Начальный размер | около 1280 × 820 pt; минимальный рабочий размер 1000 × 640 pt с возможностью скрыть inspector/sidebar |
| Цветовая схема | система + светлая/тёмная настройки; визуальный ориентир — предоставленный screenshot Codex macOS |
| Дистрибуция | сначала локальный Debug, затем подписанный Developer ID `.app`/DMG; Mac App Store не является условием первого выпуска |
| Автообновление | в первый выпуск не добавлять сторонний updater: нет проверенного macOS update feed в прежних контрактах |
| Виджет | отдельный этап до объявления полного платформенного паритета; не блокирует промежуточный рабочий preview |

Не менять одновременно язык всех iOS-файлов на Swift 6. Сейчас в проекте `SWIFT_VERSION = 5.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, iOS deployment target 26.2. Перенос границ модулей проверять с учётом default isolation, явных `nonisolated` и видимости типов.

## 2. Что существует в проекте

### 2.1. Подтверждённая архитектура

На дату анализа в `LumaWork/LumaWork` 164 Swift-файла; 25 явно импортируют UIKit. Это только нижняя граница платформенных зависимостей: другие файлы могут использовать iOS-only SwiftUI modifiers, условно подключённые типы или сервисы из UIKit-файлов.

| Источник | Значение для macOS |
| --- | --- |
| `LumaWorkApp.swift` | UIKit app/scene delegates, Quick Actions, iOS background refresh и callback background URLSession; новый entry point обязателен |
| `AppRootView.swift` | bootstrap, авторизация, `AppDataStores`, сетевой статус, баннеры и deep links; логику отделить от view |
| `AppDataStores.swift` | единая композиция сервисов и stores на авторизованную сессию; основа для общей композиции, но не готовый desktop root |
| `ContentView.swift` | маршрутизация разделов плюс загрузка Home, связь пробега с топливом, публикация widget/voice snapshots, resume группового архива; side effects нельзя потерять при замене UI |
| `AppSidebarShell.swift` | 12 обычных разделов и условная «Админка», настройки, профиль, обратная связь, видимость разделов; общий enum сейчас смешан с iOS UI |
| `AppModels.swift`, `AppSupport/*` | модели, настройки origins, HTTP, форматирование, кеши и классификация ошибок; кандидаты для общего слоя после разборки зависимостей |
| `SimpleOneRequestsFeature/*`, `ClosedRequestsFeature/*` | отдельная SimpleOne-сессия, mapping, delta, XLSX, search indexes и detail caches; сохранять единые алгоритмы |
| `HomeFeature/*`, `FuelFeature/*`, `SalaryFeature/*` | существуют отдельные stores/services, но часть типов живёт в файлах с UI; извлекать по доменам |
| `FTPBackgroundDownloadManager.swift` | persistent transfer queue и background download URLSession; UIKit callback вынести в iOS адаптер |
| `NotificationSettingsFeature.swift` | настройки уведомлений, локальный координатор и iOS BackgroundTasks; не готовая APNs-система |
| `EngineerVoice/*`, `WidgetSnapshotPublisher.swift`, `LumaWorkWidget/*` | существуют read-only App Intents и виджет; учесть область пользователя и защищённые ответы |
| `deploy/lumawork-api/backend/src/*` | локальные validators/handlers для фиксации контрактов; каталог ignored, не доказательство текущего продакшена |

### 2.2. Что переиспользовать и что заменить

**Переиспользовать:** DTO, Codable/raw values, URL/query builders, фильтры SimpleOne, normalization, XLSX import/export, расчёты топлива/зарплаты/трудозатрат, адресные правила, нормализацию ИНН, сопоставление комментариев, серверные file APIs, SSE parser, snapshot schemas и incremental sync policy.

**Адаптировать:** Keychain, storage paths, file protection, image decoding/previews, lifecycle callbacks, системные уведомления, download destination bookmarks, speech capture и взаимодействие с URLSession.

**Написать заново:** окна, sidebar, desktop tables, toolbar/commands, inspectors, Settings scene, edit forms, файловые диалоги, preview и WebKit container. UI должен вызывать те же доменные операции, не повторять правила сервиса.

## 3. Визуальный язык и desktop-поведение

### 3.1. Утверждённое направление

Источники: screenshot Codex macOS пользователя и последняя концепция «Инженера» в его стилистике. Это визуальные ориентиры, а не runnable UI и не эталон точности пикселей/SF Symbols.

- Основной контент — белый в светлой теме, sidebar — слегка серый, selected row — нейтральная серая заливка.
- Графитовый основной текст, приглушённый вторичный текст, тонкие границы. Цветовые значения screenshot не становятся фиксированной палитрой для тёмной темы.
- Использовать semantic `Color.primary`, `.secondary`, system materials и macOS surface colors. Брендовые iOS `AppBackground*`/`AppCardSurface` не переносить на desktop.
- Контурные SF Symbols, небольшие toolbar controls; существующие изображения авто/оборудования и map icons остаются реальными assets.
- Без mobile hero-карточек, зелёных gradient pills, DepthStack, shimmer-title при pull-to-refresh и декоративной боковой icon rail Codex.
- Декоративный жёлтый кружок кнопки из raster-концепта не является требованием. В реализации главный action оформляется стандартным macOS button style и системным tint. Цвет ошибки/предупреждения остаётся семантическим.
- Базовый текст 13 pt, подписи 11–12 pt, заголовки секций 13–15 pt, название окна 17 pt. Не уменьшать текст до нечитаемого ради плотности.
- Строки простого списка 28–32 pt; двухстрочные записи 40–48 pt; контролы `.small`/`.regular` по контексту. Большие touch targets iOS не требуются.
- Отступы 8/12/16 pt; radius небольших controls системный, content regions около 6–10 pt только там, где отдельная поверхность нужна.
- Обычно одна таблица/поверхность с разделителями, а не карточка для каждой записи. Insets и density проверять в реальном окне, а не по imagegen-картинке.

### 3.2. Layout и адаптация ширины

| Область | Поведение |
| --- | --- |
| Sidebar | `NavigationSplitView` + `List(selection:)`, ширина примерно 200–260 pt, изменяемая/скрываемая; обычный системный highlight |
| Основная область | список/таблица и контент выбранного раздела, независимые от menu touch gestures |
| Inspector | 300–380 pt, скрываемый; `.inspector` в detail view либо `HSplitView`, если нужен независимый полноценный редактор |
| Узкое окно | скрыть inspector с доступной toolbar-командой; центральная таблица сохраняет номер/название и горизонтальный scroll, вторичные колонки можно скрыть |
| Широкое окно | больше реальных строк и полей, а не масштабирование шрифтов; не растягивать форму на весь экран |
| Fullscreen / несколько дисплеев | обычные системные окна, draggable titlebar и стандартные traffic lights; не рисовать chrome вручную |

Изменение ширины не теряет selection, фильтры, scroll position и черновик. При восстановлении окна координаты ограничиваются доступной областью существующих дисплеев. Стандартные возможности [`NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview) и [inspectors](https://developer.apple.com/videos/play/wwdc2023/10161/) предпочтительнее собственного оконного механизма.

### 3.3. Совместимость 15.6.1 и Liquid Glass 26+

В обеих ветках используется один native SwiftUI/AppKit интерфейс. Версия ОС меняет presentation, а не доступность разделов, порядок синхронизации, DTO, серверные payloads или количество помещающихся строк. Визуальный язык Codex сохраняется через монохромные иконки, спокойные поверхности и компактную типографику; оформление системного chrome определяется ОС.

| Поверхность | macOS 15.6.1 | macOS 26+ |
| --- | --- | --- |
| Sidebar, toolbar, sheets, popovers | штатные системные материалы и controls Sequoia | системное оформление Liquid Glass через стандартные containers/controls |
| Таблицы, формы, текст и PDF | читаемые обычные content surfaces | такие же content surfaces; не покрывать стеклом строки и поля массово |
| Основные кнопки | системные bordered/borderedProminent, компактный control size | стандартные кнопки; glass styles только там, где они улучшают конкретный action |
| Обоснованная custom overlay | штатная панель с системной границей/материалом | guarded `glassEffect`; только если обычного toolbar/popover недостаточно |
| Reduce Transparency / Increase Contrast | адаптивные системные цвета, читаемые границы | системная адаптация; для custom glass — непрозрачная читаемая fallback surface при Reduce Transparency |

- Компилировать современным SDK, но не поднимать minimum target до 26. Проверять deployment target Mac app, tests, extensions и всех подключённых packages. Generated `LSMinimumSystemVersion` основного bundle должен соответствовать 15.6.1; package minimum не выше этой версии.
- Вызовы новых APIs (`glassEffect`, `GlassEffectContainer`, glass button styles, `ToolbarSpacer` и другие фактически используемые новые modifiers) изолировать через `if #available(macOS 26.0, *)` и `@available` helpers. UI-adapter `LumaWorkMac/Platform/MacUICompatibility.swift` содержит только реально необходимые различия оформления; EngineerCore не знает о Liquid Glass.
- Начинать со стандартных `NavigationSplitView`, `List`, `Table`, toolbar и sheet. Не закрывать sidebar/toolbar непрозрачной заливкой и не имитировать стекло собственным blur на 15.6.1. Системные поверхности получают современное оформление при сборке новым SDK и запуске на новой ОС. [Apple: adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass).
- Custom glass не является обязательным этапом ради эффекта. Если обоснованная overlay содержит несколько близких glass elements, использовать один `GlassEffectContainer`; stable glass IDs нужны только для реального morph transition. Ограничить количество одновременно активных custom surfaces. [Apple: custom Liquid Glass views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).
- Reduce Motion отключает необязательные morph/scale transitions. Glass/glass-prominent не меняют доступность клавиатуры, focus rings, disabled states и читаемость текста. Increase Contrast проверяется вместе с обеими темами, статус остаётся понятным без цвета.
- Не использовать строку версии, модель Mac или server flag как переключатель UI. Availability проверяется на устройстве; настройки accessibility читаются через системные environment values. Отсутствие Liquid Glass на 15.6.1 не отображается как ошибка или ограничение аккаунта.
- Release проверяется реальным запуском на **15.6.1**, отдельно на **26+**. Запуск на новейшей ОС с низким deployment target не доказывает совместимость с Sequoia. На новых выпусках macOS проверять системное оформление повторно без обещания непроверенной совместимости будущих SDK.

## 4. Окна, состояние и навигация

### 4.1. Набор scenes

1. `WindowGroup("Инженер", id: "workspace")` — главное рабочее окно, появляется при обычном запуске; поддерживает ещё одно рабочее окно.
2. `Settings` — одно штатное окно настроек, `⌘,`; не destination в основном sidebar. [Apple Settings](https://developer.apple.com/documentation/swiftui/settings).
3. Отдельное detail-window — только для существующей сущности с устойчивым ID: заявка, сотрудник или статья. Открывается по явной команде «Открыть в новом окне», без копирования stores.
4. Preview/Quick Look — системная презентация выбранного файла. Полноценный `DocumentGroup` не нужен: приложение не является файловым редактором документов.
5. Обратная связь — отдельная utility scene/лист формы; одна форма на активный draft, без создания нового сообщения при каждом открытии.

Не добавлять MenuBarExtra, login item, XPC daemon или постоянный сервис в первой версии. Закрытие последнего окна не равно `⌘Q`: при работающем процессе transfer queue и согласованные session-level задачи могут продолжаться.

### 4.2. Владельцы состояния

| Состояние | Владелец и срок жизни |
| --- | --- |
| App auth, SimpleOne auth, конфигурация, session epoch | один app-level session container |
| Domain repositories, файловые кеши, transfer queue, обновление общих данных | app/session-level; одна операция на один ключ, не на каждое окно |
| Выбранный раздел, дата/тип маршрута, фильтры, sorting, выбранные IDs | scene/window-level; `@SceneStorage` для небольшого безопасного состояния |
| Unsaved editor draft, открытый popover, focus | window-local; содержимое чувствительных полей не сохранять в scene restoration |
| Видимость разделов, тема, последняя пользовательская папка | user-scoped preferences; bookmark хранить отдельно от обычного path |
| Разблокировка зарплаты/админки | window-local gate + app-level invalidation; не global boolean «разблокирован навсегда» |

**Критичный нюанс:** существующий `HomeRouteStore` владеет `selectedDate`, `workType` и `record`. Если разделить только windows, но использовать этот объект напрямую везде, изменение даты в одном окне изменит другой редактор. Для Mac вводится keyed repository `RouteDayKey(date, workType)` и отдельный draft/controller окна. Существующий iOS store может остаться façade над тем же сервисом; не ломать его поведение ради multiwindow.

Сетевые результаты принимаются только при совпадении auth epoch, app user и SimpleOne user. При logout/смене аккаунта все окна сбрасывают selection, закрывают защищённые previews и прекращают запросы прежней сессии. История окон не должна снова показать данные прежнего пользователя.

### 4.3. Menu bar и клавиатура

| Команда | Shortcut / правило |
| --- | --- |
| Новое рабочее окно | `⌘N`; в контексте редактора не переопределять этим создание бизнес-записи |
| Настройки | `⌘,` |
| Поиск в текущем разделе | `⌘F`, если поиск действительно поддержан доменом |
| Обновить | `⌘R`; один существующий refresh cycle, без дублирования запросов |
| Сохранить черновик | `⌘S` только в активном редакторе; не означает «Отправить отчёт» |
| Отправить маршрут / сообщение | `⇧⌘Return` в соответствующем контексте; обычный Return не отправляет маршрут |
| Скрыть/показать sidebar | стандартная macOS команда |
| Скрыть/показать inspector | отдельная команда «Вид», например `⌥⌘I` |
| Открыть выделенное | Return / double-click; в text field сохраняется текстовая семантика |
| Quick Look файла | Space при фокусе файлового списка, не перехватывать ввод в поле |
| Удалить | только при фокусе списка; destructive confirmation для удаляемых данных |
| Закрыть окно / приложение | штатные `⌘W` / `⌘Q`, с проверкой несохранённых editor drafts |
| Отмена | Escape закрывает popover/отменяет редактирование, не удаляет данные |

Команды маршрутизировать через focused values/actions активного окна. Нельзя обращаться к «последнему глобально выбранному ID». Menu items disabled объясняются состоянием, а shortcut не обходит auth/permission gate. Undo/Redo работают для локального редактирования текста/перестановки точек; серверный DELETE не становится Undo без существующего восстановительного контракта.

## 5. Паритет функций и новый UI по разделам

Названия sidebar сохраняются. Не создавать отдельные разделы «Документы», «График» или «ГСМ» только ради места: существующие вложенные сценарии остаются в своих областях. «Админка» видна по прежней роли/разрешениям; настройки видимости не дают доступ к запрещённым данным.

| Раздел | Существующий код / функции | Нативный macOS UI |
| --- | --- | --- |
| Главная | `HomeScreen`, `HomeRouteStore`, `RouteDayService`, route settings/archive/calendar, Apple/Yandex routes, заправка и отправка дня | компактная сводка, рабочий день, route table, docked point inspector; archive как отдельный browser |
| Мой рюкзак | `BackpackFeature`, `OfficeEquipmentFeature`, `BackpackPhotos`; ЗИП, личное оборудование, фото, карточки и копирование | list/table + preview/details; переключение существующих подрежимов локальным контролом, не global tabs |
| Сотрудники | `EmployeesScreen`, `SimpleOneEmployeesStore`, `WorkSchedule*`; каталог по населённому пункту, контакты, график | source list/таблица, карточка справа, компактный month schedule; фильтр города в toolbar |
| Авто | `VehicleFeature`, `VehicleDocumentsFeature`, `MaintenanceFeature`; автомобили, реквизиты/документы, ТО/затраты | vehicle list + detail form, maintenance table и document list; даты/деньги вводятся desktop controls |
| Топливо | `FuelScreen`, `FuelServiceStore`, `FuelSummarySupport`, `FuelAnalyticsSection`, `FuelImportFeature` | месяцы слева/фильтр периода, таблица операций, баланс/аналитика, inspector записи, импорт с preview |
| Помощник | `AssistantFeature/Store/API`, `WikiFeature`, local tools, история, attachments, speech, knowledge feedback | история разговоров + чат; Wiki search/results/article; компактный multiline composer, drag/drop файлов |
| FTP | `FTPFeature`, `FTPBackgroundDownloadManager`; удалённый каталог, favorites, breadcrumbs, ZIP папок, downloads/очередь | file browser table, path bar, favorites, preview, persistent transfer panel, Finder/save-panel actions |
| Зарплата | `SalaryScreen`, `SalaryServiceStore`, analytics, pay slips, `SalaryPasscodeLock` | защищённая таблица выплат и документов, monthly detail/analytics; native PIN field + Touch ID |
| Заявки | `ClosedRequestsScreen`, SimpleOne store/service, active/closed/warehouse modes, detail/browser, XLSX, comments, ИНН | tables + detail/inspector, локальные scopes/filters, сохранённый selection по stable ID |
| Координация | `CoordinationScreen/Store`, group active/closed, employee detail, cached pagination | инженерский список + заявки выбранного инженера/группы; pager и partial-load status, не nested mobile cards |
| Трудозатраты | `TimeReportFeature`, store, SimpleOne JSON/XLSX fallback, work/travel calculations | таблица по дням/периоду и итоговая строка; числовые колонки и export/save panel |
| Аналитика | `ClosedRequestsAnalyticsSupport*`, `ClosedRequestsAnalyticsScreen` | существующие агрегаты/графики и periods; desktop grid только для имеющихся метрик |
| Админка | users, overview/audit, images, GSM template/layout/projects, feedback, assistant, site, engineer files | отдельный локальный admin navigator внутри защищённого раздела: tables, editors, previews и permission-aware actions |

### 5.1. Главная и маршрут

- «Активные заявки»: Всего / Просрочено / Сегодня в небольшой строке; existing nearest-SLA request открывает actual request detail. Не создавать фиктивный список nearest requests.
- Date + «Тип работы»: локальные controls рядом с рабочим днём. В UI «POS»/«АРМ», в payload строго `POS`/`ARM`.
- Начальный/конечный пункт — local pop-up «Склад/Дом»; недоступный Дом при отсутствии адреса disabled. Адреса берутся из действующих settings.
- Intermediate stops — таблица с номером позиции, адресом, номером заявки и reorder grip. Только поля, реально доступные в этой записи; org/TID/reason не выдумывать из краткой строки.
- Existing point editor содержит адрес и номер заявки, actions «Отмена»/«Сохранить». Inspector — новая презентация этой же операции, не новый API.
- Reorder мышью + явные menu actions вверх/вниз для клавиатуры и accessibility; начальная/конечная точки защищены существующим правилом `canRemoveStop`.
- «Пробег дня», Apple mileage, archive, заправка и отправка доступны одновременно без огромных карточек. Числовой draft локален и валидируется прежним domain helper.
- Карта Apple — отдельная MapKit view для existing route snapshot; manual coordinate corrections, unverified points и cache version сохраняются. Не показывать карту только ради заполнения пространства.
- Яндекс — прежний URL builder/порядок остановок/параметры. macOS `NSWorkspace` открывает URL; embedded browser сохраняется, если требует текущего сценария. Не утверждать одинаковые дистанции Apple/Yandex.
- Archive включает прежний calendar/список дней, monthly odometer и вход к ГСМ. Calendar не должен запускать повторную загрузку каждого дня на hover/selection.
- Отправка отчёта остаётся отдельной явной операцией с прежним подтверждением, результатом и сверкой после потерянного ответа.
- При dirty draft смена даты/типа/окна/аккаунта предлагает сохранить локальные изменения, отменить действие либо отказаться от draft; не отправляет отчёт автоматически.

### 5.2. Заявки, координация, трудозатраты и аналитика

- Перенести existing active/closed/warehouse modes и поиск по прежним полям. Период, scopes, deadlines/SLA, критерии групп и city filters не ослабляются ради новой таблицы.
- Непустой поиск по закрытым заявкам проходит по всему доступному архиву, независимо от выбранного периода, в личном и групповом режиме. Обойти оба существующих period gates через общий effective-range helper; не ограничивать поиск загруженными строками текущего экрана. При неполном локальном архиве явно показать partial coverage и продолжить существующую синхронизацию.
- Display columns выбираются из actual `SimpleOneRequestRecord`/`ClosedRequestRecord`, полная карточка загружается existing detail request. Не заменять full description обрезанным list description.
- Устойчивое выделение по `sys_id`/domain stable ID, а не номеру строки в sorting; copy selected cells/номер/адрес через pasteboard. Произвольные массовые update/delete не вводить.
- Точный effective-date rule closed archive общий: для `returnEquip` использовать корректный `registeredAt`, иначе `closedAt`. Это влияет на группировку, поиск по периоду, статистику и голосовые ответы.
- Комментарии клиента, привязки address/terminal/ИНН и company lookup сохраняют exact matching и permissions. ИНН — строка, ведущие нули и длина не теряются.
- Нативная карточка заявки — данные/существующие actions; browser остаётся ограниченным fallback для тех операций SimpleOne, которые сейчас сделаны через веб. Не переписывать upstream API на предполагаемый endpoint.
- Групповой архив не загружается заново при переходе между окнами/разделами. Не терять checkpoint `nextPage`, `refreshedIDs`, `totalCount` и session guard.
- Трудозатраты: тот же JSON head check/full refresh/XLSX fallback и тот же расчёт Работа/Дорога. Display sort не влияет на исходную sync sorting.
- Аналитика строится на общем snapshot/index; не отдельным запросом с другими условиями. Данные большого периода вычисляются вне hot path SwiftUI body.

### 5.3. Авто, топливо, зарплата и документы

- Vehicle list сохраняет разделение действующего/других авто и привязку ТО к vehicle ID; реквизиты/документы редактируются прежними DTO.
- Fuel сохраняет отдельные заправки, fuel type по записи, выплаты, вычеты долга, carryover и стоимость. Не агрегировать несколько операций месяца в одну запись.
- Monthly mileage sync, currently запущенный в `ContentView`, переносится в application coordinator и имеет одного владельца. Отображение другого окна не запускает повторную запись.
- Формы допускают русскую десятичную запятую, пустое поле и отмену без сохранения; formatter отделён от transport number. Денежная математика не меняется при desktop-переносе.
- Fuel-import preview и commit — разные действия. До commit показываются реальные результаты разбора/дубли/коррекции; повторный клик не создаёт второй импорт.
- Salary сохраняет existing типы выплат, period month, расчёты и PDF/иные slips. Защищены таблицы, previews, export и меню, не только первый экран.
- Документы сотрудника/авто/зарплаты: native file importer/save panel, список metadata, Quick Look или PDFKit, открыть в стандартном приложении через локальный файл.
- Avatar/photo: исходные server manifests и matching rules, image preparation и size limits; новое фото берётся из выбранного файла/PhotosPicker, если доступен. Камеру не переносить через `UIImagePickerController`; direct camera capture — отдельный проверяемый macOS этап, не фальшивый disabled control.

### 5.4. Помощник, Wiki и FTP

- История conversation/messages хранится существующим backend и локальным user-scoped store. Выделенный разговор и composer draft принадлежат окну.
- SSE сохраняет existing parser/event semantics, `clientRequestId`, tool calls/approvals и remote history. Прервать соединение — не доказательство остановки server run; не добавлять выдуманный cancel endpoint.
- Markdown rendering переиспользует текущую зависимость после проверки macOS package product/platform minimum. Если потребуется замена, отдельно проверить ссылки, code blocks, text selection и существующие actions.
- Multiline chat: Return — отправка по привычному chat-поведению, Shift+Return — новая строка; при IME composing Return не отправляет. Обработка shortcut контекстная.
- Upload/drop/paste поддерживают существующие форматы; изображения подготавливаются ImageIO, preview — NSImage; PDF/OCR — PDFKit/Vision. Не уменьшать лимиты случайно при переписывании.
- Текущие лимиты image preparation: 1800 px и 4 MiB. Document preparer: 12 MiB файл, 5 MiB legacy DOC/XLS, 12000 извлечённых символов, 8 MiB archive entry, 30 PDF pages, 8 OCR pages, 6 worksheets. Использовать единственный общий набор, сверить source/server validators перед реализацией.
- On-device speech: сохранить реальную capability check для русского языка. `AVAudioSession` заменить Mac audio adapter; permission prompt только после действия пользователя. Текстовый ввод остаётся доступен при отказе/неподдерживаемом распознавании.
- Wiki использует собственный `WIKI_API_ORIGIN`/token, `/health`, `/search`, `/article/{id}`, `/pdf/{id}`; snapshot version invalidation сохранить. Не считать Wiki частью SimpleOne login.
- Wiki PDF URL может содержать token: не отдавать такой URL в браузер/логи. Скачать авторизованным клиентом в private temporary file, затем preview. Прежний network contract не меняется.
- FTP доступен по прежней app/SimpleOne authorization policy, но транспорт приложения — existing HTTPS proxy, не прямой FTP/SFTP-клиент.
- Каталог: name/type/size/date/path из actual response; breadcrumbs, favorites, root, search и downloads queue сохраняются. «Сохранить в Файлы» в Mac UI становится «Сохранить как…»; API и действие download не меняются.
- «Показать в Finder», drag наружу и открыть файл работают только для реально завершённого local download. Для remote item нельзя обещать Finder path до загрузки.

### 5.5. Админка, профиль и обратная связь

- Все текущие admin группы входят в финальный scope: overview/audit, users/permissions/block/delete/update email, images/catalog/requests, template/layout/projects ГСМ, feedback, assistant limits/settings, site/screenshots/order, engineer files/source editor.
- UI checks `AdminPermission`; сервер остаётся окончательным источником разрешения. При 403 показать запрет, не возвращать защищённый кеш как успешный ответ.
- Engineer files сохраняют различие Wiki snapshots/IPA/source metadata, read-only areas, выбор current snapshot, file editor и chunk upload. Desktop UI не разрешает то, что backend запрещает.
- Destructive actions выводят конкретный объект/период/подтверждение; bulk mailing и delete account не исполняются shortcut без confirmation.
- Profile, virtual card, fuel card, route settings, work documents и visibility preferences остаются существующими вложенными сценариями. QR строится из прежних данных; тип изображения меняется через adapter.
- Feedback — existing server draft → chunks → submit → additions; `clientRequestId` не меняется при retry. Файлы можно добавить drag/drop и file panel.
- `FeedbackDeviceInfo` сохраняет прежние JSON-ключи, но реальные values: macOS version вместо `iOS ...`, фактический Mac model, версия Mac-приложения. Никаких новых обязательных fields или fake device values.
- Автоматически захватывать экран не нужно. Пользователь прикладывает файл screenshot; системное screen recording permission запрашивается только при отдельной реализованной capture-функции.

## 6. Настройки и системные интеграции

Настройки группируются по существующим функциям: Аккаунт/SimpleOne, профиль, маршрут, ГСМ/топливная карта, уведомления, видимость разделов, оформление, безопасность. File destination — desktop-предпочтение для existing download workflow. Не добавлять SSH/server admin preferences, отсутствующие в iOS-приложении.

- Dark mode системный и принудительный, Increased Contrast/Reduce Transparency/Reduce Motion, VoiceOver и keyboard traversal.
- `AppBannerCenter`: временные messages через общий presenter Mac; permanent domain/auth/loading states остаются в содержимом. Alert для confirmation; error UI не превращать в notification spam.
- Local notifications — `UNUserNotificationCenter` после user permission; auth/dedup/business rules прежние. Отказ не блокирует работу приложения.
- Никаких обещаний новых заявок при завершённом процессе без существующего push-транспорта. Проверенные `/notifications/preferences` и `/notifications/events` сами по себе не являются регистрацией APNs-device.
- App Intents/Shortcuts: перенос существующего read-only каталога по реально поддержанным Mac APIs, без `ShortcutsLink` iOS UI. Защищённые данные требуют local auth, а вся выдача — актуальной user-scoped сессии. Не обещать свободную исходную Siri-фразу без supported dialogue/диктовки.
- Виджет: новый macOS WidgetKit target и собственная проверка App Group/provisioning. Не копировать entitlement `group.septon.LumaWork` механически: доступность группе для нового bundle ID проверяется. Read-only snapshot и route deep link, без записи данных из widget.
- Phone Quick Actions/вибрации/pull gestures заменяются commands/context menus; это platform presentation parity, а не утрата доменных функций.

## 7. Прежние серверные контракты

### 7.1. Три независимых сетевых контура

| Контур | Авторизация / поведение |
| --- | --- |
| LumaWork API | email code → token; `Authorization: Bearer <token>`, `/me`, `/api/v2/*`; прежний AppBuildIdentity headers |
| SimpleOne | `/auth/login`, `/user/me` относительно configured SO API origin; cookie `auth=<authKey>`; own Keychain/session и web cookie store |
| Wiki | отдельный configured origin + token; JSON endpoints и PDF; `health` без token по текущему клиенту |

Origins читаются через существующий `AppConfig`: окружение → Bundle → UserDefaults с прежним порядком resolution. Finder-запуск не наследует shell env: release имеет корректную несекретную конфигурацию в своём build. Placeholder `$(...)` не считается валидным origin. Invalid origin не должен превращать API-запрос в `file:///` и выглядеть как network outage.

Новый Mac target не использует iOS `Info.plist` с scene manifest, orientations, BGTask IDs и phone permissions. API settings и ключи configuration сохраняются отдельно; токены не хардкодятся в plist.

### 7.2. Инварианты transport и payload

- Точный method/path/query, percent encoding, dynamic IDs, accepted status codes, `records`/`user` envelopes, `null` и absent fields сохраняются.
- Отделить presentation labels от enum values; `АРМ` в интерфейсе не становится `АРМ` в `workType` JSON.
- Не заменять PUT на PATCH, не сериализовать Double как русскую строку, не выкидывать неизвестные optional fields из existing decoding path.
- Сохранить `X-LumaWork-Version`, `X-LumaWork-Build`; для scoped comments — существующий `X-LumaWork-Personal-Comments-Version: 2` в соответствующем клиенте.
- Передавать настоящий Mac version/build. Backend сейчас хранит единые `lastAppVersion/lastAppBuild/lastAppSeenAt` на пользователя, а рассылка outdated не разделена по платформам. Суффикс `-macos` не решает это: comparator убирает suffix. До публичного выпуска проверить поведение update-email и отобразить в Mac admin UI фактическое ограничение; не притворяться iOS-клиентом. Backend change для платформенной версии — отдельный запрос, вне этого плана.
- Прежние chunk envelopes/sequence/IDs/MIME/limits, PDF/download responses и SSE `Accept: text/event-stream` сохраняются.
- UUID/time-dependent fields golden-tests нормализуют только для сравнения; на wire сохраняется существующая семантика.
- 204 не decode-ить как обязательный JSON; legitimate empty/null не трактовать как auth failure.
- Раздельные cookie jars и hosts: app JWT/Wiki token не добавляются в произвольный web request или redirect.
- Retry GET/read допускается по нынешней policy; POST/PUT/DELETE/stream не повторяются вслепую. Не добавлять общий «автоматический retry всех запросов».
- Ошибки 401/403/404/429/5xx различаются; 404 FTP `FTP_FILE_NOT_FOUND` не превращать в пустой каталог; invalid response не кэшировать поверх валидного snapshot.
- Извлечение services не создаёт новый универсальный HTTP-client framework. Добавить URLSession injection в existing clients для тестов, сохранив production defaults.

### 7.3. Маршрут — пример contract-preserving операции

`RouteDayService.sendDay(_:date:)` отправляет `POST /api/v2/routes`; payload содержит `date`, `workType`, `distanceKm`, `periodStartOdometer`, `sent`, `stops`. Stop payload сохраняет `id`, `address`, `org`, `tid`, `reason`, `status`, `rejectReason`, `requestNumber`, `coordinateOverride` (`latitude/longitude` или null).

Статусы прежние: `В процессе`, `Выполнена`, `Отказ`. На локальном backend route key — user/date/workType; повторная отправка upsert-ит целый маршрут, stop IDs в response могут поменяться. Не привязывать выделение к server-generated stop ID при каждом reload без reconciliation.

При потерянном ответе сервис уже делает GET по дню/типу и сравнивает payload. Сохранить это; UI не должен заявлять «не отправлено» и запускать новую запись, пока сверка не завершена.

Полный endpoint inventory в приложении A — локальные declarations, не утверждение о доступности всех этих маршрутов в проде. Проверка release-кандидата выполняется прежними контрактами и без изменения сервера.

## 8. Общий слой и границы модулей

### 8.1. Структура репозитория

Новые пути относительно независимого `/Users/tigrandarcinan/projects/github/luma-work/lumawork-macos` (старые ссылки на iOS ниже являются reference, не build dependencies):

```text
Packages/EngineerCore/
  Package.swift
  Sources/EngineerCore/
    App/                 # config, session DTO, section enum, application coordinator
    Networking/          # existing HTTP/URL builders, error classification
    Persistence/         # snapshots, scoped keys, indexes, local version migration
    Requests/            # SO services/DTO, closed archive, comments, calculations
    Routes/              # DTO, service, storage, keyed Mac repository
    Fuel/ Salary/ Vehicles/ Equipment/ Employees/ WorkSchedule/
    Assistant/ Wiki/ FTP/ Documents/ Feedback/ Admin/
  Tests/EngineerCoreTests/
LumaWorkMac/
  App/EngineerMacApp.swift
  App/MacAppDelegate.swift
  App/MacSessionContainer.swift
  App/MacWorkspaceState.swift
  App/MacCommands.swift
  Views/MacRootView.swift
  Views/MacSidebarView.swift
  Settings/MacSettingsView.swift
  Features/<Domain>/...   # новый UI, выборки и draft controllers по разделам
  Platform/              # Keychain, filesystem/bookmarks, previews, browser, images,
                         # local auth, notifications, speech и app lifecycle
  Resources/Assets.xcassets
  Resources/Info.plist
  EngineerMac.entitlements
LumaWorkMacTests/
LumaWorkMacUITests/
scripts/test-engineer-core.sh
scripts/build-macos.sh
scripts/package-macos.sh
```

Это карта ответственности, не требование заранее создать все пустые папки/файлы. Создавать только фактические units ближайшего этапа. Для маленького домена service/models/store могут остаться одним файлом, если он не тянет UI и не смешивает платформенные обязанности.

### 8.2. Как переносить контракты в независимый проект

1. iOS/backend остаются read-only reference. Собственные models/services/parsers добавляются в Mac package по доменам после fixture assertions.
2. Нет общей runtime/build зависимости от iOS, импортов его target и symlinks наружу. Приложение собирается из содержимого `lumawork-macos`; исходный iOS checkout для сборки не требуется.
3. Names/raw values/DTO keys/query/method/header/retry/error semantics сохраняются. Mac UI вызывает одну реализацию package, не повторяет правила в views.
4. UIKit/phone-only lifecycle/file callbacks не переносить. Добавлять узкие Mac adapters по необходимости, без generic DI framework.
5. Config/version/build явно относятся к Mac app bundle; `Bundle.module` предназначен лишь package resources.
6. Public access и Swift actor boundaries проверяются реальными package tests и Mac build. iOS сохраняет исходный код и настройки.
7. Contract drift ловится golden fixtures, source fingerprints и domain parity checks; синхронное изменение двух разных репозиториев не является частью этой задачи.
8. Existing iOS regression harnesses — baseline evidence; actual Mac package XCTest запускается на его real sources, без вырезания функций из текста.

### 8.3. Ограниченный список платформенных seams

| Seam | Existing источник | Mac реализация |
| --- | --- | --- |
| Clipboard / open URL | `AppClipboard`, `UIApplication`, `UIPasteboard` | NSPasteboard, NSWorkspace, contextual copy |
| Image input/output | UIImage previews, `BackpackPhotos`, vehicle/avatar processing | данные/CGImage в core; NSImage только в Mac UI; ImageIO downsampling |
| QR | `AppSupport/AppFormattingQRCode.swift`, `ProfileVirtualCard` | общий payload/CoreImage, platform image wrapper |
| Documents | UIDocumentPicker/ShareSheet/QLPreviewController | NSOpenPanel/NSSavePanel, Quick Look/PDFKit, NSSharingServicePicker по необходимости |
| Web browser | UIViewRepresentable WKWebView | NSViewRepresentable WKWebView + explicit cookie store |
| Snapshot location/protection | `AppOfflineSnapshotStore`, `.protectionKey` | sandbox support directory, atomic write, permissions и sensitive-data policy |
| Lifecycle / archive pause | UIApplication begin/endBackgroundTask | session-owned Task, checkpoint, app sleep/wake/termination adapter |
| Downloads | UIKit completion handler в download manager | общий URLSession delegate/records + Mac destination/presentation lifecycle |
| Auth gate | faceID-only availability check | LAContext policy + Touch ID capability; own PIN fallback |
| Speech | `AVAudioSession` и iOS permissions | AVAudioEngine/Speech + Mac permissions/device changes |
| Haptics/keyboard dismissal | AppHaptics, UIKit responder action | убрать phone vibration/tap keyboard dismissal; оставить native focus |
| Feedback device info | UIDevice/systemVersion | ProcessInfo/mac hardware values в прежних полях |

Не делать `#if os(macOS)` по каждой UI-строке. Условия допустимы на малых SDK boundaries; полные view trees раздельные.

## 9. Кеши, синхронизация и несколько клиентов

### 9.1. Изоляция и сохранение

- Mac caches собственные: app container/Application Support, пространство current app user + current SimpleOne user/session там, где источник SO. iOS App Group files не «появятся на Mac» автоматически.
- Прежние snapshot Codable payloads сохраняются; при необходимости новый disk envelope имеет `schemaVersion` и явную migration. Сломанный файл не удалять сразу: isolate/quarantine, предложить reload без потери локального draft.
- Для Mac не использовать не-scoped key при отсутствующем userID для пользовательских данных. Persist user identity before hydrate, а при logout закрывать доступ к retained snapshot.
- Чтение кеша прежде сети, stamp последнего успешного обновления. Offline и partially-loaded не выдаются за свежий полный ответ.
- Atomic writes, serial writer, cancellation/generation checks; storage error отображается и не позволяет обещать «сохранено» после неудачной записи.
- Mac `.protectionKey` не даёт автоматически iOS Data Protection. Зарплатные snapshots, slips и чувствительные drafts должны иметь отдельную политику: encrypted-at-rest Mac storage с per-user Keychain key через CryptoKit, versioned envelope; previews расшифровываются временно. Не называть один PIN экрана шифрованием.
- Temp files живут в managed directory, очищаются после использования/на следующем старте с учётом открытых previews; текущий download не удаляется очисткой истории.
- Read-only/visible-state restore не хранит JWT, cookie, PIN, зарплату или текст документа в `@SceneStorage`/URL.

### 9.2. Сохранить sync policy заявок

См. существующий [CLOSED_REQUESTS_SYNC.md](../../../CLOSED_REQUESTS_SYNC.md). Перед переносом значения сверяются с текущими constants, а не только с историческим описанием:

- Начальное заполнение пустого архива — прежний XLSX bootstrap с baseline до выгрузки, затем delta.
- Watermark `(sys_updated_at, sys_id)`, narrow/wide scopes, sort и нужные `list-cell-value` запросы остаются прежними.
- Не останавливаться только потому, что встретился знакомый номер: существующая запись могла измениться.
- Manual XLSX import сохраняет upsert/сброс baseline/generation, не трактуется как mirror delete отсутствующих записей.
- Existing cadence 60/120/300 секунд и wide-check ограничение шесть часов не заменять агрессивным таймером на каждое окно. Если code constants изменились, брать code values и обновить plan reference.
- Existing head-check трудозатрат и периодический полный проход сохраняются; пользовательский refresh — прежний полный цикл.
- Одна in-flight sync на key/scope; ручной импорт, удаление архива и auto-refresh согласуются, поздний batch не перезаписывает новую generation.
- Локальное удаление архивной записи без server tombstone не гарантирует, что она не вернётся при повторной синхронизации; UI не обещает permanent server deletion.

### 9.3. Несколько окон и iOS/Mac одновременно

В одном процессе — единый repository и serial mutation по entity key. Editor draft содержит base fingerprint/version локального snapshot. Обновление данных другим окном не заменяет dirty draft; показать сравнение/предложить reload.

На разных устройствах сервер остаётся прежним. По исследованным контрактам нет общего ETag/CAS/version-precondition для всех writes. Preflight GET/fingerprint снижает риск, но между GET и PUT остаётся гонка. Поэтому:

1. Перед отправкой большого dirty route повторно прочитать день и сравнить с base, если сеть доступна.
2. При обнаруженном remote изменении показать conflict и выбор перечитать/явно отправить свой вариант; не silently merge суммы/остановки.
3. Не обещать строгую защиту от одновременной записи. Existing whole-route upsert может применить последний принятый вариант.
4. При потере ответа не плодить create: повторная read/reconciliation по existing IDs/request IDs. Для create без гарантированной idempotency показывать неопределённый результат до проверки, а не выполнять blind retry.
5. Не вводить общую offline очередь всех операций. Сохранить существующую route queue и pending mileage; в других доменах offline draft не означает успешно записанную server mutation.

## 10. Фоновая работа, sleep и transfer queue

### 10.1. Application coordinator

Перенести side effects из iOS `ContentView`/`AppRootView` в один app/session coordinator:

- restore auth, network status, initial Home loading;
- refresh active requests/closed delta/time reports по прежнему cycle;
- monthly mileage → fuel sync;
- group closed archive hydrate/resume/checkpoint;
- session invalidation и permission refresh;
- notification coordination и read-only widget/voice snapshots.

Window view сообщает active demand/выбранный scope, но не создаёт параллельные timers. При переходе между экранами shared task не отменяется только потому, что исчезла view.

### 10.2. macOS lifecycle policy

| Событие | Поведение |
| --- | --- |
| Window inactive | прекратить visible-only refresh, сохранить shared transfer; security gate может блокироваться по своей политике |
| Последнее окно закрыто | приложение остаётся обычным Dock app; ограниченные transfer/sync tasks продолжаются при работающем процессе |
| Sleep / потеря сети | checkpoint, остановка регулярного polling; после wake один catch-up с jitter/backoff, не replay всех timer ticks |
| Экран заблокирован | закрыть protected content/gates, остановить speech capture; фоновые несекретные transfers — по безопасной session policy |
| `⌘Q` | проверить drafts/active transfers; persist queue/checkpoints; не удерживать приложение бессрочно |
| Force quit / crash | восстановить persistent state на следующем launch; не обещать завершение произвольных Tasks вне процесса |
| Logout / auth expired | отменить сессионные writes/polls/streams, снять credentials, не публиковать результат старому/новому пользователю |

Для CPU/import задач использовать checkpoint и cooperative cancellation. `ProcessInfo` activity assertion допустим только на фактическую длительную операцию и заканчивается; не отключать sleep ради постоянного мониторинга.

### 10.3. FTP downloads

Использовать общие `FTPDownloadRecord`/states/delegate, но отдельный session identifier нового приложения и платформенную обработку presentation. Вызов `UIApplicationDelegate.handleEvents...` не переносится в Mac-код.

- Сверять persisted records с `URLSession.getAllTasks` после старта; не показывать задачу «загружается» навечно, если underlying task уже нет.
- Обрабатывать unknown Content-Length без fake progress, отмену, invalid/expired resumeData, недостаток места, duplicate filename и destination moved/disconnected.
- Temporary download file перемещается в controlled storage в callback до потери файла; external destination — отдельный безопасный export step.
- Не переносить ownership чужому аккаунту, не публиковать старые уведомления после logout.
- Background URLSession — механизм системных transfers, а не обещание любого поведения после force quit/при выключенном Mac. macOS lifecycle/relaunch проверяется отдельно на целевых ОС. [Apple background downloads](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).
- В первом runnable milestone приемлема truthful pause/resume/retry после relaunch. Нельзя выпускать UI с обещанием «скачается после выхода», если тест этого не подтвердил.

## 11. Файлы, sandbox и permissions

Базовый Mac build: App Sandbox с network client и user-selected read/write. Security-scoped bookmark entitlement добавляется по реальному bookmark workflow и проверяется в подписанном sandbox build. Не требуются network server, произвольный доступ к домашней папке, Full Disk Access или запуск внешних scripts.

1. File picker/drop получает URL; importer открывает доступ, читает/копирует во внутреннее временное хранилище и завершает scope корректно по способу получения URL.
2. Для возвращения к пользовательской папке после relaunch сохраняется bookmark, не raw path. При resolve stale bookmark обновляется; отказ/нет папки означает повторный выбор, не silent fallback в неизвестное место.
3. Save panel проверяет overwrite, имя, extension/content type, объём/место и отмену. Existing XLSX export сохраняется как файл, без clipboard/base64.
4. Path traversal/filename normalization/managed-delete boundary сохраняются. Симлинк наружу не делает внешнюю папку безопасной для recursive cleanup.
5. Quick Look/NSWorkspace получают local file URLs с правильным scope; file отсутствует — понятное состояние, повторная загрузка если доступна.
6. Открытый sensitive preview закрывается/очищается при logout/lock; URL с token не попадает в Finder или default browser.
7. Получение большого файла/загрузка chunks идут вне MainActor; полный base64 файл не дублируется в памяти без необходимости текущего контракта. Existing base64-chunk wire encoding сохраняется.

[Apple: доступ к файлам в App Sandbox и bookmarks](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox). Пример `startAccessing...`/`stopAccessing...` проверять отдельно для importer, native panels, drag/drop и сохранённого bookmark: баланс scope нельзя обеспечить слепым копированием одного шаблона.

**Permissions:** microphone/speech только для диктовки; camera только для реально реализованного capture; notifications только после соответствующего выбора. Отказ, restricted и отсутствующий hardware — нормальные states. Не добавлять phone `NSFaceIDUsageDescription` как средство включить Touch ID на Mac.

## 12. Авторизация, защищённые разделы и WebKit

### 12.1. App / SimpleOne sessions

- Общие session DTO/API, отдельные Mac Keychain namespaces и configured access policy. iOS `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` не копируется без проверки macOS Keychain API/поведения.
- Никаких login/password/token в UserDefaults/scene storage/log. Mac пароль SimpleOne вводится в SecureField; хранится только существующий auth credential по согласованной policy.
- App login не автоматически логинит SimpleOne. Если SO expired, недоступны именно его источники; authenticated LumaWork domains остаются доступны по своей сессии.
- Offline может открыть допустимый retained snapshot только подтверждённому local app identity; 401/403 не маскировать как «offline».
- «Выйти» отзывает app session прежним `/auth/logout`, очищает локальный доступ и останавливает tasks; потеря сети не должна оставлять UI с активным старым аккаунтом.
- При смене role/permissions до UI-action повторно проверять server result; снять admin gate на user/token changes.

### 12.2. Touch ID, PIN и privacy

- Mac security UI «Touch ID» только при реальной availability; системная `.deviceOwnerAuthentication` может использовать пароль Mac/поддерживаемый системный способ. [Apple LA policy](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication).
- Зарплатный 4-значный PIN и recovery через прежние email endpoints сохраняются как сценарий, но новый Mac PIN хранится в Keychain, не в plaintext `@AppStorage`.
- Existing gate/recovery выделить из `SalaryPasscodeLock.swift`; не переиспользовать phone keypad и `biometryType == .faceID` как Mac capability check.
- Cancel/failure/lockout не показывают защищённую view и не запускают export. Если Touch ID отсутствует, доступен понятный PIN/system fallback по действующей политике домена.
- Admin gate сбрасывается при выходе из раздела, потере app activity/lock, изменении токена/роли. Зарплатный gate также ограничен окном и lifecycle, не раскрывает соседние окна автоматически.
- Secure text selection/clipboard возможны только после unlock; protected меню, Shortcuts и Quick Look проходят тот же gate.
- Локальная разблокировка не заменяет server authorization и не даёт доступ offline после отказа сервера.

### 12.3. WebKit

Новый `MacSimpleOneBrowser` на NSViewRepresentable; для WebKit cookie установить на нужный domain/path до загрузки; не рассчитывать на автоматическое разделение URLSession-cookie и WKWebsiteDataStore.

Разрешённые исходные URLs строятся прежним builder. Redirect/new window/external links открываются с проверкой назначения; credentials не уходят на чужой host. Logout очищает соответствующие WebKit данные. Web details показывают loading/auth/error и back/forward; не применять JS patch, имитирующий новые upstream endpoints.

## 13. Производительность и доступность

- Для больших таблиц — lazy/виртуализируемая система, stable IDs, prepared indexes, debounced search и off-main filtering. Не сортировать/группировать весь архив в `body` каждой строки.
- Вначале использовать native `Table`. Если измерения на реальном объёме подтверждают проблему SwiftUI Table, заменить только этот список на `NSTableView` через узкий bridge, не всю app архитектуру.
- Domain DTO не содержат NSImage/UIImage. Thumbnail cache ограничен стоимостью/размером; downsample photo до display requirements, не декодировать исходный full image на каждой строке.
- Chart/analytics aggregation — общий calculator вне render path, cache по generation/filter; смена theme не запускает network refresh.
- Сохранять selection/scroll при delta, не `.id(UUID())` вокруг большой таблицы. Смену sort не считать сменой auth/cache generation.
- В UX отличать удалённый ответ, ещё загружаемый кеш и полный snapshot; не блокировать всё окно spinner, когда список уже доступен.
- Test datasets: 1k/12k/50k синтетических записей, long names/addresses, same timestamps, null/empty, строки кириллица/emoji, большие PDF/фото и многомегабайтные downloads. Это контрольные объёмы, не заявленный размер живой базы.
- Начальные цели, подлежащие измерению: shell из кеша примерно ≤1 сек на reference Mac; local filter 12k записей ≤150 мс без MainActor stall; typing/scroll без заметных hangs; steady memory не растёт линейно от каждой перезагрузки. Эти числа не являются результатом тестов.
- Reference Mac — MacBook Air M1 с 8 ГБ RAM. Проверять memory pressure, освобождение preview/thumbnail ресурсов после закрытия, два рабочих окна и параллельную загрузку/SSE. На macOS 26+ отдельно сравнить scroll и память с системным glass и custom overlay: стекло не оправдывает потерю отзывчивости. Не хранить в памяти все изображения/PDF или второй полный архив для каждого окна.
- Замер отделяет network latency от cache decode/render/aggregation. Только проблемный сценарий запускается в Instruments; для каждого screen нужен targeted runtime check, а не обязательный многочасовой profiling всего приложения.
- Keyboard Tab/Shift-Tab, focus rings, VoiceOver labels/selection, Increase Contrast и Reduce Transparency проверяются; статус не передаётся одним цветом.
- Не ломать стандартные Edit/Copy/Paste/Select All/Services/context menus ради собственных shortcuts. Скрытая колонка не скрывает единственный путь к данным или actions.

## 14. Локализация, время и числовые значения

- Русские бизнес-термины остаются точными; системные menu labels/localization оформляются штатно. Не изменять глобально `AppleLanguages`/`AppleLocale` всего desktop процесса как обход локализации.
- UI uses Russian locale; server ISO date keys/UTC timestamps и existing explicit timezone conversions сохраняются. `Calendar.autoupdatingCurrent` в текущих helper-ах не заменяется произвольным UTC без regression tests.
- Проверить сутки/месяц/год, timezone Mac, выбранный рабочий день и SO timestamps отдельно. Смена системной зоны не должна переносить route storage key прошлого дня или менять archived request count незаметно.
- Leading-zero IDs/ИНН/TID/VIN/request numbers — строки. Валюта/литры/km — текущие types и rounding, а не форматированный текст на wire.
- Десятичная запятая/точка, вставка из Excel с пробелами/nonbreaking space, empty/negative/overflow и отмена — целевые input cases. Existing validation/maximum constraints сохраняются.
- Privacy logs редактируют token/cookie/code/base64 и URL query tokens, а также персональные payload fields; current network logger печатает URL и некоторые bodies, поэтому Mac safe logging boundary нужен до подключения private-data workflows.

## 15. Сборка, подпись и выпуск

- Отдельный Info.plist/entitlements/scheme; development signing и release signing — разные configurations. Team/Keychain rights/Developer ID availability проверить, не предполагать по iOS signing.
- Native product — `.app` с `Contents/MacOS`, Resources и правильным icon набором. Existing mac icon в Assets существует; проверить размеры и отдельный asset catalog, не рисовать новый бренд без запроса.
- iOS build scripts/SideStore `source.json` и IPA pipeline остаются iOS-only. Mac release не публиковать как IPA и не менять источник SideStore ради Mac.
- Developer ID + Hardened Runtime, timestamp, подпись вложенных code bundles, notarization через notarytool, stapling и Gatekeeper assessment. [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- Не отключать library validation/JIT/ATS/sandbox «чтобы работало». Если пакет требует entitlement, обосновать его реальным code path и отдельной проверкой.
- ZIP/DMG версия соответствует app version/build и release notes; checksums; download/reinstall/clean Mac quarantine запуск. Архив, подпись, notarization и публичный download — четыре отдельных результата.
- До публичного релиза: подтвердить min macOS и обе заявленные архитектуры, network origins, account isolation, sandbox file paths, Touch ID fallback, и конфликт server lastAppVersion/email-updates.
- Если подписанный release требует unavailable certificate/account, сохранить локальный build/план, указать конкретный blocker. Нельзя объявить нотариальный выпуск готовым по ad-hoc signature.
- Текущее разрешение — только создать план. Выполнение серверных write-smokes, массовых email, публикация/настройка аккаунтов, commit/push/deploy требуют отдельного пользовательского поручения.

## 16. Сложные сценарии, которые нельзя потерять

| Условие | Ожидаемое поведение |
| --- | --- |
| Login A → late result → Login B | ответ A отбрасывается; cache/files/selection B не меняются |
| Два окна выбирают разные даты POS/ARM | независимые drafts, общий keyed repository; дата другого окна не переключается |
| iOS изменил маршрут во время Mac draft | обнаруженный конфликт не перезаписывается молча; отсутствие server CAS прямо учитывается |
| Ответ POST потерян | reconciliation до retry, existing route verification; не считать запись несуществующей автоматически |
| 401 после успешного cached load | auth-required, остановка запрещённых tasks, не успешный fallback из кеша |
| 429/5xx при автообновлении | backoff, сохранение last good snapshot, один owner/timer |
| Manual XLSX import во время delta | mutex/generation; импорт не затирается поздней страницей |
| Возврат ТО на границе месяца | grouping/filter/analytics/voice используют тот же effective-date helper |
| Partial group archive + закрытие окна | checkpoint сохранён; при возврате сразу кеш и resume |
| Sleep → wake → сеть недоступна | один корректный recovery cycle, не десятки накопленных запросов |
| Cancel download рядом с completion | один итоговый state, сохранённый local file не удаляется случайно |
| Bookmark stale / внешняя папка исчезла | запрос повторного выбора; internal finished download остаётся доступным |
| Недостаток места / corrupted snapshot | понятная ошибка хранения, no false success, последний валидный файл сохранён |
| Смена permissions с открытой админкой | gate/cache actions invalidated; server 403 не обходится |
| Нет Touch ID / отказ microphone/notifications | сохранена доступность основных функций, явный supported fallback |
| Закрытие dirty editor / `⌘Q` | save-local/discard/cancel без незаметной отправки на сервер |
| Widget/Shortcuts после logout | защищённые ответы и старые snapshots не возвращаются |
| Local delete архива + обновление | восстановление server записи допускается прежней семантикой; permanent deletion не обещается |

## 17. Этапы реализации и зависимости

Одна завершённая вертикальная задача предпочтительнее десятков skeleton screens. Этапы выполняются последовательно там, где зависят от общего слоя; отделённые домены можно реализовать независимо только после стабилизации интерфейсов. Этот план не поручает автоматически запускать дополнительные чаты/агентов.

### Этап 0. Baseline, fixtures и контрактный барьер

**Файлы:** этот plan; новые `Packages/EngineerCore/Tests/EngineerCoreTests/Fixtures/*`, `ContractFixtureManifest.md`, `ContractParityTests.swift`; существующие `scripts/tests/*` только для запуска baseline.

**Интерфейс:** manifest связывает fixture с source service/method, HTTP request/response и ожидаемым domain result. Все идентификаторы/credentials fixtures синтетические; реальные данные не коммитить.

- [ ] Зафиксировать checkout/status, package versions, target settings, все feature entry points и safe config key names. Проверить source handlers не как доказательство runtime, а как локальную схему.
- [x] Выполнить текущую iOS-сборку и минимальные существующие archive regression harnesses. Baseline PASS; остальные harnesses пока не запускались.
- [ ] Подготовить fixtures LumaWork auth/profile/routes/fuel/salary/vehicles/files; SO active/closed/details/versions/time reports/schedule/equipment; Wiki; assistant JSON/SSE и errors.
- [ ] `ContractParityTests.testRequestShape`: normalized URL/method/query/headers/JSON совпадают с production service builder; несовпадение версии assertion не «исправляется» переписыванием baseline под новый Mac UI.
- [ ] `ContractParityTests.testResponseShape`: existing DTO decoding, null/empty/204, unknown optional fields и errors дают прежние results.
- [x] Текущие HTTP/auth tests используют injectable URLSession/URLProtocol и synthetic tokens; production network/authenticated smoke не выполнялся. Следующие домены обязаны сохранить эту изоляцию.

**Готово:** есть воспроизводимый baseline, список известных ограничений и request/response tests. **Стоп:** противоречие iOS DTO/backend validator, утечка секретов в fixture, непонятный исходный filter.

### Этап 1. Минимальный EngineerCore и native target

**Создать:** `Packages/EngineerCore/Package.swift`, `Sources/EngineerCore/App/EngineerSection.swift`, `Networking/HTTPClient.swift`, `Networking/AppServiceError.swift`, `App/AppConfig.swift`, чистые domain model units; `LumaWorkMac/App/EngineerMacApp.swift`, `LumaWorkMac/App/MacAppDelegate.swift`, Resources/Info.plist, entitlements; scripts/build-macos.sh.

**Изменить (новая область):** только собственный `lumawork-macos/EngineerMac.xcodeproj` и Mac package/sources. iOS-файлы служат read-only контрактным reference, не частью Mac dependency graph.

**Интерфейс:** shared `EngineerSection` сохраняет текущие raw values/titles/permissions и не знает о views; config/transport принимают явную session/config dependency. Остальной извлечённый API сохраняет существующие сигнатуры.

- [x] Сначала тест exact enum/title mapping, config resolution/invalid origin и DTO raw values; затем добавить собственные portable types с тем же контрактом (без изменения iOS).
- [x] Добавить native macOS target/scheme в отдельном проекте, собственный local package и отдельные plist/entitlements; iOS files не входят в dependency graph.
- [x] Minimum 15.6.1 в Debug/Release и собственном package; generated `LSMinimumSystemVersion=15.6.1`. API macOS 26 пока не используются.
- [x] Минимальное стартовое SwiftUI окно, штатные traffic lights и app menus. Реальных domain controls пока нет. Quit/все оконные сценарии ещё не QA-проверены.
- [x] `swift test`: 19/19; Mac Debug arm64: BUILD SUCCEEDED; iOS baseline: BUILD SUCCEEDED, его checkout неизменён. No `import UIKit` в Mac package/app source.
- [x] `.app` запущена через LaunchServices (`open`, не `swift run`/Preview), process и native window подтверждены. В Settings видны Bundle origin и version 0.1.0 (1), shell env для config не требуется. Ручной Finder double-click не проверялся.

**Минимальная часть этапа готова:** native Mac `.app` открывает стартовое окно, собственный package используется target, Debug build/tests проходят, iOS baseline не изменён. Это не рабочий login, desktop shell или feature parity.

### Этап 2. Авторизация, user-scoped storage и lifecycle

**Создать:** `EngineerCore/App/EngineerApplicationCoordinator.swift`, `EngineerCore/Persistence/ScopedSnapshotStorage.swift`, `LumaWorkMac/App/MacSessionContainer.swift`, `Platform/MacKeychain.swift`, `Platform/MacLifecycle.swift`, `Platform/MacSensitiveSnapshotStorage.swift`, `Features/Auth/MacAuthView.swift`.

**Перенести по контракту:** собственные auth DTO/API уже в package; впереди — отдельная SimpleOne session, Keychain boundary, Mac session composition/storage/lifecycle. iOS `AppDataStores`/snapshot/error paths читать как reference, не редактировать.

**Предлагаемые новые interfaces:** `SessionEpoch` — UInt64 generation; coordinator `refreshHomeData(refreshClosedArchive: Bool) async`, `invalidateSession()`, `resumeAfterWake() async`. `MacSessionContainer` владеет app/SO sessions и созданными domain repositories. Storage adapter принимает explicit user scope; anonymous fallback запрещён для private данных.

- [x] `SessionIsolationTests.testLateResponseDiscardedAfterAccountSwitch`: late verify A не меняет session/сохранённые credentials B; domain snapshots будут проверяться при переносе repositories.
- [x] `SessionIsolationTests.test401DoesNotReturnProtectedCache`: 401 снимает session/context и credentials; domain cache read gates проверяются при подключении конкретного домена.
- [x] `SnapshotPersistenceTests`: atomic replacement, quarantine повреждённого файла, simulated no-space, user/SO scopes, AES-GCM envelope и политика версии. Первый Mac schema=1, старых Mac formats нет; unknown version сохраняется, plaintext migration запрещена.
- [x] Реализовать app email code login, restore `/me`, logout; отдельный SO login и Mac Keychain adapter. Auth errors разделены. Реальный Keychain/online login требуют runtime evidence ниже.
- [ ] Mac coordinator auth single-flight/epoch checks реализован; прежние Home/fuel/archive/widget/notification side effects подключить при переносе соответствующих доменов. iOS callbacks/source не изменены.
- [ ] Runtime: холодный запуск, offline restore, смена аккаунта, expired SO при valid app auth, sleep/wake и окна после logout.

**Готово:** реальные сессии/данные изолированы, нет pollers per window, Mac baseline не раскрывает чужой кеш.

### Этап 3. Desktop shell, Settings, команды и edit lifecycle

**Создать:** `App/MacWorkspaceState.swift`, `App/MacCommands.swift`, `Views/MacRootView.swift`, `Views/MacSidebarView.swift`, `Settings/MacSettingsView.swift`, при необходимости `Platform/MacUICompatibility.swift`, `LumaWorkMacTests/WindowStateTests.swift`, `LumaWorkMacUITests/WorkspaceTests.swift`.

**Интерфейс:** `MacWorkspaceState` содержит window ID, selected section/entity IDs, filters и inspector visibility; приватных DTO в restoration нет. Focused command action доступен только активному окну и валидной selection.

- [x] Tests: два windows имеют разные selection; commands targeting; restored invalid/unauthorized section возвращается к разрешённому разделу. 5/5 unhosted tests; независимость selection и focused menu navigation также проверены в двух запущенных окнах.
- [x] Реализовать NavigationSplitView, theme, Settings scene, Cmd shortcuts, context menus и system focus behavior. Shell/account sheet готовы; domain actions и editor shortcuts добавляются вместе с реальными разделами.
- [ ] Сначала штатный UI Sequoia 15.6.1; на 26+ проверить автоматическое оформление native chrome и добавить лишь обоснованные guarded glass APIs. Удалить заливки, мешающие системному glass. Проверить одинаковые actions/layout в обеих ветках.
- [ ] При dirty draft реализовать save-local/discard/cancel; на switch/logout/terminate каждый доступный dirty editor участвует в проверке.
- [ ] UI tests: 1000 × 640, 1280 × 820, widescreen/fullscreen, hidden inspector/sidebar, tab navigation и menu enablement.
- [ ] Проверить светлую/тёмную темы, VoiceOver, Reduce Transparency, Increase Contrast и Reduce Motion на 15.6.1 и 26+; reference Codex — стиль, не источник новых функций.

**Готово:** работа через клавиатуру/мышь, независимые окна, корректные settings и отсутствие phone navigation mechanics.

### Этап 4. Главная, маршрут, карта и ГСМ — первая рабочая вертикаль

**Создать:** `EngineerCore/Routes/RouteDayRepository.swift`, `LumaWorkMac/Features/Home/MacHomeScreen.swift`, `MacRouteTable.swift`, `MacRouteDraftController.swift`, `MacRouteInspector.swift`, `MacRouteArchiveScreen.swift`, `MacRouteMapView.swift`, `Features/Gsm/MacGsmReportScreen.swift`.

**Переиспользовать/выделить:** `HomeFeature/HomeRouteStores.swift`, `RouteDayService.swift`, `RouteLocalStorage.swift`, `RouteSettingsScreen.swift`, `AppleRouteDistance.swift`, `AppleRouteMapScreen.swift` domain parts, `YandexRouteLinks.swift`, `GsmReportFeature.swift` API/profile/store.

**Новый interface:** `RouteDayKey: Hashable(date: String, workType: RouteWorkType)`; repository `load(_ key: RouteDayKey) async throws -> RouteDayRecord`, `send(_ record: RouteDayRecord, for key: RouteDayKey) async throws`. `MacRouteDraftController` хранит key/base/local draft и вызывает тот же `RouteDayService.sendDay(_:date:)`; repository methods не вводят новый server API.

- [x] `RouteContractTests.testPOSAndARMRequestShapes`: date/type/stop sequence/null coordinates/status labels совпадают.
- [x] `RouteDraftTests`: разные даты двух окон; reorder/draft cancel; обязательные endpoints; server ID reconciliation после upsert.
- [x] `RouteSendRecoveryTests`: потерянный POST response + matched GET — один успешный результат; mismatch — не false success.
- [ ] Реализовать desktop route editor/summary/date popup, fuel add action, existing map calculation/manual correction и archive/odometer/GSM entry.
- [x] `RouteConflictTests`: remote fingerprint changed не заменяет draft; тест документирует оставшуюся гонку без CAS.
- [ ] Проверить export/send confirmation, offline route queue/relaunch и monthly mileage → fuel callback (пока Fuel UI может быть ещё не реализован).

**Готово:** сквозной Mac login → день POS/ARM → локальное редактирование → прежняя server send → reload; iOS читает те же поля. Server write runtime check только в разрешённом тестовом scope.

### Этап 5. Заявки, архив, координация, трудозатраты и аналитика

**Создать:** `Features/Requests/MacRequestsScreen.swift`, `MacRequestsTable.swift`, `MacRequestDetailView.swift`, `Platform/MacSimpleOneBrowser.swift`, `Features/Coordination/MacCoordinationScreen.swift`, `Features/TimeReports/MacTimeReportsScreen.swift`, `Features/Analytics/MacAnalyticsScreen.swift`.

**Переиспользовать:** все shared SO builders/mappers, ClosedRequestsStore/Index/Query/IncrementalSync, personal comments, company lookup, group archive, TimeReportStore и existing analytics calculators.

**Тесты:** `RequestsParityTests.swift`, `ClosedSyncTests.swift`, `GroupArchiveResumeTests.swift`, `TimeReportParityTests.swift`, `AnalyticsParityTests.swift` в EngineerCoreTests.

- [ ] Assertions: exact active/closed/warehouse conditions; JSON/XLSX equality; effective dates returnEquip; user-scoped data; long description fallback; same timestamp/sys_id boundary.
- [ ] Поиск закрытых вне выбранного периода находит запись в личном и групповом архиве; пустой запрос возвращает прежний период. Ручное полное обновление группы сверяет все страницы, включая удалённые/изменённые записи, не останавливается на первой знакомой странице.
- [ ] Bootstrap baseline → delta → manual import race → resume/recovery; one refresh owner across windows.
- [ ] Desktop tables/details/browser/comments/ИНН, group active/closed и time reports; scopes выбираются локально, не header app tabs.
- [ ] Export не теряет поля скрытых UI columns; visible sort не меняет JSON sync cursor.
- [ ] Сравнить counts/filters/totals iOS и Mac на одной fixture generation, одном периоде и timezone. Переиспользовать existing regression harness как дополнительный контроль.
- [ ] Runtime 12k rows: scroll, sorting, search, selection during delta. Только измеренный bottleneck разрешает NSTableView fallback.

**Готово:** функциональный паритет всех request domains и реальная desktop usability без деградации sync correctness.

### Этап 6. Авто, топливо и зарплата

**Создать:** `Features/Vehicles/MacVehiclesScreen.swift`, `MacMaintenanceScreen.swift`, `Features/Fuel/MacFuelScreen.swift`, `MacFuelImportScreen.swift`, `Features/Salary/MacSalaryScreen.swift`, `Platform/MacLocalAuthentication.swift`.

**Переиспользовать:** VehicleAPI, MaintenanceService, FuelService/Store/SummaryCalculator, FuelImportAPI, SalaryService/Store/analytics и shared parts passcode recovery.

**Тесты:** `FuelCalculationParityTests.swift`, `FuelImportContractTests.swift`, `SalaryParityTests.swift`, `VehicleContractTests.swift`, `LumaWorkMacTests/LocalAuthenticationTests.swift`.

- [ ] Для одинаковых records totals/month summaries/rounding совпадают с iOS, включая несколько fuel types, deductions/carryover и нулевые значения.
- [ ] Проверить input comma/empty/overflow, cancelled form, association vehicleID, one pending monthly-mileage update.
- [ ] Fuel preview → deliberate replace IDs → commit; timeout не запускает другой import бессознательно.
- [ ] Реализовать compact tables/forms/analytics и protected Salary UI; gate распространяется на documents/export/Shortcuts.
- [ ] Real Mac Touch ID + system fallback + PIN recovery + lock/cancel/permissions change; mock LAContext тест не считается biometric proof.

**Готово:** domain calculations/контракты прежние, защищённые данные не раскрываются через соседние окна/commands.

### Этап 7. Общие документы, FTP и platform image adapters

**Создать:** `Platform/MacFileAccess.swift`, `MacDocumentPreview.swift`, `MacImageAdapter.swift`, `Features/FTP/MacFTPScreen.swift`, `MacTransferQueueView.swift`, `Features/Documents/MacDocumentsView.swift`.

**Адаптировать:** общий delegate/state manager из `FTPBackgroundDownloadManager.swift`; APIs/stores из FTP/WorkDocuments/VehicleDocuments/SalaryDocuments; photo preparation/QR code wrapper.

**Тесты:** `FileContractTests.swift`, `TransferReconciliationTests.swift`, `LumaWorkMacTests/FileAccessTests.swift`; UI tests подписанного sandbox .app.

- [ ] Tests: actual chunk envelope/MIME/sequence, FTP404 vs502, ownership, cancel/completion race, late callback A after login B.
- [ ] Реализовать import/export panels, bookmarks, preview, open/reveal/share, existing favorites/breadcrumbs/search/ZIP download.
- [ ] Download retry только после выяснения state; completed managed file сохраняется при удалении history record.
- [ ] Runtime: denied/stale scope, moved folder, no-space, file exists overwrite, network drop, sleep, нормальный quit/relaunch, force quit/relaunch.
- [ ] Image adapters используют downsampling/cost-limited cache, QR payload неизменен; попробовать representative фото и многостраничный PDF.

**Готово:** safe signed-sandbox filesystem workflow и truthful transfer lifetime, без UIDocumentPicker/ShareSheet в Mac.

### Этап 8. Оборудование, сотрудники, график, профиль

**Создать:** `Features/Equipment/MacEquipmentScreen.swift`, `Features/Employees/MacEmployeesScreen.swift`, `MacWorkScheduleView.swift`, `Features/Profile/MacProfileView.swift`.

**Переиспользовать:** BackpackStore, OfficeEquipmentStore, equipment media manifests/matching, SimpleOneEmployeesStore/Service, WorkScheduleStore/parser/selection, ProfileStore и profile API.

**Тесты:** `EquipmentParityTests.swift`, `EmployeesFilterParityTests.swift`, `WorkScheduleParityTests.swift`, `ProfileContractTests.swift`.

- [ ] СО city/ownership filters и schedule journal/record selection совпадают; пустой месяц/город/no auth показываются раздельно.
- [ ] Desktop lists/inspectors/photo previews, контактные действия и native calendar; existing routes не меняются.
- [ ] Profile/fuel card/virtual QR/route settings/docs; visibility preference scoping и selected-section normalization.
- [ ] Avatar upload/delete roundtrip и image invalidation; не оставлять cached404 после успешной загрузки.
- [ ] New month/week/year boundary и русский calendar; table selection сохраняется после update.

**Готово:** весь existing equipment/team/profile scope доступен с Mac через реальные источники.

### Этап 9. Помощник, Wiki, attachments и диктовка

**Создать:** `Features/Assistant/MacAssistantWorkspace.swift`, `MacConversationList.swift`, `MacAssistantComposer.swift`, `Features/Wiki/MacWikiScreen.swift`, `Platform/MacSpeechCapture.swift`.

**Переиспользовать:** AssistantAPI/Store/local tool executor, shared stream parser и prepared attachment DTO, WikiAPI/Store; desktop MarkdownUI после platform compatibility check.

**Тесты:** `AssistantSSEContractTests.swift`, `AssistantHistoryParityTests.swift`, `AttachmentPreparationTests.swift`, `WikiContractTests.swift`, Mac speech lifecycle tests.

- [ ] SSE fragmented UTF-8/event boundaries/end/error/tool events: один append и одна final message; server-run timeout не вызывает duplicate POST.
- [ ] Conversation pagination/delete/rename и same clientRequestId при retry; old window не пишет новую историю другого аккаунта.
- [ ] Chat/UI local tools дают прежние filters/outputs/approval behavior; не добавлять новые actions для Mac.
- [ ] Реализовать drop/paste/file picker, preview, knowledge feedback, Wiki search/article/PDF; URL tokens не выходят наружу.
- [ ] Test attachment limits actual source; документ с bitmap OCR, encrypted/broken PDF, archive inflation/cancel; отказ микрофона и unsupported on-device Russian recognition.
- [ ] Runtime text selection/links/code blocks, Shift+Return/IME, stream cancellation и speech device change.

**Готово:** прежний assistant wire protocol, реальные файлы/Wiki и работающий основной ввод при любом speech state.

### Этап 10. Администрирование, ГСМ, обратная связь и настройки

**Создать:** `Features/Admin/MacAdminScreen.swift` и отдельные domain views по фактическим группам, `Features/Feedback/MacFeedbackScreen.swift`; дополнить `MacSettingsView.swift`.

**Переиспользовать:** AdminPermission/Admin APIs/Stores, GSM profile/report/template/layout/projects, source editor/file support, FeedbackStore/API и draft/chunk/submit lifecycle.

**Тесты:** `AdminPermissionTests.swift`, `AdminContractTests.swift`, `FeedbackContractTests.swift`, `GsmContractTests.swift`; Mac protected window/command tests.

- [ ] Every actual admin action соответствует permission; role change/403 сбрасывает selection/gate, без cached protected success.
- [ ] Реализовать все группы из 5.5, включая файлы/source metadata, image requests и template/layout/project rules. Read-only server areas явно представлены.
- [ ] Поле version/build — true client metadata; outdated bulk update-email UI показывает отсутствие platform segmentation, не обещает «только Mac».
- [ ] Existing destructive confirmations/validation; опасные action runtime tests не выполняются на production в рамках обычного UI QA.
- [ ] Feedback actual Mac device info, same request ID, draft→chunks→submit→additions; нет duplicate report после reopen.
- [ ] Profile/route/appearance/visibility/notification/security settings доступны в system scene и сохраняют user scoping.

**Готово:** admin/feedback/GSM паритет и проверенная permission модель; не выпустить «Админка» с половиной fake destinations.

### Этап 11. Уведомления, App Intents и macOS Widget

**Создать:** `Platform/MacNotificationCoordinator.swift`, Mac-supported intent presentation, `LumaWorkMacWidget/*` и отдельные entitlements/resources только по реально реализованной интеграции.

**Переиспользовать:** existing notification preference/events API, EngineerVoiceDataService/catalog, widget domain snapshots и deep-link router.

- [ ] Intent tests: тот же вопрос/период/filters → тот же read-only answer; current account and protected local auth enforced.
- [ ] Notifications dedup в текущем процессе по прежним rules; запуск не запрашивает permission без соответствующего UX.
- [ ] Widget group provisioning, refresh/cache, empty/logged-out/protected views и deep link в правильное окно/сессию.
- [ ] Прямо проверить platform API availability для каждого intent/widget; unsupported surface документировать, не маскировать phone UI.
- [ ] Уведомление при полностью завершённом app не объявлять поддержанным без existing transport. Login item/daemon/push endpoints не добавлять.

**Готово:** системные функции честно отражают macOS возможности. Если стадия исключена из preview, релиз не называется полным паритетом.

### Этап 12. Финальная usability, regression и performance

**Файлы:** `LumaWorkMacTests/*`, `LumaWorkMacUITests/*`, package tests, `docs/.../engineer-macos-acceptance.md` создаётся только с реальными результатами, не заранее как «PASS».

- [ ] Пройти section/action parity matrix и failure scenarios раздела 16; зафиксировать missing items явно.
- [ ] Проверить именно macOS Sequoia 15.6.1 и доступную актуальную 26+, базовый M1/8 ГБ и заявленный Intel; minimum window/fullscreen/secondary display, light/dark/contrast, screen lock/wake.
- [ ] Матрица оформления: обе ОС × light/dark × Reduce Transparency; отдельно Increase Contrast/Reduce Motion, active/inactive window, toolbar над прокрученным контентом, sheets/popovers/inspector. На 15.6.1 нет missing symbols/crash новых APIs; на 26+ системный glass не закрыт custom fills.
- [ ] Воспроизвести и измерить большой архив, image/PDF нагрузку, sustained SSE/transfer и relaunch. AppKit fallback только для измеренного проблемного компонента.
- [ ] Проверить focus/commands, text editing, row multi-selection где supported, dirty editors, permissions и every write confirmation.
- [ ] Полная iOS build + релевантные регрессии извлечённых модулей; release target не включает новые Mac files в iOS membership.
- [ ] Sanitize logs, fixtures/resources, bookmarks и temp paths; никакой личной screenshot reference в публичной документации по умолчанию.

**Готово:** quality report связывает каждый claim с тестом/запуском; known limitations отделены от подтверждённого поведения.

### Этап 13. Подписанный кандидат и публикация

**Создать:** scripts/package-macos.sh и отдельный release manifest/checksums. **Не менять:** scripts/publish-sidestore.sh, public iOS source metadata или VPS.

- [ ] Release archive корректной архитектуры; actual bundle name/icon/version/config, signed entitlements и Hardened Runtime.
- [ ] Developer ID codesign validation → notarization accepted → staple → Gatekeeper accepted. Каждую стадию подтверждает её собственный инструмент.
- [ ] Clean install с quarantine, запуск из Finder без окружения, login, server contract smoke и export/download в sandbox.
- [ ] Явно решить ограничение lastAppVersion/update-email и проверить отсутствие ложных server-side release promises.
- [ ] Пользователь отдельно поручает публикацию; после неё скачать public artifact и сверить hash/version/signature, если такой путь дистрибуции выбран.
- [ ] Commit/push только по отдельному подтверждению; production API/deploy в этом плане не меняются.

**Готово:** проверенный installable `.app`/DMG и documented limitations; «собралось» не заменяет notarization/download verification.

## 18. Минимальные интерфейсы и файловые обязанности

| Компонент | Обязанность / что не должно попадать внутрь |
| --- | --- |
| EngineerCore | модели, request builders, parsing/calculations, portable state; никаких SwiftUI Views/NSApplication/UIApplication |
| EngineerApplicationCoordinator | single-flight refresh, session generations, domain side effects; не window navigation |
| MacSessionContainer | composition root/auth/services/platform adapters; не массив произвольных view models |
| MacWorkspaceState | window identity/section/filters/selection/visibility; не token и не server cache |
| RouteDayRepository | данные keyed date/type, serial mutation/reconciliation; не глобально выбранный день окна |
| MacRouteDraftController | base/local draft/dirty state и explicit save/send; не новый mapper/backend client |
| MacFileAccess | scoped URLs/bookmarks/import/export; не DTO/parser/upload API |
| MacSensitiveSnapshotStorage | шифрование/Keychain envelope для чувствительных cache files; не server encryption protocol |
| MacLocalAuthentication | SDK interaction/capability/result; не выдача admin permissions |
| MacCommands | focused actions/menu enablement; не обход UI/domain authorization |
| MacSimpleOneBrowser | WebKit container/cookies/navigation; не новый серверный API |

Имена здесь закрепляют границы плана. Не создавать все adapters как protocols с пустыми mock-only implementations: protocol нужен там, где существуют две реальные платформенные реализации или meaningful injected test seam. Публичные типы/сигнатуры фиксируются в этапе, которому они принадлежат, до начала зависимой реализации.

## 19. Стратегия проверок

### 19.1. Слои evidence

1. **Contract tests:** те же request/response semantics; полностью offline URLProtocol fixtures.
2. **Domain parity:** одинаковые records и generation → одинаковые filters/totals/ответы iOS и Mac.
3. **Mac unit/integration:** per-window drafts/focus/actions, scoped files, epochs/lifecycle, queue reconciliation.
4. **Runtime UI:** native executable, keyboard/mouse/settings/windows/dialogs/previews, protected content и accessibility.
5. **Targeted performance:** реальный scroll/filter/import, цифры и аппаратная/OS-конфигурация; compile-only proof исключается.
6. **Distribution:** подписанный sandbox artifact, notarization, Gatekeeper и clean install; отдельно public artifact, если опубликован.

Существующие `scripts/tests/test-work-schedule-*`, `test-simpleone-*`, `test-coordination-*`, `test-closed-requests-*`, voice/widget tests полезны как regression. Некоторые harnesses компилируют извлечённые текстом fragments — это не substitute проверки реального нового package. Их текущий результат не заявлен данным документом.

### 19.2. Планируемые команды

Новые target/package команды выполняются из `/Users/tigrandarcinan/projects/github/luma-work/lumawork-macos`. iOS baseline/regression команды — из первоначального iOS checkout. История фактических запусков — раздел 22:

```bash
swift test --package-path Packages/EngineerCore
```

```bash
xcodebuild -project EngineerMac.xcodeproj -scheme EngineerMac -configuration Debug -destination 'platform=macOS' -derivedDataPath .codex-tmp/macos-derived-data CODE_SIGNING_ALLOWED=NO build
```

```bash
xcodebuild -project LumaWork/LumaWork.xcodeproj -scheme LumaWork -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .codex-tmp/ios-regression-derived-data CODE_SIGNING_ALLOWED=NO build
```

```bash
bash scripts/tests/run-closed-requests-regressions.sh
```

Подписанный artifact проверяется по фактическому пути; команды не исправляют missing signature автоматически:

```bash
codesign --verify --deep --strict --verbose=2 /actual/path/Инженер.app
codesign -d --entitlements :- /actual/path/Инженер.app
spctl --assess --type execute --verbose=4 /actual/path/Инженер.app
xcrun stapler validate /actual/path/Инженер.app
```

`--deep` здесь verification, не рекомендация подписывать всё blind deep-sign. UI tests со signed sandbox build и actual Keychain/Touch ID остаются отдельной проверкой.

## 20. Риски, ограничения и решения перед выпуском

| Риск | Контроль / критерий остановки |
| --- | --- |
| Общий код изменил iOS filter/расчёт | golden parity и iOS regression на каждом extraction increment; stop при первом unexplained mismatch |
| Извлечение изменило actor isolation/visibility | explicit Swift settings, package compile/tests и concurrency audit конкретных state paths |
| Несколько окон используют глобальный selectedDate | keyed repository + window draft tests; запрет прямого shared HomeRouteStore editor в Mac |
| Потерянный POST породил дубль | existing read-back/request identity; blind retries не включать |
| iOS/Mac overwrite без server version lock | conflict UX + honest last-writer limitation; строгая CAS требует отдельного server change |
| Разные устройства затёрли user lastAppVersion | release gate по server client-version/outdated-email; не заявлять platform-specific updates |
| Локальный backend source разошёлся с продом | separately authorized read-only smoke и release contract validation; source не равно runtime |
| Mac Keychain/App Group policy не совпала с iOS | отдельные namespaces/entitlements и signed runtime proof, особенно widget/auth |
| Фоновые promises оказались недоступными | испытать sleep/quit/force quit; UI сообщает проверенный поддержанный lifetime |
| File dialog работает только unsigned | signed sandbox acceptance обязательна до релиза |
| Загрузка раскрыла данные прошлого пользователя | owner/epoch checks и private destinations; cancel/clear на logout |
| Монохромность скрыла ошибки | текст/символ/семантическое состояние; цвет не единственный носитель |
| Нативная таблица тормозит | воспроизведение/измерения, локальный NSTableView fallback при доказанной необходимости |
| Новые SDK APIs повысили фактический minimum | build settings/Info.plist/package audit + реальный запуск на 15.6.1; availability guards для API 26+ |
| Стекло снижает читаемость или перегружает M1/8 ГБ | системные поверхности, ограниченный custom glass, accessibility fallback и targeted runtime measurements |
| Нет сертификата или неподдержан Intel | не объявлять universal/public ready; сохранить Debug build и зафиксировать конкретный blocker |

**Не требуют остановки исследования:** невыбранный путь публичной дистрибуции, отсутствие signing certificate, неподтверждённый App Group. Они блокируют соответствующий release/widget этап, а не написание common core/UI.

**Требуют отдельного решения до публичного релиза:** заявлять ли Intel после реальных проверок, Developer ID account, Mac feed/update strategy, ограничения server version metadata, область пользовательских production write-smokes. Минимальная macOS 15.6.1 и Liquid Glass на 26+ уже закреплены пользовательским требованием.

## 21. Финальная матрица готовности

- [ ] Native macOS target; Finder/Dock/menu bar/window lifecycle, никаких Catalyst/phone view roots.
- [ ] Реальный запуск полного приложения на Sequoia 15.6.1/M1/8 ГБ; target и packages не требуют более новой ОС.
- [ ] На 26+ нативный Liquid Glass, на 15.6.1 стандартное оформление; одинаковые функции/плотность и проверенные accessibility fallbacks.
- [ ] Отдельный desktop UI всех 12 обычных разделов, условная Админка и вложенные workflows.
- [ ] Профиль, work docs, schedule, equipment, archive/odometer/GSM не потеряны за main-screen концептом.
- [ ] Public server contracts и SimpleOne/Wiki behavior неизменны, request/response parity подтверждён.
- [ ] App/SO auth независимы, caches/Tasks/notifications/files scopes корректны, logout не оставляет данные в окнах.
- [ ] POS/АРМ/date локальны workflow; tables/inspectors/Settings/commands native и доступны с клавиатуры.
- [ ] Multiwindow drafts независимы, conflict/lost-response scenarios имеют явное поведение.
- [ ] Protected salary/admin, Touch ID/PIN/system fallback и encrypted sensitive files проверены.
- [ ] Signed sandbox import/export/bookmarks/Quick Look/FTP queue работают, lifetime обещания совпадают с тестом.
- [ ] Assistant/SSE/attachments/history/local tools, Wiki и speech fallback имеют parity evidence.
- [ ] Notification/Shortcuts/widget support и ограничения явно документированы.
- [ ] 1000 × 640 и типичные/широкие окна; light/dark/contrast/accessibility; реальные performance measurements.
- [ ] iOS baseline сохранён неизменным; Mac domain parity подтверждён, SideStore workflow не менялся.
- [ ] Release signed/notarized/stapled/Gatekeeper accepted; version metadata limitation рассмотрено.
- [ ] Каждый оставшийся gap помечен; screenshot/imagegen или compile не названы готовым продуктом.

## 22. Что изменено этой задачей

Реализация начата 08.10.2026 в ветке `codex/engineer-macos`, от чистого `051b022`. Commit/push, публикация и VPS не разрешались и не выполнялись. Чекбоксы ниже обновляются только после проверок.

### Журнал реализации

- **Продолжение 08.10.2026:** прочитан handoff; текущие файлы сохранены, работа в `codex/session-auth` (репозиторий без commits). Следующая вертикаль — этап 2. Сначала synthetic SO contract fixtures и session/persistence tests, затем implementation; проверки и gaps будут дописаны по результату.

- **Изменение пользователя:** Mac-проект создаётся отдельно в `/Users/tigrandarcinan/projects/github/luma-work/lumawork-macos`, имя проекта `lumawork-macos`. Native target/scheme `EngineerMac` находится в его собственном Xcode project. **Уточнено следующим сообщением:** никаких sibling/cross-repo dependencies; package принадлежит `lumawork-macos`. План пока остаётся по исходному указанному пути.

- **Baseline:** Xcode 26.3; macOS 15.6.1, MacBookAir10,1 (M1), 8 ГБ. `run-closed-requests-regressions.sh`: PASS для group cache/lifetime, group projection, sync policy, personal archive search и index. iOS Debug baseline: BUILD SUCCEEDED (arm64 и x86_64 simulator compilation).
- **Рабочий контур:** используется текущий чистый checkout с отдельной feature-веткой; ignored plan/backend остаются на месте. Progress ledger: `.superpowers/sdd/2026-10-08-engineer-macos/progress.md`.
- **Уточнение этапа 0:** contract barrier выполняется для каждого фактически извлекаемого домена до зависимого UI. Полная матрица fixtures остаётся незавершённой; неперенесённые разделы не объявляются рабочими. Это следует правилу постепенного извлечения из 8.2.
- **Тесты до извлечения:** добавлены XCTest для exact section/title/role mapping, wire values, config precedence/placeholders/invalid origins и HTTP request/response/status/empty envelopes. Первый `swift test` закономерно завершился отсутствием shared target; результат не является PASS.
- **EngineerCore:** добавлен собственный локальный package в `lumawork-macos`, Swift 5, minimum macOS 15.6.1. Перенесены как baseline контрактов `EngineerSection`, `RouteWorkType`, `RouteStopStatus`, `SalaryPaymentKind`, `AppConfig`, `HTTPClient`, `HTTPResponse`, `AppServiceError`, `AppBuildIdentity`, `NetworkDiagnostics`. Первоначальные typealiases в iOS отменены по указанию пользователя: четыре iOS-файла возвращены ровно к `051b022`; iOS checkout снова чистый. Mac package не зависит от него.
- **Конфигурация:** сохраняется фактический per-key порядок environment → Bundle → UserDefaults, затем alias key. Собственный package сохраняет legacy `configuredURL` для baseline parity; throwing `validatedURL` используется перед Mac запросом. iOS полностью неизменён.
- **Test harness correction:** URLSession передаёт upload body в URLProtocol через `httpBodyStream`; fixture reader теперь читает оба штатных представления. Production serialization не менялась.
- **Transport:** прежние method/headers/timeout/cache/JSON/status semantics; добавлен injectable URLSession с прежним ephemeral production default. Никаких настоящих tokens в fixture; URLProtocol изолирован отдельной test session.
- **Auth contract preparation:** в собственный package перенесены `AppUser`, `UserProfileData`, `AppSession`, `AdminPermission`, `AdminPermissionGroup`, `LumaWorkAuthAPI`/`LumaWorkAuthError` и portable `AppErrorClassification`/`AppNetworkBannerKind`. Имеются golden requests request-code/verify-code/me/logout/profile и DTO/permission/error tests. Это только API/DTO, без Mac login/session storage UI.
- **Native environment:** собственные `EngineerMac.xcodeproj`/shared scheme; SwiftUI WindowGroup 1280×820, minimum content 1000×640; минимальный `MacRootView`, `MacAppDelegate`, `MacCommands` (Cmd+N), `MacSettingsView` (theme + actual config/version). Login/sections честно показываются недоступными; fake domain controls нет.
- **Configuration/resources:** собственный Mac `Info.plist` с несекретными API origins и true `0.1.0 (1)`, без Wiki token/phone manifest/background IDs. Собственные sandbox/network-client/user-selected-file entitlements, без App Group и iOS Secrets.
- **Build correction:** первый Debug build компилировал app arm64+x86_64, а package — active arch arm64. Установлен стандартный Debug `ONLY_ACTIVE_ARCH=YES`; повторный Debug build успешен. Это не доказательство Intel/universal Release.
- **Tooling:** `scripts/build-macos.sh`, `scripts/test-engineer-core.sh`, `script/build_and_run.sh` (run/debug/logs/telemetry/verify), Codex Run action и собственные `.gitignore`/`AGENTS.md`. Нет внешних path/dependency references в executable sources/project/scripts.
- **Checks:** 19/19 XCTest PASS; `build-macos.sh` и `build_and_run.sh --verify` PASS; plist/pbxproj и shell syntax PASS. Runtime AX: главное окно «Инженер» со штатными controls и Settings окно с системной темой, actual API origin и version. No login, network writes, Keychain, domain runtime, signed sandbox, Intel/macOS 26 или performance evidence.
- **State before handoff:** все новые Mac files untracked, commits отсутствуют, remote не настроен. iOS возвращён на `main`, status clean; временная пустая feature-ветка удалена. VPS/backend/SideStore не менялись.

### Продолжение: авторизация / storage foundation — 08.10.2026

- **Файлы:** новые `EngineerApplicationCoordinator`, `SessionCredentials`/auth interfaces, `SimpleOneAuthAPI`, `ScopedSnapshotStorage`; Mac `MacSessionContainer`, `MacKeychain`, `MacLifecycle`, `MacAuthView`, `MacSimpleOneAuthView`. `EngineerMacApp` создаёт один app-wide container; `MacRootView` показывает restoring/login/account/SO/offline/error. Domain controls ещё отсутствуют.
- **Владение и изоляция:** credentials и auth tasks принадлежат приложению; email/code/password drafts — окну, без scene/defaults persistence. Cancel и generations не позволяют late A response перезаписать B. Отдельные app/SO generations сохраняют независимость auth operations; общий context epoch инвалидирует domain responses/protected gates. Restore проверяет nonempty identity; 401/403/revoked снимают локальный доступ; offline разрешён только сохранённой identity, malformed response даёт failed/retry. Logout снимает local access до server revocation; server failure отображается отдельно.
- **SO contract barrier:** portable API реализует только login/me с прежними payloads, paths, cookie/header/timeout/error envelopes. Synthetic `simpleone-auth.json` и URLProtocol tests добавлены до реализации. HTTP403 auth получил typed `.forbidden` с прежним сообщением: запрет нельзя преобразовать в offline identity. Shared/implicit cookies отключены; app Bearer не передаётся SO.
- **Mac Keychain policy:** отдельный native login Keychain namespace, bound к обоим origins; default local ACL, без iOS access group/AfterFirstUnlock attributes и без password storage. App и SO auth логически независимы; сохранённый SO credential принадлежит app user в единой atomically replaced Keychain record. Nonsecret pending logout/SO disconnect markers не позволяют снова прочитать credential после отказа delete/write. Runtime ACL/tombstone proof не заявлен.
- **Persistence ruling:** чувствительные и обычные Mac snapshots шифруются одним `ScopedSnapshotStorage` через AES-GCM; Mac key provider — `MacKeychain`. Отдельный дублирующий `MacSensitiveSnapshotStorage` не нужен. Application Support path дополнительно разделён по origins, user/SO paths hashed, authenticated envelope bound к scope+key. Atomic replacement, permissions 0700/0600, serial actor, cancellation перед записью; corrupt files quarantined, schema=1/unknown-version preservation. Нет Mac legacy data: никакой plaintext/iOS migration. Storage создаётся lazily только после app identity; конкретные domain reads/writes ещё не подключены.
- **Lifecycle:** один app-owned observer для sleep/wake и activation; protected generation инвалидируется, wake auth catch-up single-flight. Pollers/checkpoints/transfers и domain side effects будут добавляться вместе с domain repositories. Actual sleep/wake/lock behaviour не проверялся.
- **Privacy fix:** прежний Mac `NetworkDiagnostics` дополнительно redacts email/username/login/auth_key/cookie, включая nested body. Regression сначала показал 3 failures, затем PASS; серверные bodies не менялись.
- **Независимое review:** `requesting-code-review` reviewer нашёл два Important: SO disconnect во время app refresh оставлял restoring; SO403 → offline восстанавливал запрещённую identity. Оба воспроизведены RED tests и исправлены одним проходом (separate generations + актуальный retained SO state; typed forbidden + SO credential removal). Critical/Minor не найдено.
- **Checks:** свежий `./scripts/test-engineer-core.sh` — **42/42 XCTest PASS**; `./scripts/build-macos.sh` — **BUILD SUCCEEDED**. Единственное build warning — ожидаемый skipped AppIntents metadata. Empty app/SO persisted identity regressions также RED→GREEN. Tests не используют реальные Keychain entries, credentials или сеть. Последние logs: `.codex-tmp/engineer-core-tests.log`, `.codex-tmp/macos-build.log`; отдельные RED evidence сохранены в `.codex-tmp/`.
- **Gaps:** live email/SO login, real/signed Keychain, cold/offline restore и account switch в UI, expired SO/valid app runtime, sleep/wake, multiwindow/logout UI, domain hydration/generation/storage и реальные sensitive files остаются непроверенными. Браузер/приложение не запускались этим increment; сборка не названа runtime proof.
- **Git:** `codex/session-auth`; commits и remote отсутствуют, все файлы по-прежнему untracked. `git diff --stat` пуст по этой причине; source inventory/diff artifact сохраняется локально для review. iOS `git status --short` проверен — чисто. Commit/push/VPS/backend/SideStore не выполнялись.



В исходном iOS repo `docs/` и Markdown ignored. В новом независимом Mac repo plan, `AGENTS.md` и fixture manifest не ignored и видны в status; commit/push не выполнялись. Канонический экземпляр для следующего чата находится в `lumawork-macos/docs/superpowers/plans/2026-10-08-engineer-macos.md`; исходный указанный пользователем документ обновлён той же записью.

Последний концепт служит layout reference, screenshot Codex — style reference. На момент создания документа они лежат вне Git workspace; личный screenshot пользователя с названиями других чатов не копируется в репозиторий. Для реализации можно пользоваться исходными attachment/generated-image файлами из этого чата, а production assets брать из текущего app asset catalog.

### Продолжение: desktop shell — 08.10.2026

- Пользователь подтвердил «делай» после предложения первого commit и следующего этапа. Выполняется первый local commit baseline+auth, затем desktop shell в текущем самостоятельном checkout/feature branch; новый worktree не нужен для этого последовательного этапа. Push/remote/production не настраивать без указания.
- **Local commit:** `732bfda` — independent baseline/auth, 45 files; рабочее дерево сразу после commit чистое. Remote отсутствует, push не выполнялся.
- **Steering:** пользователь показал реальный app login и SO HTTP500. Desktop shell ещё не изменялся; сначала расследовать реальный SO login→me path, сравнить runtime origin/контракт, не извлекать и не печатать credentials.
- Текущая source baseline: 42/42 package tests PASS; явный secret-pattern scan новых файлов не нашёл private keys/API keys/JWT. Build — BUILD SUCCEEDED; staged diff check выявил лишние пустые строки EOF в двух baseline enums, они удалены без изменения поведения.
- **SO HTTP500 investigation:** configured `/v1` origin совпадает с read-only iOS config. Read-only endpoint probes: GET login=405, GET me=401. Один POST с синтетическим несуществующим логином дал HTTP500, JSON ERROR/errors.message=`Wrong username or password`. Mac отбрасывал envelope до status handling; исправлен typed invalidCredentials для этого ответа, unknown500 сохраняет status+объяснение. Добавлена диагностика method/path/status без credentials/body. Реальные credentials пользователя не извлекались и не отправлялись агентом. Причина именно его отказа пока не установлена; это не proof успешного SO login.
- **SO normalization parity:** iOS store trims username и password; Mac ранее trim только username. Regression воспроизвёл trailing whitespace в wire password; теперь normalization совпадает. Изменение не названо причиной конкретного пользовательского отказа.
- **Desktop shell implementation:** `MacWorkspaceState` принадлежит окну, хранит section и account-sheet presentation. SceneStorage содержит только raw section и opaque app userID для account-scoped restoration. Native `NavigationSplitView`/flat sidebar, системный sidebar toggle, toolbar/account sheet, focusedSceneValue для sections/account/connection/logout; command navigation повторно читает текущие permissions. Account/SO forms перенесены в sheet. Domain screens честно unavailable; inspector/search/dirty draft/save не добавляются до реального редактора.
- **Native test boundary:** собственный unhosted `EngineerMacTests` target компилирует production workspace state и navigation target напрямую с EngineerCore; app executable не служит test host, поэтому Keychain/сеть не запускаются. RED missing workspace source, затем 5/5 PASS: независимость окон, permission-safe restoration, account switch/logout, dispatch target/current permissions, admin role без grants. Command focus в SwiftUI отдельно проверяется runtime; model tests не названы GUI proof.
- **Current checks:** package 45/45 PASS, native 5/5 PASS, app BUILD SUCCEEDED; auth HTTP500/parsing/normalization RED→GREEN. Launch через `./script/build_and_run.sh --verify` успешен. Независимый reviewer не нашёл Critical/Important замечаний; `git diff --check` чистый.

- **Runtime shell:** первое окно сохранило «Заявки», второе через Cmd+N открыло «Главная»; меню «Разделы» изменило только второе окно на «Топливо». Cmd+W закрыл второе окно, selection первого сохранилась. Account sheet открывается toolbar action и закрывается Escape. Это focused smoke, не полный UI/accessibility/platform acceptance.
- **Runtime SO:** пользователь сообщил «авторизовался»; в текущем native UI вместо login form наблюдались SO profile и «Выйти из SimpleOne». Успешный login подтверждён, точная причина первоначального HTTP500 не установлена. Credentials и персональные данные в fixtures/plan не записывались.
- **Git:** первый baseline commit `732bfda` существует; текущий SO fix, desktop shell, native tests и journal остаются незакоммиченными. Remote/push отсутствуют.

### Продолжение: первая route вертикаль — 08.10.2026

- Пользователь поручил связать проект с `https://github.com/septoon/lumawork-macos` и выполнить commit/push; remote пустой, PUBLIC, GH CLI доступен. SSH publickey отказал; используем HTTPS с существующей GH авторизацией.
- Пользователь передал `icon_lw.png` как окончательную иконку. Подключён Mac AppIcon asset catalog (16–1024px) с исходной композицией; runtime dependency на внешний файл отсутствует.
- Пользователь поручил продолжить реализацию. Сохраняем предыдущий незакоммиченный shell/SO increment; новых commit/push нет.
- Прочитаны реальные RouteDayService, RouteLocalStorage, HomeRouteStores, AppModels и backend GET/upsert validators. Добавлен синтетический barrier route-days/route-send-arm до domain code.
- Ruling: app-owned keyed repository, window-owned draft. Проверка remote fingerprint перед POST и read-back при неопределённом результате; серверный CAS отсутствует, гонка между preflight и POST остаётся. Возвращать server IDs из upsert/read-back вместо сохранения local IDs.
- Contract/API: 6 новых tests, request/response aliases и lost-response reconciliation GREEN. iOS derives reportedDistanceKm из distanceKm; fixture assertion исправлен по прочитанному source, серверный reportedDistanceKm не переопределяет прежний display helper.
- Repository/draft: account/epoch gates, encrypted cached remote+local revision, conflict preflight, manual queued retry/read-back и disk-failure rollback. 63/63 package tests GREEN; UI model/window close guard и native route editor/archive уже собираются. Runtime и final review впереди.
- Ruling: первая рабочая часть этапа 4 — маршрут/day editor, локальное сохранение, server send/reload и архив. Карта/ГСМ/топливо подключаются только с реальными контрактами; не добавлять fake actions.


### Проверка и подготовка GitHub — 09.10.2026

- По прямому требованию пользователя расширен `.gitignore`: Secrets/local xcconfig, env, credentials/session JSON, signing keys/profiles, базы, authenticated snapshots, screenshots/diagnostics, bundles и build outputs. Synthetic contract fixtures и AppIcon остаются в Git.
- Добавлен `scripts/check-git-secrets.py`: staged tree + reachable history, sensitive filenames/private keys/known token formats/JWT/URL credentials; вывод только path/category, без значений. Проверка эвристическая, дополнительно просматривается staged diff. Никакие Keychain/session данные не читались для публикации.
- Один независимый readonly route review завершён. Исправлены найденные проблемы: nil base сохранённого нового дня; отсутствие удалённого remote не подменяется default; local sent receipt; explicit recovery другого window draft с подтверждением замены; rollback discard/send draft при disk failure; GET дня/архива во время POST не перезаписывает confirmed snapshot (per-day generation + archive generation); readback 401 остаётся auth failure.
- Regression tests прошли RED до исправлений и GREEN после. Core: **70/70 PASS** (`.codex-tmp/route-publish-core.log`). Native build: **BUILD SUCCEEDED** (`.codex-tmp/route-publish-build.log`). Native tests: **5/5 PASS**, **TEST SUCCEEDED** (`.codex-tmp/route-publish-native.log`). Staged tree + вся reachable history: 103 blobs, 0 secret findings; synthetic private-key/path positive probe корректно BLOCKED, ignore/non-ignore probes PASS; credential-literal review и diff check выполнены перед push. Push receipt фиксируется после выполнения.
- Добавлен README с реальным scope, build/test/run и secret check. iOS checkout проверен: чистый, не изменён.

## 23. Источники и правила обновления плана

Основные локальные источники, относительно корня репозитория:

- `LumaWork/LumaWork/LumaWorkApp.swift`, `AppRootView.swift`, `AppDataStores.swift`, `ContentView.swift`, `AppSidebarShell.swift`.
- `LumaWork/LumaWork/AppSupport/AppConfig.swift`, `EndpointHTTP.swift`, `AppOfflineSnapshot.swift`, `AppErrorPresentation.swift`; `AppModels.swift`, `AppNavigationRouter.swift`.
- `LumaWork/LumaWork/LumaWorkAuthFeature.swift`, `SimpleOneRequestsFeature/*`, `ClosedRequestsFeature/*`, `CoordinationFeature/*`.
- `LumaWork/LumaWork/HomeFeature/*`, `FuelFeature/*`, `SalaryFeature/*`, `VehicleFeature.swift`, `VehicleDocumentsFeature.swift`, `MaintenanceFeature.swift`.
- `LumaWork/LumaWork/WorkDocumentsFeature.swift`, `FTPFeature.swift`, `FTPBackgroundDownloadManager.swift`, `EmployeesFeature/*`, `WorkScheduleFeature/*`.
- `LumaWork/LumaWork/AssistantAPI.swift`, `AssistantStore.swift`, `AssistantFeature.swift`, `AssistantImagePreparation.swift`, `AssistantDocumentPreparation.swift`, `AssistantSpeechRecognizer.swift`, `WikiFeature.swift`.
- `LumaWork/LumaWork/Admin*Feature.swift`, `AdminSelectelFileSupport.swift`, `FeedbackFeature.swift`, `NotificationSettingsFeature.swift`, `EngineerVoice/*`, `WidgetSnapshotPublisher.swift`, `LumaWorkWidget/*`.
- `LumaWork/LumaWork.xcodeproj/project.pbxproj`, current entitlements/plist, `scripts/tests/*`, `CLOSED_REQUESTS_SYNC.md`.
- `deploy/lumawork-api/backend/src/*`: declarations/schemas, особое внимание `server.ts`, `v2Writes.ts`, `adminUsers.ts`, `assistant/*`, `ftpProxy.ts`, file/chunk handlers.

При изменении исходников сначала обновляются source inventory и fixtures; при изменении API это больше не «Mac UI-only adaptation» и требуется отдельное решение. Не записывать здесь фактические production credentials, данные пользователей или неподтверждённые PASS.

## 24. Передача в новый чат — auth, desktop shell и маршрут добавлены

**Открыть как проект:** `/Users/tigrandarcinan/projects/github/luma-work/lumawork-macos`. Это самостоятельный Git repo; Xcode project `EngineerMac.xcodeproj`, scheme `EngineerMac`, product `EngineerMac.app` (имя пользователю «Инженер»). iOS для сборки не требуется.

**Текущий scope по поручению нового чата 08.10.2026:** продолжить реализацию по плану. Auth/storage foundation этапа 2 завершён на source/package уровне. Пользователь подтвердил первый local commit и продолжение desktop shell этапа 3 сообщением «делай». Domain repositories и их side effects подключаются при переносе соответствующих разделов; фиктивный refresh Home не добавлять. Commit/push в `septoon/lumawork-macos` прямо разрешены последним поручением пользователя. Production mutations и публикация бинарника не поручены. У этапа 0 остаётся неполная domain fixture matrix.

**Где продолжить:** первая часть этапа 4 реализована: app-owned `RouteDayRepository`, window-owned `RouteDraftController`, native Table/inspector, POS/АРМ, архив с локальным фильтром месяца, encrypted cache/drafts, manual queued retry, preflight conflict и readback без повторного POST. Следующие части — существующая карта/расчёт маршрута, ГСМ/топливо, затем заявки этапа 5. Не дублировать существующие auth/API/store. Automatic queue processing ещё не реализован. Перед следующим переносом расширить synthetic fixture barrier и прочитать iOS/backend source read-only.

**Команды из нового project root:**

```bash
./scripts/test-engineer-core.sh
./scripts/build-macos.sh
./script/build_and_run.sh --verify
```

```bash
xcodebuild -project EngineerMac.xcodeproj -scheme EngineerMac -configuration Debug -destination 'platform=macOS' -derivedDataPath .codex-tmp/macos-derived-data -only-testing:EngineerMacTests CODE_SIGNING_ALLOWED=NO test
```

**Локальные артефакты:** `.codex-tmp/macos-derived-data/Build/Products/Debug/EngineerMac.app`; `.codex-tmp/macos-build.log`; `.codex-tmp/engineer-core-tests.log`; baseline iOS/archive logs скопированы в `.codex-tmp/baseline/`. Это generated/ignored material, не release.

**Файлы минимального окружения:**

```text
AGENTS.md
.gitignore
.codex/environments/environment.toml
EngineerMac.xcodeproj/project.pbxproj
EngineerMac.xcodeproj/xcshareddata/xcschemes/EngineerMac.xcscheme
LumaWorkMac/App/{EngineerMacApp,MacAppDelegate,MacCommands}.swift
LumaWorkMac/Views/MacRootView.swift
LumaWorkMac/Settings/MacSettingsView.swift
LumaWorkMac/Resources/Info.plist
LumaWorkMac/EngineerMac.entitlements
Packages/EngineerCore/Package.swift
Packages/EngineerCore/Sources/EngineerCore/App/{AppConfig,EngineerSection,WireValues,AuthModels}.swift
Packages/EngineerCore/Sources/EngineerCore/Networking/{HTTPClient,LumaWorkAuthAPI,AppErrorClassification}.swift
Packages/EngineerCore/Tests/EngineerCoreTests/{ConfigurationTests,SectionAndWireValueTests,ContractParityTests,AuthContractTests}.swift
Packages/EngineerCore/Tests/EngineerCoreTests/Fixtures/{http-records,auth-session}.json
Packages/EngineerCore/Tests/EngineerCoreTests/ContractFixtureManifest.md
scripts/{build-macos,test-engineer-core}.sh
script/build_and_run.sh
docs/superpowers/plans/2026-10-08-engineer-macos.md
```

**Что подтверждено runtime:** app authenticated workspace, успешный SO login (сообщение пользователя и native account UI), независимость selection двух окон, focused section command, Cmd+W и Escape account sheet. Реальный GET дня отрисовал упорядоченный маршрут и native inspector; редактирование mileage второго окна не изменило первое; Cmd+W → Cancel сохранил несохранённые изменения. Agent не выполнял live POST и не сохранял синтетические изменения production дня. После закрытия окна «Не сохранять» UI-инструмент потерял доступ; process sample показывал штатный idle event loop, зависание приложения не подтверждено. Полный close/logout/terminate guard runtime matrix остаётся gap.

**Что не доказано после shell increment:** полный email-code flow и authenticated domain parity, Keychain ACL/restore/logout tombstones в signed sandbox/после restart, runtime offline restore/account switch/sleep-wake/logout across windows; полный domain fixture barrier; close/logout/terminate drafts across windows; остальные рабочие разделы; Touch ID/PIN и реальные sensitive previews; signed file panels, notification/widget/App Intents, Intel/Sequoia styling/accessibility beyond startup, macOS 26+ appearance, performance, Developer ID/notarization/distribution. `AppIntents metadata extraction skipped` — ожидаемое предупреждение: App Intents target/API ещё не подключены. Hardened runtime выключен для текущего unsigned Debug, signed validation впереди.

**Read-only references при переносе:** iOS `/Users/tigrandarcinan/projects/github/luma-work/LumaWork` @ `051b022`; package fixture manifest содержит SHA-256 использованных source units. Отсутствие этого соседнего checkout не мешает сборке/тестам Mac.

## Приложение A. Инвентаризация локальных HTTP declarations

Ниже автоматически перечислены literal маршруты из локальной копии `deploy/lumawork-api/backend/src`. Исключены custom GPT/MCP/OAuth-only routes и test files. Некоторые backend routes не вызываются текущим iOS UI и не должны автоматически превращаться в новые Mac features. Методы объединены по пути внутри каждого исходного файла; динамические placeholders сохранены. Это 107 строк declarations, не число уникальных публичных endpoints: один путь может обслуживаться несколькими файлами. SimpleOne и Wiki описаны отдельно в разделах 5 и 7, их upstream handlers в этой локальной копии отсутствуют.

Этот список дополняет, но не заменяет DTO/validator/query/header контракт и не подтверждает production доступность.

| Источник в backend/src | Методы | Путь |
| --- | --- | --- |
| `adminAssistant.ts` | GET | `/api/v2/admin/assistant` |
| `adminAssistant.ts` | PATCH | `/api/v2/admin/assistant/settings` |
| `adminAssistant.ts` | DELETE, PUT | `/api/v2/admin/assistant/users/:id/limit` |
| `adminEngineerFiles.ts` | GET | `/api/v2/admin/engineer-files` |
| `adminEngineerFiles.ts` | DELETE, PATCH | `/api/v2/admin/engineer-files/:area/:name` |
| `adminEngineerFiles.ts` | GET | `/api/v2/admin/engineer-files/:area/:name/content` |
| `adminEngineerFiles.ts` | POST | `/api/v2/admin/engineer-files/:area/upload-chunk` |
| `adminEngineerFiles.ts` | GET, PUT | `/api/v2/admin/engineer-files/source` |
| `adminGsmProjects.ts` | GET, PUT | `/api/v2/admin/gsm-projects` |
| `adminGsmProjects.ts` | GET | `/api/v2/gsm/projects` |
| `adminGsmTemplate.ts` | GET, PUT | `/api/v2/admin/gsm-layout` |
| `adminGsmTemplate.ts` | GET | `/api/v2/admin/gsm-template` |
| `adminGsmTemplate.ts` | POST | `/api/v2/admin/gsm-template/chunk` |
| `adminGsmTemplate.ts` | GET | `/api/v2/admin/gsm-template/file` |
| `adminImages.ts` | GET | `/api/v2/admin/images` |
| `adminImages.ts` | DELETE, PATCH | `/api/v2/admin/images/:kind/:id` |
| `adminImages.ts` | POST | `/api/v2/admin/images/:kind/:id/image-chunk` |
| `adminImages.ts` | POST | `/api/v2/admin/images/backpack-terminals` |
| `adminImages.ts` | POST | `/api/v2/admin/images/equipment` |
| `adminImages.ts` | GET | `/api/v2/media/backpack-terminals` |
| `adminImages.ts` | GET | `/api/v2/media/equipment` |
| `adminOverview.ts` | GET | `/api/v2/admin/audit-log` |
| `adminOverview.ts` | GET | `/api/v2/admin/overview` |
| `adminSite.ts` | GET, PUT | `/api/v2/admin/site` |
| `adminSite.ts` | PUT | `/api/v2/admin/site/screenshots-order` |
| `adminSite.ts` | DELETE, PATCH | `/api/v2/admin/site/screenshots/:id` |
| `adminSite.ts` | POST | `/api/v2/admin/site/screenshots/chunk` |
| `adminSite.ts` | GET | `/api/v2/site` |
| `adminSite.ts` | GET | `/api/v2/site/screenshots/:id` |
| `adminUsers.ts` | GET | `/api/v2/admin/users` |
| `adminUsers.ts` | DELETE, GET | `/api/v2/admin/users/:id` |
| `adminUsers.ts` | PATCH | `/api/v2/admin/users/:id/access` |
| `adminUsers.ts` | POST | `/api/v2/admin/users/:id/block` |
| `adminUsers.ts` | POST | `/api/v2/admin/users/update-email` |
| `appAccess.ts` | GET, PATCH | `/api/v2/admin/app-access` |
| `appAccess.ts` | GET | `/api/v2/app-access` |
| `assistant/history.ts` | GET | `/api/v2/assistant/conversations` |
| `assistant/history.ts` | DELETE, PATCH | `/api/v2/assistant/conversations/:conversationId` |
| `assistant/history.ts` | GET | `/api/v2/assistant/conversations/:conversationId/messages` |
| `assistant/register.ts` | POST | `/api/v2/assistant/runs` |
| `assistant/register.ts` | POST | `/api/v2/assistant/runs/stream` |
| `companyLookup.ts` | GET | `/api/v2/reference/companies/:inn` |
| `feedback.ts` | GET | `/api/v2/admin/feedback` |
| `feedback.ts` | GET, PATCH | `/api/v2/admin/feedback/:id` |
| `feedback.ts` | GET | `/api/v2/admin/feedback/:id/attachments/:attachmentId` |
| `feedback.ts` | POST | `/api/v2/admin/feedback/:id/retry-email` |
| `feedback.ts` | GET, POST | `/api/v2/feedback` |
| `feedback.ts` | DELETE, GET | `/api/v2/feedback/:id` |
| `feedback.ts` | POST | `/api/v2/feedback/:id/additions` |
| `feedback.ts` | GET | `/api/v2/feedback/:id/attachments/:attachmentId` |
| `feedback.ts` | POST | `/api/v2/feedback/:id/attachments/chunk` |
| `feedback.ts` | POST | `/api/v2/feedback/:id/submit` |
| `ftpProxy.ts` | GET | `/api/v2/ftp/download` |
| `ftpProxy.ts` | GET | `/api/v2/ftp/download-folder` |
| `ftpProxy.ts` | GET | `/api/v2/ftp/files` |
| `fuelImports.ts` | POST | `/api/v2/fuel/imports/commit` |
| `fuelImports.ts` | POST | `/api/v2/fuel/imports/preview` |
| `knowledge.ts` | POST | `/api/v2/knowledge/contributions` |
| `knowledge.ts` | POST | `/api/v2/knowledge/feedback` |
| `knowledge.ts` | POST | `/api/v2/knowledge/search` |
| `notifications.ts` | POST | `/api/v2/notifications/events` |
| `notifications.ts` | GET, PUT | `/api/v2/notifications/preferences` |
| `salaryDocuments.ts` | GET | `/api/v2/salary/documents` |
| `salaryDocuments.ts` | DELETE, GET | `/api/v2/salary/documents/:month` |
| `salaryDocuments.ts` | POST | `/api/v2/salary/documents/:month/chunk` |
| `server.ts` | GET | `/admin/users` |
| `server.ts` | GET, POST | `/api/v2/client-personal-comments` |
| `server.ts` | GET | `/api/v2/fuel` |
| `server.ts` | GET | `/api/v2/gsm/jobs` |
| `server.ts` | GET | `/api/v2/gsm/odometer-suggestion` |
| `server.ts` | GET, PUT | `/api/v2/gsm/profile` |
| `server.ts` | POST | `/api/v2/gsm/report` |
| `server.ts` | GET, PUT | `/api/v2/gsm/report-period-overrides` |
| `server.ts` | GET | `/api/v2/maintenance` |
| `server.ts` | GET, PUT | `/api/v2/profile` |
| `server.ts` | DELETE, POST | `/api/v2/profile/avatar` |
| `server.ts` | GET | `/api/v2/routes` |
| `server.ts` | GET | `/api/v2/salary` |
| `server.ts` | POST | `/auth/logout` |
| `server.ts` | POST | `/auth/request-code` |
| `server.ts` | POST | `/auth/verify-code` |
| `server.ts` | GET | `/health` |
| `server.ts` | GET | `/me` |
| `v2Writes.ts` | POST | `/api/v2/fuel` |
| `v2Writes.ts` | DELETE, PUT | `/api/v2/fuel/:id` |
| `v2Writes.ts` | POST | `/api/v2/maintenance` |
| `v2Writes.ts` | DELETE, PUT | `/api/v2/maintenance/:id` |
| `v2Writes.ts` | POST | `/api/v2/routes` |
| `v2Writes.ts` | PUT | `/api/v2/routes/:date` |
| `v2Writes.ts` | POST | `/api/v2/salary` |
| `v2Writes.ts` | DELETE, PUT | `/api/v2/salary/:id` |
| `vehicles.ts` | GET | `/api/v2/admin/vehicle-image-requests` |
| `vehicles.ts` | POST | `/api/v2/admin/vehicle-image-requests/:id/image` |
| `vehicles.ts` | POST | `/api/v2/admin/vehicle-image-requests/:id/image-chunk` |
| `vehicles.ts` | POST | `/api/v2/admin/vehicle-image-requests/:id/reject` |
| `vehicles.ts` | POST | `/api/v2/admin/vehicle-image-requests/:id/start` |
| `vehicles.ts` | POST | `/api/v2/admin/vehicle-images/catalog/image-chunk` |
| `vehicles.ts` | POST | `/api/v2/admin/vehicle-images/catalog/prepare` |
| `vehicles.ts` | PUT | `/api/v2/gsm/profile/vehicle` |
| `vehicles.ts` | GET, POST | `/api/v2/vehicles` |
| `vehicles.ts` | PUT | `/api/v2/vehicles/:id` |
| `vehicles.ts` | DELETE, GET | `/api/v2/vehicles/:id/documents/:documentId` |
| `vehicles.ts` | POST | `/api/v2/vehicles/:id/documents/chunk` |
| `vtbOffices.ts` | GET | `/api/v2/offices` |
| `workDocuments.ts` | GET | `/api/v2/work-documents` |
| `workDocuments.ts` | DELETE, GET, PATCH | `/api/v2/work-documents/:id` |
| `workDocuments.ts` | POST | `/api/v2/work-documents/chunk` |
