# Contract fixture manifest

Source baseline: iOS commit `051b022`, 08.10.2026. The sources below were read locally; they are NOT build dependencies. Package sources are owned by this independent Mac repository.

All fixtures are synthetic. URLProtocol intercepts each injected URLSession; tests do not contact production.

| Fixture / suite | Baseline source | Request / response assertions | Scope |
| --- | --- | --- | --- |
| `Fixtures/http-records.json`, `ContractParityTests` | `AppSupport/EndpointHTTP.swift` | PUT/query/Bearer/JSON/cache/version headers, numeric/null body; records envelope, unknown keys, 200/204/401/403/404/429/500/502, malformed JSON | Actual package HTTPClient |
| `Fixtures/auth-session.json`, `AuthContractTests` | `LumaWorkAuthFeature.swift` | POST request-code/verify-code/logout, GET me (8 s), PUT profile; token/user/profile decoding, 204, INVALID_CODE/CODE_RECENTLY_SENT/USER_BLOCKED/401, permission normalization, string identifiers | Actual package Auth API/DTOs; no runtime login |
| `SectionAndWireValueTests` | `AppSidebarShell.swift`, `AppModels.swift` | 13 raw/title mappings, 12 non-admin sections; POS/ARM/date keys, stop statuses, salary kind values | Metadata only, no implemented domains |
| `ConfigurationTests` | `AppSupport/AppConfig.swift` | per-key env → Bundle → defaults; aliases/placeholders; explicit invalid Mac origin; legacy URL fallback | Public resolution function + real package |

Pending coverage: routes (actual send/read-back), fuel/salary/vehicles/files, SimpleOne active/closed/details/versions/time reports/schedule/equipment, Wiki, assistant JSON/SSE and domain errors. Do not claim complete stage 0 or feature parity.

Portable changes from the original: public access; injectable URLSession; Mac invalid-origin gate; value-injected config resolver. Payload builders/response rules otherwise preserve the baseline. `HTTPClient.allowEmpty` retains the original unused-parameter behavior. Auth connection retry behavior remains the original one; do not widen it in later UI.

App version/build use `Bundle.main` (the app's real identity), not `Bundle.module`.

## Read-only source fingerprints

Original checkout at analysis: `/Users/tigrandarcinan/projects/github/luma-work/LumaWork`. These paths/hashes are traceability metadata and are never read by the build/test scripts.

- `LumaWork/LumaWork/AppSupport/AppConfig.swift`: SHA-256 `7710f7a4aaf68aa6f280d20f02ae0f1f9f87c01e527419d665e26397aacc098f`
- `LumaWork/LumaWork/AppSupport/EndpointHTTP.swift`: SHA-256 `50fab5943678b6a6d1718b485f6d758856205ebd6bcb8f41f57e1f45d1533400`
- `LumaWork/LumaWork/AppSidebarShell.swift`: SHA-256 `8ba508d474dd05deeb27f503e11d48dc0043a3cfd65b3995cf24364d5cdb8935`
- `LumaWork/LumaWork/AppModels.swift`: SHA-256 `542a10f46584de74374ad0ac29426bc032e8920e5fe20b487f27a95075050401`
- `LumaWork/LumaWork/LumaWorkAuthFeature.swift`: SHA-256 `ffcb7a806548ef4cb2ecddea57cec7d0059b34e4d6c47e205120c73803148337`
- `LumaWork/LumaWork/AppSupport/AppErrorPresentation.swift`: SHA-256 `4f5979a43d7479f17d1edbfd965e75fae888889abcb3fddfd4bbd2779256067b`

## Session increment — 08.10.2026

- `Fixtures/simpleone-auth.json`, `SimpleOneAuthContractTests`: POST `/auth/login` username/password/language=ru, GET `/user/me`, explicit Cookie auth, 25 s timeout, no Bearer, no-cache; auth_key and sys_id validation, OK/error envelope parity, HTTP401/403 and missing identity. Source: four SimpleOne source units below. HTTP403 keeps its original message but gains a typed forbidden case so auth refusal cannot reopen an offline session.
- `SessionIsolationTests`: late account-A response after B login, app401/403/revoked/no anonymous offline identity, offline vs malformed restore, local logout before server revoke, independent SO expiration/403, SO logout during app refresh, single-flight wake refresh, credential-write failure.
- `SnapshotPersistenceTests`: real temporary files, hashed user/SO scopes, AES-GCM encrypted/authenticated payload, corrupt-file quarantine, simulated no-space preserving old data, unsupported version preservation. Schema 1 is the first Mac format: no plaintext/iOS-cache migration. Fixtures do not access Keychain or production.
- `NetworkPrivacyTests`: actual log sanitizer removes login identity and credentials including nested objects. Wire bodies remain unchanged.
- Native Keychain access/ACL, failure tombstones across process restart, signed sandbox, real app/SO login, macOS lifecycle notifications and multiwindow UI still need runtime evidence. Tests prove the production core coordinator with credential/API test boundaries, not those platform behaviors.

Read-only source fingerprints:

- `LumaWork/LumaWork/SimpleOneRequestsFeature/SimpleOneRequestsService.swift`: SHA-256 `711a7377bcbd7fec0791d3227bfe26bce8cb28d26e3e5f18e52d3b0462a4d018`
- `LumaWork/LumaWork/SimpleOneRequestsFeature/SimpleOneRequestsService+Network.swift`: SHA-256 `fecc5f7fccfedf14b78c44093ee5aa1a7c1aa645f23f0a864f8f5cffd2a8138b`
- `LumaWork/LumaWork/SimpleOneRequestsFeature/SimpleOneRequestsService+Mapping.swift`: SHA-256 `133d085f1691bb3cc11ba37c34c0936af3bd9187f8430b6bd85776e96ec9d67b`
- `LumaWork/LumaWork/SimpleOneRequestsFeature/SimpleOneRequestsModels.swift`: SHA-256 `8b661dc529ad57e8fe836aa25f20f20911f52b18e1d7c7a6133d56ab307a4449`
