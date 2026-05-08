import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

struct SettingsView: View {
    @AppStorage(KeystoneSettings.displayNameKey) private var displayName: String = ""

    @State private var currentLocation: WorkspaceLocation = .container
    @State private var alert: AlertContent?
    @State private var pendingRestart: Bool = false

    #if os(iOS)
    @State private var iOSPickerOpen = false
    #endif

    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $displayName, prompt: Text(promptText))
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    #endif
            } header: {
                Text("You")
            } footer: {
                Text("Used in the Home greeting. Leave empty to use your system account name.")
            }

            Section {
                Picker("Where Keystone stores your data", selection: locationBinding) {
                    Text("App container (private to this Mac)").tag(LocationKind.container)
                    Text("Custom folder…").tag(LocationKind.userFolder)
                    Text(iCloudPickerLabel).tag(LocationKind.iCloud)
                        .disabled(!WorkspaceLocationManager.isICloudAvailable)
                }
                .pickerStyle(.inline)
                .labelsHidden()

                LabeledContent("Current location") {
                    Text(currentPathDisplay)
                        .font(.kstMono(size: 11))
                        .foregroundStyle(KstColor.ink2)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if pendingRestart {
                    Text("Quit and reopen Keystone for the new storage location to take effect.")
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.amber)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(storageFooter)
            }

            Section {
                ForEach(APIKeyKind.allCases, id: \.rawValue) { kind in
                    APIKeyRow(kind: kind)
                }
            } header: {
                Text("API Keys")
            } footer: {
                Text("Stored in the macOS Keychain, never in app preferences. Keys unlock external lookups for Books and Movies / TV records; Vendors enrichment uses Apple Maps and needs no key.")
            }

            Section {
                LabeledContent("Version") {
                    Text(versionString)
                        .font(.kstMono(size: 11))
                        .foregroundStyle(KstColor.ink2)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 480)
        #endif
        .onAppear { currentLocation = WorkspaceLocation.current }
        .alert(item: $alert) { content in
            Alert(
                title: Text(content.title),
                message: Text(content.message),
                dismissButton: .default(Text("OK"))
            )
        }
        #if os(iOS)
        .sheet(isPresented: $iOSPickerOpen) {
            FolderPicker { url in
                handleUserPickedFolder(url)
            }
        }
        #endif
    }

    // MARK: - Location picker

    private enum LocationKind: Hashable { case container, userFolder, iCloud }

    private var locationBinding: Binding<LocationKind> {
        Binding(
            get: {
                switch currentLocation {
                case .container: .container
                case .userFolder: .userFolder
                case .iCloudDrive: .iCloud
                }
            },
            set: { kind in
                switch kind {
                case .container:
                    switchTo(.container)
                case .userFolder:
                    presentUserFolderPicker()
                case .iCloud:
                    if WorkspaceLocationManager.isICloudAvailable {
                        switchTo(.iCloudDrive)
                    } else {
                        alert = .init(
                            title: "iCloud Drive unavailable",
                            message: "Sign into iCloud and enable iCloud Drive in System Settings, then try again."
                        )
                    }
                }
            }
        )
    }

    private var iCloudPickerLabel: String {
        WorkspaceLocationManager.isICloudAvailable
            ? "iCloud Drive (sync across devices)"
            : "iCloud Drive (unavailable — sign into iCloud)"
    }

    private var storageFooter: String {
        switch currentLocation {
        case .container:
            return "Files live inside the macOS sandbox container — private and hidden from Finder. Switch to a custom folder or iCloud Drive to make your data visible and portable."
        case .userFolder:
            return "Files live at the folder you picked. Use any sync service (Dropbox, Syncthing, iCloud Drive) by choosing a folder inside it."
        case .iCloudDrive:
            return "Files live in iCloud Drive › Keystone. Visible in Finder's iCloud Drive section and in Files.app on iPhone/iPad. Open Keystone on only one device at a time to avoid SQLite conflicts; row-level changes still sync via CloudKit when configured."
        }
    }

    private var currentPathDisplay: String {
        if let url = try? WorkspaceLocationManager.shared.resolve(currentLocation) {
            return url.path
        }
        return "—"
    }

    // MARK: - Switching

    private func switchTo(_ destination: WorkspaceLocation) {
        guard destination != currentLocation else { return }
        do {
            let oldURL = try WorkspaceLocationManager.shared.resolve(currentLocation)
            let newURL = try WorkspaceLocationManager.shared.resolve(destination)

            if oldURL.path == newURL.path {
                // Same path resolved (shouldn't happen, but guard).
                try WorkspaceLocation.save(destination)
                currentLocation = destination
                return
            }

            try WorkspaceMigration.copy(from: oldURL, to: newURL)
            try WorkspaceLocation.save(destination)
            WorkspaceLocationManager.shared.invalidate()
            currentLocation = destination
            pendingRestart = true
        } catch {
            alert = .init(
                title: "Couldn't switch storage location",
                message: error.localizedDescription
            )
        }
    }

    private func presentUserFolderPicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for Keystone to store your workspace and assets."
        panel.prompt = "Choose"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        handleUserPickedFolder(url)
        #else
        iOSPickerOpen = true
        #endif
    }

    private func handleUserPickedFolder(_ url: URL) {
        do {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            // iOS document-picker URLs carry implicit scoped access;
            // creating a security-scoped bookmark is macOS-only API.
            let options: URL.BookmarkCreationOptions = []
            // Start the scope while we're on the main thread of the picker
            // callback so subsequent reads succeed.
            _ = url.startAccessingSecurityScopedResource()
            #endif
            let bookmark = try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            switchTo(.userFolder(bookmark: bookmark))
        } catch {
            alert = .init(
                title: "Couldn't save folder reference",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Display helpers

    private var promptText: String {
        let system = KeystoneSettings.systemDisplayName
        return system.isEmpty ? "Your name" : system
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

private struct AlertContent: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#if os(iOS)
private struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
#endif
