import SwiftUI
import ComposableArchitecture

/// Dispatcher: Books / Movies / TV Shows get the full statistics
/// experience (`StatsDetailView`); every other database falls through
/// to the original generic-dashboard body (still rendered by
/// `GenericDashboard`). There used to be a separate "summary card"
/// per database with a "Show more stats →" button that pushed a
/// dedicated stats page, but the user is already on a stats tab —
/// the two-tier design was redundant chrome. Now the dashboard tab
/// is the stats experience.
struct DashboardView: View {
    @Bindable var store: StoreOf<AppFeature>
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]

    var body: some View {
        switch db.id {
        case "books", "movies", "tv_shows":
            StatsDetailView(store: store, db: db, properties: properties, records: records)
        default:
            GenericDashboard(db: db, properties: properties, records: records)
        }
    }
}

/// Pre-stats dashboard body, kept as the fallback for every database
/// that doesn't have a custom stats summary yet (people, pets,
/// vehicles, …). Renders a single bar-chart card grouped by the
/// first `.select` property plus a "RECENT" list.
struct GenericDashboard: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]

    private var selectProp: PropertyRow? {
        properties.first { $0.type == .select }
    }
    private var counts: [(String, Int)] {
        guard let p = selectProp else { return [] }
        var m: [String: Int] = [:]
        for r in records {
            let k = r.values[p.key] ?? "Other"
            m[k, default: 0] += 1
        }
        return Array(m.sorted { $0.key < $1.key })
    }

    var body: some View {
        ScrollView {
            Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    DashCard(title: "TOTAL \(db.name.uppercased())", value: records.count, accent: db.accent, big: true)
                        .gridCellColumns(2)
                    DashCard(title: "UPDATED THIS MONTH", value: min(records.count, 4), accent: .sage)
                        .gridCellColumns(1)
                }
                GridRow {
                    if let p = selectProp {
                        DashCard(title: "BY \(p.name.uppercased())", accent: db.accent) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(counts, id: \.0) { row in
                                    let total = max(records.count, 1)
                                    HStack(spacing: 10) {
                                        Text(row.0).font(.kstText(size: 12)).foregroundStyle(KstColor.ink1).frame(width: 90, alignment: .leading)
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 3).fill(KstColor.paper2).frame(height: 6)
                                            RoundedRectangle(cornerRadius: 3).fill(db.accent.base)
                                                .frame(width: max(0, CGFloat(row.1) / CGFloat(total) * 200), height: 6)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(row.1)").font(.kstText(size: 11)).monospacedDigit().foregroundStyle(KstColor.ink2).frame(width: 18, alignment: .trailing)
                                    }
                                }
                            }
                            .padding(.top, 6)
                        }
                        .gridCellColumns(2)
                    } else {
                        DashCard(title: "BY CATEGORY", accent: db.accent) { Text("—").foregroundStyle(KstColor.ink3) }
                            .gridCellColumns(2)
                    }
                    DashCard(title: "RECENT", accent: db.accent) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(records.prefix(4)) { r in
                                HStack(spacing: 8) {
                                    RecordAvatar(record: r, size: 16, radius: 4)
                                    Text(r.title).font(.kstText(size: 12)).foregroundStyle(KstColor.ink0)
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                    .gridCellColumns(1)
                }
            }
            .padding(24)
        }
        .background(KstColor.paper0)
    }
}

private struct DashCard<Content: View>: View {
    var title: String
    var value: Int? = nil
    var accent: AccentTone
    var big: Bool = false
    @ViewBuilder var content: () -> Content

    init(title: String, value: Int? = nil, accent: AccentTone, big: Bool = false, @ViewBuilder content: @escaping () -> Content = { EmptyView() }) {
        self.title = title; self.value = value; self.accent = accent; self.big = big; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.kstText(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(KstColor.ink2)
            if let value {
                Text("\(value)")
                    .font(.kstDisplay(size: big ? 56 : 32, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent.base)
                    .padding(.top, 12)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: big ? 140 : nil, alignment: .leading)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}
