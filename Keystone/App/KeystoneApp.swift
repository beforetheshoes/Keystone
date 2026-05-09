import SwiftUI
import ComposableArchitecture
import Dependencies

/// Entry point that gives the binary two personas:
/// - Default: launch the SwiftUI app via `KeystoneApp.main()` (the
///   compiler synthesizes that from `App` conformance, regardless of
///   whether `@main` is present).
/// - `--cli <command> [args]`: run the headless `KeystoneCLI` against
///   the same workspace database, then exit.
///
/// Detecting the flag *before* SwiftUI's `App.main()` is critical —
/// once the SwiftUI lifecycle runs there's no way to escape it cleanly,
/// and we need stdout for JSON output.
@main
struct KeystoneEntry {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "--cli" {
            KeystoneCLI.run(arguments: Array(args.dropFirst(2)))
            return
        }
        KeystoneApp.main()
    }
}

struct KeystoneApp: App {
    @State private var store: StoreOf<AppFeature>

    init() {
        let isTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let disableSync = ProcessInfo.processInfo.environment["KEYSTONE_DISABLE_CLOUDKIT"] == "1"
        let enableSync = !isTests && !disableSync

        // If the user's storage preference is iCloud Drive, we MUST
        // pre-warm the ubiquity container off the main thread before
        // resolving the workspace folder. `url(forUbiquityContainerIdentifier:)`
        // returns nil on the main thread on first call (Apple explicitly
        // documents this); without priming, resolve() throws and we
        // silently fall back to the sandbox container.
        if WorkspaceLocation.current.isICloud {
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = FileManager.default.url(
                    forUbiquityContainerIdentifier: CloudKitConfig.containerIdentifier
                )
                semaphore.signal()
            }
            // First-launch-after-install can take several seconds while
            // CloudKit provisions the container; subsequent launches are
            // near-instant. Bound the wait so a permanently broken
            // iCloud account doesn't deadlock the app.
            _ = semaphore.wait(timeout: .now() + 12)
        }

        prepareDependencies {
            do {
                try $0.bootstrapKeystoneDatabase(configureSyncEngine: enableSync)
            } catch {
                fatalError("Failed to bootstrap Keystone database: \(error)")
            }
        }
        _store = State(wrappedValue: Store(initialState: AppFeature.State()) {
            AppFeature()
        })
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            AppView(store: store)
                .frame(minWidth: 1100, idealWidth: 1400, minHeight: 700, idealHeight: 900)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Keystone") {}
            }
            CommandMenu("Keystone") {
                Button("Search…") { store.send(.openPalette) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Quick Capture") { store.send(.openCapture) }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Lock Now") { store.send(.lockAppRequested) }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(!KeystoneSettings.appLockEnabled && store.unlockedRecordIDs.isEmpty)
            }
            CommandGroup(replacing: .help) {
                Button("Keystone Help") {
                    store.send(.setNav(.help(topic: HelpTopics.defaultTopicID)))
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
        #else
        WindowGroup {
            AppView(store: store)
        }
        .commands {
            // Hardware-keyboard shortcuts on iPad. iPhone gets toolbar buttons.
            CommandMenu("Keystone") {
                Button("Search…") { store.send(.openPalette) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Quick Capture") { store.send(.openCapture) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Keystone Help") {
                    store.send(.setNav(.help(topic: HelpTopics.defaultTopicID)))
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
        #endif
    }
}
