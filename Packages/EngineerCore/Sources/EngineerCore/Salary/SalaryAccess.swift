import Foundation
import Observation

public struct ProtectedAccessGrant: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let context: SessionContext
    fileprivate let generation: UInt64
}
@MainActor @Observable
public final class ProtectedAccess {
    private let context: () -> SessionContext?
    private let generation: () -> UInt64
    private var grants: Set<UUID> = []
    public var currentGeneration: UInt64 { generation() }
    public init(context: @escaping () -> SessionContext?, generation: @escaping () -> UInt64) { self.context = context; self.generation = generation }
    // Called by the native authenticator only after PIN/system/email verification.
    public func authorize(expectedContext: SessionContext, expectedGeneration: UInt64) throws -> ProtectedAccessGrant {
        guard context() == expectedContext, generation() == expectedGeneration else { throw CancellationError() }
        let grant = ProtectedAccessGrant(id: UUID(), context: expectedContext, generation: expectedGeneration)
        grants.insert(grant.id); return grant
    }
    public func accepts(_ grant: ProtectedAccessGrant?) -> Bool {
        guard let grant else { return false }
        return context() == grant.context && generation() == grant.generation && grants.contains(grant.id)
    }
    public func revoke(_ grant: ProtectedAccessGrant?) { if let grant { grants.remove(grant.id) } }
    public func lockAll() { grants = [] }
}

// Preserve the salary domain API while sharing the verified grant mechanism with admin.
public typealias SalaryAccess = ProtectedAccess
public typealias SalaryAccessGrant = ProtectedAccessGrant
