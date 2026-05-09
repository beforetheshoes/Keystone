import Foundation
import Dependencies
import os

private let workspaceDepLog = Logger(subsystem: "Keystone", category: "Workspace")

/// Dependency-injected accessor for the workspace folder root. Wraps
/// `WorkspaceLocationManager.shared.resolve()` so tests can override
/// the path with a per-test temp directory and avoid polluting the
/// real iCloud Drive / Application Support location.
///
/// Production behavior is byte-identical to the prior static accessor:
/// `liveValue` resolves through `WorkspaceLocationManager` and falls
/// back to the container if resolution fails. Tests must opt in by
/// setting `$0.workspaceFolder` inside `withDependencies { … }`. The
/// test value traps so any test that forgets the override fails
/// loudly instead of silently writing to `~/Library/Application Support/`.
private enum WorkspaceFolderKey: DependencyKey {
    static var liveValue: URL {
        do {
            return try WorkspaceLocationManager.shared.resolve()
        } catch {
            workspaceDepLog.error(
                "workspaceFolder dependency live resolution failed (\(error.localizedDescription, privacy: .public)), falling back to container"
            )
            return WorkspaceLocationManager.containerWorkspaceFolder
        }
    }

    static var testValue: URL {
        // Trap so tests that forget to override with a temp dir fail
        // loudly. The earlier behavior — silently resolving to
        // `~/Library/Application Support/Keystone/` — meant tests
        // polluted the user's machine and raced each other on shared
        // filesystem state. This is the seam that has to fail.
        reportIssue("workspaceFolder accessed in a test without an explicit override. Wrap the test body in `withDependencies { $0.workspaceFolder = tmpDir }`.")
        return WorkspaceLocationManager.containerWorkspaceFolder
    }
}

extension DependencyValues {
    /// Workspace folder root: the user-visible directory holding
    /// `Inbox/`, `Assets/`, `Cars/`, and the workspace README. Read
    /// this through `@Dependency(\.workspaceFolder)` in new code.
    /// `AppDatabase.workspaceFolder` is a thin forwarder kept for
    /// existing callers; both resolve through the same key.
    var workspaceFolder: URL {
        get { self[WorkspaceFolderKey.self] }
        set { self[WorkspaceFolderKey.self] = newValue }
    }
}
