import Foundation
import EngineerCore

@MainActor
final class MacSessionContainer {
    let config: AppConfig
    let coordinator: EngineerApplicationCoordinator
    private let keychain: MacKeychain
    private var lifecycle: MacLifecycle?
    private var startup: Task<Void, Never>?
    private var snapshots: ScopedSnapshotStorage?
    lazy var requests = RequestsRepository(session: { [coordinator] in coordinator.simpleOneSession },
                                           context: { [coordinator] in coordinator.context },
                                           storage: { [weak self] in
                                               guard let self else { throw SimpleOneServiceError.missingCredentials }
                                               return try self.snapshotStorage()
                                           }, service: { [config] in SimpleOneRequestsService(config: config) },
                                           authFailure: { [coordinator] in coordinator.disconnectSimpleOne() })
    lazy var routes = RouteDayRepository(session: { [coordinator] in coordinator.session },
                                         context: { [coordinator] in coordinator.context },
                                         storage: { [weak self] in
                                             guard let self else { throw RouteRepositoryError.staleSession }
                                             return try self.snapshotStorage()
                                         }, service: { [config] in RouteDayService(config: config, authToken: $0.token) },
                                         authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") },
                                         mapService: { RouteMapCalculator(transport: MacRouteMapTransport()) })

    lazy var gsmFuel = GsmFuelRepository(session: { [coordinator] in coordinator.session },
                                         context: { [coordinator] in coordinator.context },
                                         storage: { [weak self] in
                                             guard let self else { throw GsmFuelError.staleSession }
                                             return try self.snapshotStorage()
                                         }, service: { [config] in GsmFuelService(config: config, authToken: $0.token) },
                                         authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") },
                                         importService: { [config] in FuelImportService(config: config, token: $0.token) })

    lazy var clients = ClientDetailsRepository(session: { [coordinator] in coordinator.session },
                                                context: { [coordinator] in coordinator.context },
                                                storage: { [weak self] in
                                                    guard let self else { throw SnapshotStorageError.missingIdentity }
                                                    return try self.snapshotStorage()
                                                }, service: { [config] in ClientDetailsService(config: config, token: $0.token) },
                                                authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })

    lazy var vehicles = VehicleMaintenanceRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in VehicleMaintenanceService(config: config, token: $0.token) }, authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })
    lazy var salaryAccess = SalaryAccess(context: { [coordinator] in coordinator.context }, generation: { [coordinator] in coordinator.protectedContentGeneration })
    lazy var salaryAuthenticator = MacSalaryAuthenticator(keychain: keychain, config: config, coordinator: coordinator)
    lazy var salary = SalaryRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in SalaryService(config: config, token: $0.token) }, access: salaryAccess, authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })

    lazy var documents = DocumentsRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in DocumentService(config: config, token: $0.token) }, access: salaryAccess, authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })
    lazy var ftp = FTPRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in FTPService(config: config, token: $0.token) }, filesRoot: URL.applicationSupportDirectory.appendingPathComponent("EngineerMac/FTP/" + keychain.snapshotNamespace, isDirectory: true), authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })

    init(config: AppConfig = AppConfig()) {
        self.config = config
        let keychain = MacKeychain(config: config)
        self.keychain = keychain
        coordinator = EngineerApplicationCoordinator(appAPI: LumaWorkAuthAPI(config: config),
                                                       simpleOneAPI: SimpleOneAuthAPI(config: config), credentials: keychain)
    }

    func start() {
        guard startup == nil else { return }
        // Remove only our transient previews/downloads left by a previous terminated process.
        for name in ["EngineerMac-DocumentPreviews", "EngineerMac-FileDownloads"] {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true))
        }
        lifecycle = MacLifecycle(coordinator: coordinator)
        startup = Task { [coordinator] in await coordinator.restore() }
    }

    // Created only when a migrated domain needs it. No anonymous directory or hydration.
    func snapshotStorage() throws -> ScopedSnapshotStorage {
        guard coordinator.context != nil else { throw SnapshotStorageError.missingIdentity }
        if let snapshots { return snapshots }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        let storage = ScopedSnapshotStorage(root: support.appendingPathComponent("EngineerMac/Snapshots/" + keychain.snapshotNamespace, isDirectory: true),
                                            keyProvider: { [keychain] scope in try await keychain.encryptionKey(for: scope) })
        snapshots = storage
        return storage
    }
}
