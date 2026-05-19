import Foundation
import os
#if canImport(CloudKit)
import CloudKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Receives `CKShare.Metadata` from the OS when the user taps a share
/// invitation link. Forwards into a static handler that the app's TCA
/// store taps into to dispatch `.shareAccepted(metadata:)`.
///
/// SwiftUI's `App` protocol doesn't expose a per-platform hook for
/// share acceptance; we register a tiny delegate via
/// `@NSApplicationDelegateAdaptor` / `@UIApplicationDelegateAdaptor`
/// that funnels into a single `Sendable` callback.
enum ShareAcceptInbox {
    /// Set by the SwiftUI app at launch. The delegate calls this when
    /// a share lands; the closure dispatches `.shareAccepted` into the
    /// store. `nil` until the app finishes initializing — early
    /// arrivals (rare; the OS only delivers after launch handoff) are
    /// dropped. Stored behind an `OSAllocatedUnfairLock` so the
    /// compiler can verify `Sendable` safety; the slot is touched twice
    /// per process lifetime (once at install, never reassigned).
    private static let _handler = OSAllocatedUnfairLock<(@Sendable (CKShare.Metadata) -> Void)?>(initialState: nil)
    static var handler: (@Sendable (CKShare.Metadata) -> Void)? {
        get { _handler.withLock { $0 } }
        set { _handler.withLock { $0 = newValue } }
    }
}

#if os(macOS)
final class KeystoneAppDelegate: NSObject, NSApplicationDelegate, Sendable {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        ShareAcceptInbox.handler?(metadata)
    }
}
#endif

#if os(iOS)
final class KeystoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = KeystoneSceneDelegate.self
        return config
    }
}

final class KeystoneSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        ShareAcceptInbox.handler?(metadata)
    }
}
#endif
