import SwiftUI
import ComposableArchitecture

struct HomeView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Dependency(\.databaseClient) private var dbClient

    @AppStorage(KeystoneSettings.displayNameKey) private var displayName: String = ""

    @State private var people: [RecordRow] = []
    @State private var pets: [RecordRow] = []
    @State private var vehicles: [RecordRow] = []
    @State private var documents: [RecordRow] = []
    @State private var events: [RecordRow] = []
    @State private var maintenance: [RecordRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KstToolbar(breadcrumb: ["Home"]) {
                Text(toolbarDateLabel)
                    .font(.kstMono(size: 11.5))
                    .foregroundStyle(KstColor.ink2)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Greeting
                    VStack(alignment: .leading, spacing: 6) {
                        Text(eyebrowLabel)
                            .font(.kstText(size: 12, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(KstColor.ink2)
                        Text(greetingLine)
                            .font(.kstDisplay(size: 38, weight: .semibold))
                            .foregroundStyle(KstColor.ink0)
                            .kerning(-0.6)
                    }
                    .padding(.bottom, 32)

                    // Top stat row
                    HStack(spacing: 12) {
                        StatTile(label: "PEOPLE",    value: people.count,    accent: .cerulean) { store.send(.setNav(.database("people"))) }
                        StatTile(label: "PETS",      value: pets.count,      accent: .sage)     { store.send(.setNav(.database("pets"))) }
                        StatTile(label: "VEHICLES",  value: vehicles.count,  accent: .iris)     { store.send(.setNav(.database("vehicles"))) }
                        StatTile(label: "DOCUMENTS", value: documents.count, accent: .cerulean) { store.send(.setNav(.database("documents"))) }
                    }
                    .padding(.bottom, 24)

                    // 2x2 panels
                    Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow {
                            HomePanel(title: "Upcoming", subtitle: "Next 60 days",
                                      onMore: { store.send(.setNav(.database("events"))) }) {
                                ForEach(Array(events.prefix(3).enumerated()), id: \.element.id) { idx, e in
                                    EventRow(record: e,
                                             showDivider: idx < min(events.count, 3) - 1,
                                             onTap: { store.send(.setNav(.record(databaseID: "events", recordID: e.id))) })
                                }
                            }
                            .gridCellColumns(1)
                            .frame(maxWidth: .infinity)

                            HomePanel(title: "Family",
                                      onMore: { store.send(.setNav(.database("people"))) }) {
                                ForEach(Array(people.prefix(4).enumerated()), id: \.element.id) { idx, p in
                                    PersonRow(record: p,
                                              showDivider: idx < min(people.count, 4) - 1,
                                              onTap: { store.send(.setNav(.record(databaseID: "people", recordID: p.id))) })
                                }
                            }
                            .gridCellColumns(1)
                            .frame(maxWidth: .infinity)
                        }
                        GridRow {
                            HomePanel(title: "House & maintenance",
                                      onMore: { store.send(.setNav(.database("maintenance"))) }) {
                                ForEach(Array(maintenance.prefix(3).enumerated()), id: \.element.id) { idx, m in
                                    MaintenanceRow(record: m, showDivider: idx < min(maintenance.count, 3) - 1)
                                }
                            }
                            .gridCellColumns(1)
                            .frame(maxWidth: .infinity)

                            HomePanel(title: "Expiring documents",
                                      onMore: { store.send(.setNav(.database("documents"))) }) {
                                let expiring = documents.filter { ($0.values["expires"] ?? "—") != "—" }.prefix(3)
                                ForEach(Array(expiring.enumerated()), id: \.element.id) { idx, d in
                                    DocumentRow(record: d,
                                                showDivider: idx < expiring.count - 1,
                                                onTap: { store.send(.setNav(.record(databaseID: "documents", recordID: d.id))) })
                                }
                            }
                            .gridCellColumns(1)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.top, 36)
                .padding(.bottom, 80)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(KstColor.paper0)
        }
        .background(KstColor.paper0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadData() }
        // Re-fire loadData when the sidebar's database list changes —
        // this is the signal the rest of the app uses to indicate "rows
        // changed, please refetch" (Inbox auto-imports, manual creates,
        // sync deltas).
        .onChange(of: store.databases) { _, _ in
            Task { await loadData() }
        }
    }

    private func loadData() async {
        people = (try? dbClient.records("people")) ?? []
        pets = (try? dbClient.records("pets")) ?? []
        vehicles = (try? dbClient.records("vehicles")) ?? []
        documents = (try? dbClient.records("documents")) ?? []
        events = (try? dbClient.records("events")) ?? []
        maintenance = (try? dbClient.records("maintenance")) ?? []
    }

    private var toolbarDateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d · yyyy"
        return f.string(from: Date())
    }

    private var eyebrowLabel: String {
        let weekday = Date().formatted(.dateTime.weekday(.wide)).uppercased()
        let hour = Calendar.current.component(.hour, from: Date())
        let period: String
        switch hour {
        case 5..<12:  period = "MORNING"
        case 12..<17: period = "AFTERNOON"
        case 17..<22: period = "EVENING"
        default:      period = "NIGHT"
        }
        return "\(weekday) \(period)"
    }

    private var greetingLine: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? KeystoneSettings.systemDisplayName : trimmed
        let firstName = resolved.split(separator: " ").first.map(String.init) ?? resolved
        if firstName.isEmpty {
            return "Welcome home."
        }
        return "Welcome home, \(firstName)."
    }
}

private struct StatTile: View {
    var label: String
    var value: Int
    var accent: AccentTone
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(accent.base).frame(width: 7, height: 7)
                    Text(label)
                        .font(.kstText(size: 11, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(KstColor.ink2)
                }
                Text("\(value)")
                    .font(.kstDisplay(size: 36, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink0)
                    .kerning(-0.8)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KstColor.paper1)
            .overlay(
                RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                    .strokeBorder(KstColor.ink4, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
            .offset(y: hovering ? -1 : 0)
            .modifier(ConditionalShadow2(active: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

private struct ConditionalShadow2: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active {
            AnyView(content.kstShadow2())
        } else {
            AnyView(content)
        }
    }
}

private struct HomePanel<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var onMore: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.kstDisplay(size: 15, weight: .semibold)).foregroundStyle(KstColor.ink0)
                if let subtitle {
                    Text(subtitle).font(.kstText(size: 12)).foregroundStyle(KstColor.ink2)
                }
                Spacer(minLength: 0)
                if let onMore {
                    Button(action: onMore) {
                        Text("Open →").font(.kstText(size: 12)).foregroundStyle(KstColor.ink2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}

private struct EventRow: View {
    var record: RecordRow
    var showDivider: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                DateBadge(date: record.values["when"] ?? "")
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.kstText(size: 14, weight: .semibold)).foregroundStyle(KstColor.ink0)
                    HStack(spacing: 4) {
                        Text(record.values["where"] ?? "")
                        Text("·")
                        Text("with \(record.values["with"] ?? "—")")
                    }
                    .font(.kstText(size: 12)).foregroundStyle(KstColor.ink2)
                }
                Spacer(minLength: 0)
                RecordAvatar(record: record, size: 20, radius: 5)
            }
            .padding(.vertical, 12).padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showDivider { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }
        }
    }
}

private struct PersonRow: View {
    var record: RecordRow
    var showDivider: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                RecordAvatar(record: record, size: 22, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.kstText(size: 13, weight: .medium)).foregroundStyle(KstColor.ink0)
                    Text("\(record.values["relationship"] ?? "—") · \(record.values["lastSeen"] ?? "")")
                        .font(.kstText(size: 11)).foregroundStyle(KstColor.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showDivider { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }
        }
    }
}

private struct MaintenanceRow: View {
    var record: RecordRow
    var showDivider: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(KstColor.ink3, lineWidth: 1.2).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.kstText(size: 13, weight: .medium)).foregroundStyle(KstColor.ink0)
                Text("\(record.values["home"] ?? "—") · \(record.values["cadence"] ?? "—")")
                    .font(.kstText(size: 11)).foregroundStyle(KstColor.ink2)
            }
            Spacer(minLength: 0)
            Text(record.values["due"] ?? "—").font(.kstMono(size: 11)).foregroundStyle(KstColor.ink2)
        }
        .padding(.vertical, 10).padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            if showDivider { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }
        }
    }
}

private struct DocumentRow: View {
    var record: RecordRow
    var showDivider: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                RecordAvatar(record: record, size: 20, radius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.kstText(size: 13, weight: .medium)).foregroundStyle(KstColor.ink0)
                    Text(record.values["kind"] ?? "—").font(.kstText(size: 11)).foregroundStyle(KstColor.ink2)
                }
                Spacer(minLength: 0)
                Text(record.values["expires"] ?? "—")
                    .font(.kstMono(size: 11)).fontWeight(.semibold)
                    .foregroundStyle(KstColor.dangerInk)
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showDivider { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }
        }
    }
}

private struct DateBadge: View {
    var date: String
    var body: some View {
        let parts = date.split(separator: " ", maxSplits: 1).map(String.init)
        let mon = parts.first ?? ""
        let day = parts.count > 1 ? parts[1].replacingOccurrences(of: ",", with: "").split(separator: " ").first.map(String.init) ?? "" : ""

        VStack(spacing: 0) {
            Text(mon.uppercased())
                .font(.kstText(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(KstColor.ceruleanInk)
            Text(day)
                .font(.kstDisplay(size: 18, weight: .semibold))
                .foregroundStyle(KstColor.ink0)
        }
        .frame(width: 44, height: 44)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
