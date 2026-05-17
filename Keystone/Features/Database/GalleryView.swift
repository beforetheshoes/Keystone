import SwiftUI
import ComposableArchitecture

struct GalleryView: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]
    /// Pre-bucketed records by group key. When the caller hasn't
    /// requested grouping this carries a single ungrouped bucket and
    /// we render a flat grid — no section headers.
    var groups: [RecordGroup] = []
    var coverSize: GalleryCoverSize = .medium
    var onOpen: (RecordRow) -> Void
    /// Optional store handle so the right-click context menu can
    /// dispatch actions ("Re-enrich…") and the inline status pill can
    /// commit edits. When nil, those affordances hide.
    var store: StoreOf<AppFeature>? = nil

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: coverSize.minimumColumnWidth), spacing: 14)]
    }

    /// Property descriptor for the `status` field, when this database
    /// has one. The gallery card overlays a status pill on the cover
    /// only when status options exist (otherwise there's nothing
    /// meaningful to cycle through).
    private var statusProperty: PropertyRow? {
        properties.first {
            $0.key == "status" &&
            ($0.config.options?.isEmpty == false)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                let buckets = groups.isEmpty
                    ? [RecordGroup(label: "", key: "", rows: records)]
                    : groups
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                    if !bucket.label.isEmpty {
                        GroupSectionHeader(label: bucket.label, count: bucket.rows.count)
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(bucket.rows) { r in
                            GalleryCard(
                                db: db,
                                properties: properties,
                                record: r,
                                statusProperty: statusProperty,
                                coverSize: coverSize,
                                store: store
                            ) { onOpen(r) }
                                .contextMenu {
                                    if let store {
                                        if !CoverProviderRegistry.providers(for: db.id).isEmpty {
                                            Button("Search covers…") {
                                                store.send(.openCoverPicker(
                                                    databaseID: db.id,
                                                    recordID: r.id,
                                                    currentTitle: r.title
                                                ))
                                            }
                                        }
                                        if LookupRegistry.provider(for: db.id) != nil {
                                            Button("Re-enrich…") {
                                                store.send(.openReenrichLookup(
                                                    databaseID: db.id,
                                                    databaseName: db.name,
                                                    recordID: r.id,
                                                    currentTitle: r.title
                                                ))
                                            }
                                        }
                                    }
                                }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(KstColor.paper0)
    }
}

/// Shared section header used by gallery / list / table when grouping
/// is active. Renders the bucket label and a count of rows in muted ink.
struct GroupSectionHeader: View {
    var label: String
    var count: Int
    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.kstText(size: 11, weight: .semibold))
                .foregroundStyle(KstColor.ink2)
                .tracking(0.6)
                .textCase(.uppercase)
            Text("\(count)")
                .font(.kstText(size: 11))
                .monospacedDigit()
                .foregroundStyle(KstColor.ink3)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

private struct GalleryCard: View {
    var db: DBRow
    var properties: [PropertyRow]
    var record: RecordRow
    var statusProperty: PropertyRow?
    var coverSize: GalleryCoverSize
    var store: StoreOf<AppFeature>?
    var onTap: () -> Void

    @State private var hovering = false

    /// Display size we pass to `CoverThumbnail` for the ImageIO
    /// downsampling target. The grid's `.adaptive(minimum:)` makes
    /// the actual cell wider when the row has slack, so we add a
    /// little headroom — without it, an "expanded" cell at the edge
    /// of the row could show a thumbnail decoded one preset too small.
    private var thumbnailDisplaySize: CGSize {
        let minWidth = coverSize.minimumColumnWidth
        let approxWidth = minWidth * 1.25
        return CGSize(width: approxWidth, height: approxWidth * 1.5)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Cover hero. Book/movie/TV covers are typically 2:3
                // (taller than wide); we honor that with a 2:3 aspect
                // ratio so the entire cover is visible (no clipping at
                // the bottom). The `Color.clear` is the layout anchor —
                // it claims the full cell width at 2:3 regardless of
                // what's overlayed, which keeps every card the exact
                // same hero size whether the record has a cover, a
                // square cover, a letterboxed cover, or no cover at
                // all. Without the anchor, ZStack's intrinsic size
                // depends on its children and cards drift heights.
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let url = record.coverImageURL {
                            ZStack {
                                KstColor.paper2
                                CoverThumbnail(
                                    url: url,
                                    displaySize: thumbnailDisplaySize,
                                    contentMode: .fit
                                ) {
                                    Color.clear
                                }
                            }
                        } else {
                            ZStack(alignment: .bottomLeading) {
                                StripedHero(tone: record.tone)
                                Glyph(tone: record.tone, text: record.glyph, size: 28, radius: 7)
                                    .padding(10)
                            }
                        }
                    }
                    // Inline status pill — one-click status changes
                    // from the gallery view instead of having to open
                    // the detail sheet. Hidden when this database has
                    // no status property with declared options.
                    .overlay(alignment: .bottomTrailing) {
                        if let statusProperty, let store {
                            InlineStatusPill(
                                store: store,
                                record: record,
                                property: statusProperty
                            )
                            .padding(8)
                        }
                    }
                    // Progress hint along the bottom edge of the cover —
                    // a thin strip that fills from 0 → 100% for books
                    // and TV shows whose status implies "in progress".
                    .overlay(alignment: .bottom) {
                        ProgressBarOverlay(properties: properties, record: record, db: db)
                    }
                    .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    // Reserve 2 lines of title height + 1 line of meta
                    // height on every card, regardless of content
                    // length, so the cards line up bottom-to-bottom in
                    // the grid. SwiftUI's `reservesSpace` flag is what
                    // pins the line count without truncating shorter
                    // titles.
                    Text(record.title)
                        .font(.kstDisplay(size: 15, weight: .semibold))
                        .foregroundStyle(KstColor.ink0)
                        .lineLimit(2, reservesSpace: true)
                    PropertyMetaRow(properties: properties, record: record)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KstColor.paper0)
            // Single stroke that thickens + darkens on hover. Replaces
            // the prior offset+shadow combo, which compounded badly
            // during scroll: cards visibly popped up by 1pt and dropped
            // a shadow as they passed under the stationary cursor,
            // truncating its 150ms animation mid-flight on the next
            // card and reading as a flicker. A stroke change is a
            // single GPU-cheap repaint, no compositing-layer churn,
            // and skipping the animation makes the indicator behave
            // instantly — no half-finished interpolations as the
            // cursor rolls over neighbors.
            .overlay(
                RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                    .strokeBorder(
                        hovering ? KstColor.ink2 : KstColor.ink4,
                        lineWidth: hovering ? 1 : 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct StripedHero: View {
    var tone: AccentTone
    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                let stripeWidth: CGFloat = 8
                let total = size.width + size.height
                var x: CGFloat = -size.height
                var alt = false
                while x < total {
                    let path = Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x + stripeWidth, y: 0))
                        p.addLine(to: CGPoint(x: x + stripeWidth + size.height, y: size.height))
                        p.addLine(to: CGPoint(x: x + size.height, y: size.height))
                        p.closeSubpath()
                    }
                    ctx.fill(path, with: .color(alt ? tone.base.opacity(0.067) : tone.soft))
                    x += stripeWidth
                    alt.toggle()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Compact metadata strip rendered under the title in a gallery card.
/// Keeps the cell scannable: at most two non-empty values, no labels,
/// single line with truncation. Skips property kinds that don't read
/// well in a chip-sized space (long opaque ids like ISBN / TMDB ID,
/// relations, checkboxes, JSON, asset references). The card overlays
/// the status pill on the cover separately, so it's filtered out of
/// the meta row here.
private struct PropertyMetaRow: View {
    var properties: [PropertyRow]
    var record: RecordRow

    /// Property keys that are noise in a gallery cell — they're either
    /// long opaque numbers (ISBN, TMDB ID, Apple Place ID) or already
    /// implied by the cover image and title. Status is overlaid on
    /// the cover, so it's suppressed here too.
    private static let suppressedKeys: Set<String> = [
        "isbn", "tmdb_id", "place_id", "imdb_id", "asin",
        "status",
    ]

    private static func isRenderable(_ p: PropertyRow) -> Bool {
        switch p.type {
        case .title, .relation, .checkbox, .json, .file, .rollup, .computed:
            return false
        default:
            return !suppressedKeys.contains(p.key)
        }
    }

    private var multiSelectTags: [String] {
        for p in properties where p.type == .multiSelect {
            let raw = record.values[p.key] ?? ""
            let tags = MultiSelectValue.decode(raw)
            if !tags.isEmpty { return Array(tags.prefix(2)) }
        }
        return []
    }

    var body: some View {
        let tags = multiSelectTags
        let visible: [String] = properties
            .filter { Self.isRenderable($0) && $0.type != .multiSelect }
            .compactMap { p -> String? in
                let v = (record.values[p.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty, v != "—" else { return nil }
                // Collapse restaurant hours to today's windows so a
                // gallery card doesn't try to fit a 7-day schedule
                // on its sub-cover meta line.
                if p.key == "hours", let today = RestaurantHoursSummary.todayShort(v) {
                    return today
                }
                return v
            }
            .prefix(tags.isEmpty ? 2 : 1)
            .map { $0 }

        HStack(spacing: 4) {
            if !visible.isEmpty {
                Text(visible.joined(separator: " · "))
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.kstText(size: 10, weight: .medium))
                    .foregroundStyle(KstColor.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(KstColor.paper2)
                    .clipShape(Capsule())
            }
            if visible.isEmpty && tags.isEmpty {
                // Reserve a line of height so cards align bottom-to-bottom.
                Text("\u{00A0}")
                    .font(.kstText(size: 11))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(height: 14, alignment: .leading)
    }
}

/// Bottom-edge progress indicator on a gallery card. For books, fills
/// in `current_page / readable_pages` (or `progress_percent` when the
/// book is in percent mode). For TV, fills in `current_episode /
/// episode_count`. Hidden when the data isn't present (other databases
/// or items the user hasn't started yet).
private struct ProgressBarOverlay: View {
    var properties: [PropertyRow]
    var record: RecordRow
    var db: DBRow

    private var fraction: Double? {
        switch db.id {
        case "books":
            return bookFraction()
        case "tv_shows":
            return tvFraction()
        default:
            return nil
        }
    }

    private func bookFraction() -> Double? {
        let mode = (record.values["progress_mode"] ?? "").trimmingCharacters(in: .whitespaces)
        if mode == "percent" {
            if let pct = Double(record.values["progress_percent"] ?? ""), pct > 0 {
                return min(1.0, pct / 100.0)
            }
            return nil
        }
        guard let cur = Double(record.values["current_page"] ?? ""), cur > 0 else { return nil }
        let total = Double(record.values["readable_pages"] ?? "")
            ?? Double(record.values["page_count"] ?? "")
        guard let total, total > 0 else { return nil }
        return min(1.0, cur / total)
    }

    private func tvFraction() -> Double? {
        guard let ep = Double(record.values["current_episode"] ?? ""), ep > 0,
              let total = Double(record.values["episode_count"] ?? ""), total > 0
        else { return nil }
        return min(1.0, ep / total)
    }

    var body: some View {
        if let f = fraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.25))
                    Rectangle()
                        .fill(record.tone.base)
                        .frame(width: geo.size.width * CGFloat(f))
                }
            }
            .frame(height: 3)
        }
    }
}

/// Tiny wrapper around `SelectPill` that wires it to the store so a
/// click cycles the record's status property and dispatches the
/// `updatePropertyValue` action. Used as a cover-image overlay on
/// gallery cards.
private struct InlineStatusPill: View {
    var store: StoreOf<AppFeature>
    var record: RecordRow
    var property: PropertyRow

    var body: some View {
        let options = property.config.options ?? []
        SelectPill(
            value: Binding(
                get: { record.values[property.key] ?? "" },
                set: { newValue in
                    store.send(.updatePropertyValue(
                        recordID: record.id,
                        key: property.key,
                        value: newValue
                    ))
                }
            ),
            options: options,
            onCommit: {},
            variant: .overlay
        )
    }
}
