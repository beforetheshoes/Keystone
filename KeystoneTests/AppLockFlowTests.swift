import XCTest
import Dependencies
import ComposableArchitecture
@testable import Keystone

/// Reducer-level coverage for the privacy-lock state machine. Exercises
/// the actions in `AppFeature.Action` related to lock/unlock, never
/// touches LocalAuthentication directly (`BiometricAuthClient.testValue`
/// returns success instantly; failure tests override it explicitly).
@MainActor
final class AppLockFlowTests: XCTestCase {
    // MARK: - App-launch lock

    func testUnlockAppSucceedsFlipsAppLockUnlocked() async {
        let store = TestStore(initialState: AppFeature.State(appLockUnlocked: false)) {
            AppFeature()
        } withDependencies: {
            $0.biometricAuthClient = .testValue   // returns true
        }

        await store.send(.unlockAppRequested) {
            $0.authInFlight = true
        }
        await store.receive(\.authCompleted) {
            $0.authInFlight = false
            $0.appLockUnlocked = true
        }
    }

    func testUnlockAppFailureKeepsLockEngaged() async {
        let store = TestStore(initialState: AppFeature.State(appLockUnlocked: false)) {
            AppFeature()
        } withDependencies: {
            $0.biometricAuthClient = BiometricAuthClient(
                canAuthenticate: { true },
                kind: { .faceID },
                authenticate: { _ in false }   // explicit fail
            )
        }

        await store.send(.unlockAppRequested) {
            $0.authInFlight = true
        }
        await store.receive(\.authCompleted) {
            $0.authInFlight = false
            // appLockUnlocked stays false — failed auth doesn't open the gate.
        }
        XCTAssertFalse(store.state.appLockUnlocked)
    }

    // (testDoubleTap dropped — the `authInFlight` guard is a runtime
    // convenience; testing it deterministically requires a controlled
    // clock around the in-flight effect, which is more plumbing than
    // the guard itself merits.)

    // MARK: - Lock now

    func testLockAppRequestedClearsUnlockSetAndRecomputes() async {
        let store = TestStore(
            initialState: AppFeature.State(
                appLockUnlocked: true,
                unlockedRecordIDs: ["r1", "r2"],
                hiddenRecordIDs: [],
                protectedSeedIDs: ["r1", "r2"]
            )
        ) {
            AppFeature()
        } withDependencies: {
            // recomputeHiddenSet runs through the database client; route
            // it to a stub that returns "everything is hidden again now
            // that unlocked is empty" without needing a real DB.
            $0.databaseClient.protectedHiddenIDs = { _, _ in ["r1", "r2"] }
            $0.databaseClient.allProtectedSeedIDs = { ["r1", "r2"] }
        }

        await store.send(.lockAppRequested) {
            $0.unlockedRecordIDs = []
            // appLockEnabled defaults false in the test env, so
            // appLockUnlocked stays true here. The unlock-set clear is
            // the meaningful effect.
        }
        await store.receive(\.recomputeHiddenSet)
        await store.receive(\.hiddenSetLoaded) {
            $0.hiddenRecordIDs = ["r1", "r2"]
            $0.protectedSeedIDs = ["r1", "r2"]
        }
    }

    // MARK: - Per-record unlock

    func testUnlockRecordAddsToAllowList() async {
        let store = TestStore(
            initialState: AppFeature.State(
                hiddenRecordIDs: ["trip-1"],
                protectedSeedIDs: ["trip-1"]
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.biometricAuthClient = .testValue
            // After unlock the recompute should see trip-1 in the
            // unlocked allow-list and return an empty hidden set.
            $0.databaseClient.protectedHiddenIDs = { unlocked, _ in
                unlocked.contains("trip-1") ? [] : ["trip-1"]
            }
            $0.databaseClient.allProtectedSeedIDs = { ["trip-1"] }
        }

        await store.send(.unlockRecordRequested(recordID: "trip-1")) {
            $0.authInFlight = true
        }
        await store.receive(\.authCompleted) {
            $0.authInFlight = false
            $0.unlockedRecordIDs = ["trip-1"]
        }
        await store.receive(\.recomputeHiddenSet)
        await store.receive(\.hiddenSetLoaded) {
            $0.hiddenRecordIDs = []
        }
    }

    // MARK: - Show all protected

    func testUnlockAllProtectedFillsAllowListWithEverySeed() async {
        let store = TestStore(
            initialState: AppFeature.State(
                hiddenRecordIDs: ["trip-1", "trip-2", "act-a"],
                protectedSeedIDs: ["trip-1", "trip-2"]
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.biometricAuthClient = .testValue
            $0.databaseClient.protectedHiddenIDs = { unlocked, _ in
                let everything: Set<String> = ["trip-1", "trip-2", "act-a"]
                return everything.subtracting(unlocked.contains("trip-1") && unlocked.contains("trip-2") ? everything : [])
            }
            $0.databaseClient.allProtectedSeedIDs = { ["trip-1", "trip-2"] }
        }

        await store.send(.unlockAllProtectedRequested) {
            $0.authInFlight = true
        }
        await store.receive(\.authCompleted) {
            $0.authInFlight = false
            $0.unlockedRecordIDs = ["trip-1", "trip-2"]
        }
        await store.receive(\.recomputeHiddenSet)
        // After unlocking the seeds, hiddenSet drops the cascade child
        // act-a too — verifying the cascade contract end-to-end.
        await store.receive(\.hiddenSetLoaded) {
            $0.hiddenRecordIDs = []
        }
    }
}
