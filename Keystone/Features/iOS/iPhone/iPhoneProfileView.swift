#if !os(macOS)
import SwiftUI
import ComposableArchitecture

struct iPhoneProfileView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var path = NavigationPath()
    @AppStorage(KeystoneSettings.displayNameKey) private var displayName: String = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    youSection
                    syncCard
                    helpSection
                    aboutSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 32)
            }
            .background(KstColor.paper0)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: iPhoneRoute.self) { route in
                iPhoneRouteView(store: store, route: route)
            }
        }
    }

    private var youSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            iOSSectionTitle(title: "You")
            iOSCardList {
                HStack(spacing: 10) {
                    Text("Display name")
                        .font(.kstText(size: 14))
                        .foregroundStyle(KstColor.ink2)
                    Spacer()
                    TextField("Your name", text: $displayName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .font(.kstText(size: 14))
                        .foregroundStyle(KstColor.ink0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            KeystoneLogo(size: 36, radius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keystone")
                    .font(.kstDisplay(size: 22, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                Text("Local-first life management")
                    .font(.kstText(size: 12))
                    .foregroundStyle(KstColor.ink2)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    private var syncCard: some View {
        iOSCardList {
            HStack(spacing: 10) {
                Circle().fill(syncDot).frame(width: 8, height: 8)
                Text(syncLabel)
                    .font(.kstText(size: 14))
                    .foregroundStyle(KstColor.ink0)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    private var syncDot: Color {
        switch store.syncStatus {
        case .local:   KstColor.ink3
        case .syncing: KstColor.amber
        case .synced:  KstColor.sage
        }
    }
    private var syncLabel: String {
        switch store.syncStatus {
        case .local:   return "Local"
        case .syncing: return "Syncing…"
        case let .synced(at):
            if let at {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .short
                return "Synced · \(f.localizedString(for: at, relativeTo: Date()))"
            }
            return "Synced"
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            iOSSectionTitle(title: "Help")
            iOSCardList {
                ForEach(HelpTopics.all) { topic in
                    iOSCardRow(
                        leading: {
                            Image(systemName: "doc.text")
                                .font(.system(size: 14))
                                .foregroundStyle(KstColor.ink2)
                                .frame(width: 26, height: 26)
                                .background(KstColor.paper2)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        },
                        title: topic.title,
                        subtitle: nil,
                        trailing: { iOSChevron() }
                    ) {
                        path.append(iPhoneRoute.helpTopic(id: topic.id))
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            iOSSectionTitle(title: "About")
            iOSCardList {
                HStack {
                    Text("Version")
                        .font(.kstText(size: 14))
                        .foregroundStyle(KstColor.ink2)
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .font(.kstMono(size: 12))
                        .foregroundStyle(KstColor.ink2)
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
            }
        }
    }
}
#endif
