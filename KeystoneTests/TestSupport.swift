import Foundation
import Dependencies
@testable import Keystone

/// Boot the Keystone database against a per-test temp workspace folder.
/// Every test that exercises the DB has to go through this — without
/// the explicit `workspaceFolder` override, tests pollute the user's
/// real iCloud Drive / `~/Library/Application Support/Keystone/`
/// folder and race each other on shared filesystem state.
///
/// The temp folder is created fresh for each call and removed when
/// the closure returns (success or throw). The DB itself still lives
/// in the sandbox app-support directory — see `databaseFolder` — so a
/// fresh temp workspace doesn't actually wipe DB rows between tests.
/// That's a separate concern; the seam this fixes is filesystem
/// hermeticity, not row-level isolation.
///
/// Bootstrap runs inside the `operation:` closure so it observes the
/// overridden `workspaceFolder`. The `withDependencies` mutating
/// closure only sets up the *new* scope; reading `@Dependency(...)`
/// inside it would still hit the outer scope's value.
func withHermeticDB<T>(_ body: () throws -> T) rethrows -> T {
    let tmp = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("keystone-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    return try withDependencies {
        $0.workspaceFolder = tmp
    } operation: {
        try withDependencies {
            do {
                try $0.bootstrapKeystoneDatabase(configureSyncEngine: false)
            } catch {
                fatalError("Hermetic DB bootstrap failed: \(error)")
            }
        } operation: {
            try body()
        }
    }
}

/// Async variant for tests that need `await` inside the body.
func withHermeticDB<T>(_ body: () async throws -> T) async rethrows -> T {
    let tmp = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("keystone-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    return try await withDependencies {
        $0.workspaceFolder = tmp
    } operation: {
        try await withDependencies {
            do {
                try $0.bootstrapKeystoneDatabase(configureSyncEngine: false)
            } catch {
                fatalError("Hermetic DB bootstrap failed: \(error)")
            }
        } operation: {
            try await body()
        }
    }
}
