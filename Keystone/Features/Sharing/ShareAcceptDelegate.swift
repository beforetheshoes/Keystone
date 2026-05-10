import Foundation
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
    /// dropped.
    nonisolated(unsafe) static var handler: (@Sendable (CKShare.Metadata) -> Void)?
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
