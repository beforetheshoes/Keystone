import SwiftUI
@preconcurrency import SQLiteData
#if canImport(CloudKit)
import CloudKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Cross-platform wrapper around the CloudKit sharing UI.
///
/// On macOS this presents `NSSharingService(named: .cloudSharing)` via
/// an `NSViewRepresentable` (port of Traveling Snails'
/// `MacCloudSharingView`). On iOS it falls through to sqlite-data's
/// stock `CloudSharingView`, which wraps `UICloudSharingController`.
///
/// Permission options are deliberately scoped to
/// `[.allowPrivate, .allowReadOnly, .allowReadWrite]`. Public links are
/// excluded — `share.encryptedValues` only decrypts for invited
/// participants, so a public link to a protected record would deliver
/// undecryptable ciphertext to anyone who has the URL.
struct CloudShareSheet: View {
    let sharedRecord: SharedRecord
    let onDismiss: () -> Void

    var body: some View {
        #if os(macOS)
        MacCloudShareSheet(sharedRecord: sharedRecord, onDismiss: onDismiss)
        #elseif canImport(UIKit) && !os(tvOS) && !os(watchOS)
        CloudSharingView(
            sharedRecord: sharedRecord,
            availablePermissions: [.allowPrivate, .allowReadOnly, .allowReadWrite],
            didFinish: { _ in onDismiss() },
            didStopSharing: { onDismiss() }
        )
        #else
        Text("Sharing is not supported on this platform.")
            .padding()
        #endif
    }
}

#if os(macOS)
/// macOS port of Traveling Snails'
/// [MacCloudSharingView](https://github.com/beforetheshoes/Traveling-Snails/blob/main/Traveling%20Snails/Views/Sharing/MacCloudSharingView.swift).
/// Wraps `NSSharingService(named: .cloudSharing)` so SwiftUI can
/// present the share invitation flow that AppKit's
/// `UICloudSharingController` analogue handles on iOS.
private struct MacCloudShareSheet: NSViewRepresentable {
    let sharedRecord: SharedRecord
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.presentSharingService(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(sharedRecord: sharedRecord, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, NSCloudSharingServiceDelegate {
        let sharedRecord: SharedRecord
        let onDismiss: () -> Void

        init(sharedRecord: SharedRecord, onDismiss: @escaping () -> Void) {
            self.sharedRecord = sharedRecord
            self.onDismiss = onDismiss
        }

        func presentSharingService(from view: NSView) {
            guard let service = NSSharingService(named: .cloudSharing) else {
                onDismiss()
                return
            }
            service.delegate = self

            let itemProvider = NSItemProvider()
            itemProvider.registerCloudKitShare(
                sharedRecord.share,
                container: CKContainer(identifier: CloudKitConfig.containerIdentifier)
            )
            service.perform(withItems: [itemProvider])
        }

        // MARK: - NSCloudSharingServiceDelegate

        func sharingService(
            _ sharingService: NSSharingService,
            didCompleteForItems items: [Any],
            error: (any Error)?
        ) {
            onDismiss()
        }

        func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
            // Save was successful — the SyncEngine already persisted
            // the share via the .share() round-trip, so this is
            // informational.
        }

        func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
            // The SyncEngine handles share cleanup on the next sync
            // cycle (sqlite-data's `unshare` path is invoked from the
            // sharing controller).
            onDismiss()
        }

        func options(
            for cloudKitSharingService: NSSharingService,
            share provider: NSItemProvider
        ) -> NSSharingService.CloudKitOptions {
            // Public links excluded on purpose — see file-level doc.
            return [.allowPrivate, .allowReadOnly, .allowReadWrite]
        }
    }
}
#endif
