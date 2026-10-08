import XCTest
import CryptoKit
@testable import EngineerCore

final class SnapshotPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private let key = Data(repeating: 7, count: 32)

    func testUserAndSimpleOneScopesDoNotShareFiles() async throws {
        let root = try directory()
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in self.key })
        let a = try SnapshotScope(userID: "A/../B", simpleOneUserID: "SO-A")
        let b = try SnapshotScope(userID: "B", simpleOneUserID: "SO-A")
        let c = try SnapshotScope(userID: "A/../B", simpleOneUserID: "SO-B")
        try await storage.save(Data("private-A".utf8), key: "route/../day", scope: a)
        let loaded = try await storage.load(key: "route/../day", scope: a)
        let otherUser = try await storage.load(key: "route/../day", scope: b)
        let otherSO = try await storage.load(key: "route/../day", scope: c)
        XCTAssertEqual(loaded, Data("private-A".utf8))
        XCTAssertNil(otherUser); XCTAssertNil(otherSO)
        XCTAssertThrowsError(try SnapshotScope(userID: " "))
        XCTAssertThrowsError(try SnapshotScope(userID: "A", simpleOneUserID: ""))
    }

    func testSensitiveEnvelopeIsEncryptedAndAuthenticated() async throws {
        let root = try directory()
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in self.key })
        let scope = try SnapshotScope(userID: "A")
        try await storage.save(Data("salary-secret-123".utf8), key: "salary", scope: scope)
        let url = await storage.fileURL(key: "salary", scope: scope)
        let disk = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("salary-secret-123"))
        let wrongKeyStorage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 8, count: 32) })
        do { _ = try await wrongKeyStorage.load(key: "salary", scope: scope); XCTFail("Wrong key exposed salary") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count, 1)
    }

    func testCorruptSnapshotIsQuarantined() async throws {
        let storage = ScopedSnapshotStorage(root: try directory(), keyProvider: { _ in self.key })
        let scope = try SnapshotScope(userID: "A")
        try await storage.save(Data("original".utf8), key: "home", scope: scope)
        let url = await storage.fileURL(key: "home", scope: scope)
        try Data("broken".utf8).write(to: url)
        do { _ = try await storage.load(key: "home", scope: scope); XCTFail("Corrupt snapshot accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].contains("quarantine"))
    }

    func testNoSpaceWriteLeavesPreviousSnapshotReadable() async throws {
        let root = try directory()
        let scope = try SnapshotScope(userID: "A")
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in self.key })
        try await storage.save(Data("old".utf8), key: "home", scope: scope)
        let failing = ScopedSnapshotStorage(root: root, keyProvider: { _ in self.key }, writeFile: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        do { try await failing.save(Data("new".utf8), key: "home", scope: scope); XCTFail("No-space write accepted") }
        catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteOutOfSpace) }
        let loaded = try await storage.load(key: "home", scope: scope)
        XCTAssertEqual(loaded, Data("old".utf8))
    }

    func testUnknownSchemaIsPreservedWithoutPlaintextMigration() async throws {
        let storage = ScopedSnapshotStorage(root: try directory(), keyProvider: { _ in self.key })
        let scope = try SnapshotScope(userID: "A")
        try await storage.save(Data("old".utf8), key: "home", scope: scope)
        let url = await storage.fileURL(key: "home", scope: scope)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["schemaVersion"] = 999
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: url)
        do { _ = try await storage.load(key: "home", scope: scope); XCTFail("Future schema decoded") }
        catch SnapshotStorageError.unsupportedSchema(let version) { XCTAssertEqual(version, 999) }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }
}
