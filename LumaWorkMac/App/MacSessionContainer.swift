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
                                         authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })

    init(config: AppConfig = AppConfig()) {
        self.config = config
        let keychain = MacKeychain(config: config)
        self.keychain = keychain
        coordinator = EngineerApplicationCoordinator(appAPI: LumaWorkAuthAPI(config: config),
                                                       simpleOneAPI: SimpleOneAuthAPI(config: config), credentials: keychain)
    }

    func start() {
        guard startup == nil else { return }
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
