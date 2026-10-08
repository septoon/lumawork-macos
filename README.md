# Инженер для macOS

Самостоятельное нативное приложение LumaWork. macOS 15.6.1+, Xcode-проект `EngineerMac.xcodeproj`, независимый пакет `Packages/EngineerCore`.

Реализованы вход в приложение и SimpleOne, рабочее окно с разделами, редактор маршрута POS/АРМ, локальные зашифрованные черновики, отправка с проверкой конфликта и архив маршрутов. Карта, ГСМ и остальные рабочие разделы ещё переносятся.

```bash
./scripts/test-engineer-core.sh
./scripts/build-macos.sh
./script/build_and_run.sh --verify
```

Учетные данные хранятся в Keychain, пользовательские снимки — зашифрованно вне исходников. `.gitignore` исключает локальные конфиги, ключи, сессии, базы и сборочные артефакты. Перед коммитом проверить staged diff и содержимое Git:

```bash
python3 scripts/check-git-secrets.py --history
git diff --cached --check
git diff --cached
```

Проверка секретов эвристическая и не заменяет просмотр изменений. Тестовые fixtures синтетические; unit tests не обращаются в сеть. iOS-проект для сборки не требуется.

План, решения и точка продолжения: [docs/superpowers/plans/2026-10-08-engineer-macos.md](docs/superpowers/plans/2026-10-08-engineer-macos.md).
