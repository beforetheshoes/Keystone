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

    /// Available width measured via `onGeometryChange`, then used to
    /// compute the column count for chunked `HStack` rows. Initialized
    /// to a reasonable macOS window-content default so the FIRST
    /// render uses a sensible `columnCount` instead of `1` — without
    /// this, the initial pass would chunk all records into single-card
    /// rows, and when `.onGeometryChange` lands the real width the
    /// chunks would re-key wholesale, triggering a teardown-and-rebuild
    /// of every row's identity. Tradeoff: on narrow windows the first
    /// pre-geometry render may produce a too-wide chunking that's then
    /// adjusted, but that's still less churn than the all-singles
    /// → final pattern.
    @State private var availableWidth: CGFloat = 1024

    private let horizontalPadding: CGFloat = 20
    private let columnSpacing: CGFloat = 14

    /// Number of cards per row, derived from the measured width.
    /// `max(1, …)` defends against the initial render where
    /// `availableWidth` is still 0 — produces a one-card-wide grid
    /// until the first geometry update arrives.
    private var columnCount: Int {
        let usable = max(0, availableWidth - horizontalPadding * 2)
        let perColumn = coverSize.minimumColumnWidth + columnSpacing
        return max(1, Int(usable / perColumn))
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

    /// One pre-chunked row of cards. Wrapping the chunk in an
    /// `Identifiable` struct keyed by the leading card's id gives
    /// `ForEach` a stable identity for incremental updates without
    /// re-chunking the whole bucket when the underlying record set is
    /// the same.
    private struct CardRow: Identifiable {
        var id: String { rows.first?.id ?? "empty" }
        let rows: [RecordRow]
    }

    /// Chunk a flat record array into rows of `columnCount` cards.
    /// Pure — kept as a static helper so the row computation is easy
    /// to memoize per (bucket-id, columnCount) pair if it ever shows
    /// up in a profile (right now it's negligible: ceil(N/columns)
    /// allocations, one slice each).
    private static func chunk(_ rows: [RecordRow], by columnCount: Int) -> [CardRow] {
        guard columnCount > 0 else { return [] }
        var out: [CardRow] = []
        out.reserveCapacity((rows.count + columnCount - 1) / columnCount)
        var i = 0
        while i < rows.count {
            let end = min(i + columnCount, rows.count)
            out.append(CardRow(rows: Array(rows[i..<end])))
            i = end
        }
        return out
    }

    var body: some View {
        let buckets = groups.isEmpty
            ? [RecordGroup(label: "", key: "", rows: records)]
            : groups
        #if os(macOS)
        // macOS: hand off to `NSCollectionView` via NSViewRepresentable.
        // SwiftUI's `LazyVStack`/`LazyVGrid` were observed to hang for
        // 60+ seconds during initial layout / fast scroll over a
        // populated (271-card) gallery, even after data-pipeline
        // optimization, card-hierarchy flattening, and switching to a
        // LazyVStack-of-HStack-rows. The bottleneck is `UnaryLayoutEngine`
        // / `AGGraphGetInputValue` / view-struct retain/release churn
        // intrinsic to SwiftUI's container layout at scale. AppKit's
        // `NSCollectionView` materializes only the visible window's
        // cells (~20-30) regardless of total record count, which is
        // how Apple's own apps (Photos, Music, App Store) render
        // thousand-item grids smoothly.
        MacGalleryCollectionView(
            db: db,
            properties: properties,
            buckets: buckets,
            coverSize: coverSize,
            statusProperty: statusProperty,
            metaByRecordID: store?.derivedRecords.metaByRecordID ?? [:],
            store: store,
            onOpen: onOpen
        )
        .background(KstColor.paper0)
        #else
        let count = columnCount
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(buckets, id: \.key) { bucket in
                    bucketSection(bucket, columnCount: count)
                }
            }
            .padding(horizontalPadding)
        }
        .background(KstColor.paper0)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
            availableWidth = newWidth
        }
        #endif
    }

    // Extracted to keep the outer `body` expression small enough for
    // the Swift type-checker. With the chunk + ForEach + HStack +
    // GalleryCard + .equatable + .contextMenu chain inlined, the
    // compiler reported "unable to type-check this expression in
    // reasonable time."
    @ViewBuilder
    private func bucketSection(_ bucket: RecordGroup, columnCount: Int) -> some View {
        if !bucket.label.isEmpty {
            GroupSectionHeader(label: bucket.label, count: bucket.rows.count)
        }
        let chunks = Self.chunk(bucket.rows, by: columnCount)
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(chunks) { row in
                cardRow(row, columnCount: columnCount)
            }
        }
    }

    @ViewBuilder
    private func cardRow(_ row: CardRow, columnCount: Int) -> some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            ForEach(row.rows) { r in
                card(for: r)
            }
            // Pad short trailing row with invisible placeholders so the
            // final row's cards don't stretch to fill the leftover space.
            if row.rows.count < columnCount {
                ForEach(0..<(columnCount - row.rows.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func card(for r: RecordRow) -> some View {
        GalleryCard(
            db: db,
            properties: properties,
            record: r,
            statusProperty: statusProperty,
            coverSize: coverSize,
            meta: store?.derivedRecords.metaByRecordID[r.id] ?? .empty,
            store: store
        ) { onOpen(r) }
            // `.equatable()` must come before `.frame()` — the modifier
            // requires the receiver to conform to `Equatable`, and
            // `GalleryCard` does but `ModifiedContent<GalleryCard, _FrameLayout>`
            // does not.
            .equatable()
            .frame(maxWidth: .infinity)
            .contextMenu { contextMenuContent(for: r) }
    }

    @ViewBuilder
    private func contextMenuContent(for r: RecordRow) -> some View {
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

struct GalleryCard: View, Equatable {
    var db: DBRow
    var properties: [PropertyRow]
    var record: RecordRow
    var statusProperty: PropertyRow?
    var coverSize: GalleryCoverSize
    /// Pre-computed by `AppFeature.recomputeDerived` off-MainActor.
    /// Reading this directly instead of computing
    /// `PropertyMetaContent.make(record:properties:)` per render
    /// removes the per-card MultiSelectValue decode + hours-grammar
    /// parse from the MainActor body path.
    var meta: PropertyMetaContent
    var store: StoreOf<AppFeature>?
    var onTap: () -> Void

    @State private var hovering = false

    /// Skip body re-evaluation when the visible inputs are unchanged.
    /// `store` is a reference type that stays identical for the card's
    /// lifetime; `onTap` is a fresh closure on every parent body run
    /// but its behavior is stable — neither belongs in equality. With
    /// `.equatable()` at the call site, editing one record's value
    /// in the parent state no longer re-renders every sibling card
    /// (matches the equivalent optimization on `TableRowView` /
    /// `ListRow`).
    ///
    /// `nonisolated` so the synthesized `Equatable` witness doesn't
    /// cross into MainActor — the comparison reads only value-typed
    /// fields safe to touch from any isolation domain.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Compare the precomputed `meta` snapshot rather than the raw
        // `properties` list — `meta` is the actual rendered content
        // and changes only when the visible cell output changes,
        // which is what we want `.equatable()` to track.
        lhs.record == rhs.record
        && lhs.db == rhs.db
        && lhs.coverSize == rhs.coverSize
        && lhs.statusProperty == rhs.statusProperty
        && lhs.meta == rhs.meta
    }

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

    // Card shape, shared between the background fill, hit-test target,
    // and stroke overlay. Pulled out so the three usages can't drift.
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
    }

    var body: some View {
        // Flattened from the prior shape — was Button { VStack { Color.clear
        // .aspectRatio + 3× .overlay … } } wrapped in a 12-deep modifier
        // chain. The 1.92-minute initial-layout hang in Time Profiler was
        // dominated by `UnaryLayoutEngine.sizeThatFits` (1858 main-thread
        // samples) and `UnaryLayoutEngine.childPlacement` (1455) — every
        // .overlay/.frame/.padding is one of those single-child layout
        // participants. Collapsing the three .overlay modifiers into a
        // single ZStack-overlay and dropping the Button wrapper for
        // `.onTapGesture` + `.contentShape` cuts per-card modifier depth
        // roughly in half.
        VStack(alignment: .leading, spacing: 0) {
            // Cover hero. The `Color.clear` is the layout anchor — it
            // claims the full cell width at 2:3 regardless of what's
            // overlaid, which keeps every card the exact same hero size
            // whether the record has a cover, a square cover, a
            // letterboxed cover, or no cover at all. Without the anchor,
            // a ZStack's intrinsic size depends on its children and
            // cards drift heights.
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    // Single overlay for everything inside the hero —
                    // cover bytes (or fallback), status pill at
                    // bottom-trailing, progress hint at bottom. SwiftUI
                    // applies a `.frame(maxWidth: .infinity, maxHeight:
                    // .infinity, alignment:)` to each ZStack child whose
                    // position differs from the ZStack's anchor, so the
                    // per-child alignment is restored from the prior
                    // three-overlay layout.
                    ZStack {
                        if let url = record.coverImageURL {
                            KstColor.paper2
                            CoverThumbnail(
                                url: url,
                                displaySize: thumbnailDisplaySize,
                                contentMode: .fit
                            ) {
                                Color.clear
                            }
                        } else {
                            StripedHero(tone: record.tone)
                            Glyph(tone: record.tone, text: record.glyph, size: 28, radius: 7)
                                .padding(10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }

                        // Inline status pill — one-click status changes
                        // from the gallery view instead of having to open
                        // the detail sheet. Hidden when this database has
                        // no status property with declared options.
                        if let statusProperty, let store {
                            InlineStatusPill(
                                store: store,
                                record: record,
                                property: statusProperty
                            )
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }

                        // Progress hint along the bottom edge of the
                        // cover — a thin strip that fills from 0 → 100%
                        // for books and TV shows whose status implies
                        // "in progress".
                        ProgressBarOverlay(properties: properties, record: record, db: db)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                // Reserve 2 lines of title height + 1 line of meta
                // height on every card, regardless of content length,
                // so the cards line up bottom-to-bottom in the grid.
                // SwiftUI's `reservesSpace` flag is what pins the line
                // count without truncating shorter titles.
                Text(record.title)
                    .font(.kstDisplay(size: 15, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                    .lineLimit(2, reservesSpace: true)
                // Pre-computed by the off-MainActor derivation pass in
                // `AppFeature.recomputeDerived`. The card just renders
                // the snapshot — no MultiSelectValue decode, no
                // hours-grammar parse, no string trimming on the
                // MainActor body path.
                PropertyMetaRow(content: meta)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Single stroke that thickens + darkens on hover. Replaces
        // the prior offset+shadow combo, which compounded badly during
        // scroll: cards visibly popped up by 1pt and dropped a shadow
        // as they passed under the stationary cursor, truncating its
        // 150ms animation mid-flight on the next card and reading as a
        // flicker. A stroke change is a single GPU-cheap repaint, no
        // compositing-layer churn, and skipping the animation makes
        // the indicator behave instantly — no half-finished
        // interpolations as the cursor rolls over neighbors.
        .background(KstColor.paper0, in: cardShape)
        .overlay(
            cardShape
                .strokeBorder(
                    hovering ? KstColor.ink2 : KstColor.ink4,
                    lineWidth: hovering ? 1 : 0.5
                )
        )
        .clipShape(cardShape)
        // `.contentShape` makes the full card (including transparent
        // areas inside the rounded corners) the hit-test region for
        // `.onTapGesture` — without it, taps inside the corner cutouts
        // fall through to whatever's behind. Replaces the prior Button
        // wrapper, which added its own responder-chain layout
        // participation (one extra layer per card × 271 cards).
        .contentShape(cardShape)
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

private struct StripedHero: View {
    var tone: AccentTone
    var body: some View {
        // No outer `GeometryReader` — `Canvas`'s closure already
        // receives `size` and renders into it natively. Wrapping it
        // in a `GeometryReader` was forcing a double-layout pass per
        // coverless card on top of the canvas drawing itself.
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
    }
}

/// Pre-computed inputs for `PropertyMetaRow`. Computed once per record
/// at the `GalleryCard` level (gated by `.equatable()` so it only
/// reruns when the record actually changes), then passed down to the
/// view as already-prepared values. The view itself becomes a stateless
/// renderer that performs zero collection/parse work in its body.
///
/// Why this matters: the prior `PropertyMetaRow.body` iterated the
/// full `properties` array on every body evaluation, calling
/// `MultiSelectValue.decode`, `String.trimmingCharacters`, and
/// (for Restaurants) `RestaurantHoursSummary.todayShort` — two
/// full string-grammar parses per `hours`-bearing card. With 278
/// cards passing through the LazyVGrid during a long scroll, this
/// was a measurable chunk of main-thread time per cell appearance.
struct PropertyMetaContent: Equatable, Sendable {
    /// Joined "·"-separated meta values displayed before the tags.
    let line: String
    /// First two multi-select tags (chips rendered after the line).
    let tags: [String]

    static let empty = PropertyMetaContent(line: "", tags: [])

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

    /// Build the meta content for a record given its database's
    /// properties. Pure function — safe to call from anywhere,
    /// caches nothing (callers should call this once per record
    /// per render of the owning card).
    static func make(record: RecordRow, properties: [PropertyRow]) -> PropertyMetaContent {
        // Multi-select tags: first multi-select column with values
        // wins; take up to 2 tags.
        var tags: [String] = []
        for p in properties where p.type == .multiSelect {
            let raw = record.values[p.key] ?? ""
            let decoded = MultiSelectValue.decode(raw)
            if !decoded.isEmpty {
                tags = Array(decoded.prefix(2))
                break
            }
        }

        // Visible meta values: up to 2 entries (or 1 if tags occupy
        // space), filtered to renderable properties, trimmed,
        // formatted-as-today for restaurant `hours`.
        let visible: [String] = properties
            .filter { Self.isRenderable($0) && $0.type != .multiSelect }
            .compactMap { p -> String? in
                let v = (record.values[p.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty, v != "—" else { return nil }
                if p.key == "hours", let today = RestaurantHoursSummary.todayShort(v) {
                    return today
                }
                return v
            }
            .prefix(tags.isEmpty ? 2 : 1)
            .map { $0 }

        return PropertyMetaContent(line: visible.joined(separator: " · "), tags: tags)
    }
}

/// Compact metadata strip rendered under the title in a gallery card.
/// Pure renderer: all collection / parse / format work happens up-front
/// in `PropertyMetaContent.make(...)` — see that type's docstring.
private struct PropertyMetaRow: View {
    let content: PropertyMetaContent

    var body: some View {
        HStack(spacing: 4) {
            if !content.line.isEmpty {
                Text(content.line)
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ForEach(content.tags, id: \.self) { tag in
                Text(tag)
                    .font(.kstText(size: 10, weight: .medium))
                    .foregroundStyle(KstColor.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(KstColor.paper2)
                    .clipShape(Capsule())
            }
            if content.line.isEmpty && content.tags.isEmpty {
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
            // No `GeometryReader` here. `GeometryReader` forces SwiftUI
            // to do a *second* layout pass for every cell it appears in
            // (first to determine the container size, then to fill the
            // reported geometry). For a gallery of 278 books where many
            // have `current_page` progress, every visible card with a
            // fill triggered that double pass — and when a cluster of
            // currently-reading books scrolls into view at the same
            // offset, the cumulative cost blew the frame budget at the
            // same scroll position every time. Classic "freezes at the
            // same spot" symptom.
            //
            // `scaleEffect(x:anchor:)` on a full-width fill achieves the
            // same visual at zero layout cost — it's a single transform
            // applied by the render server, no second pass.
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.25))
                Rectangle()
                    .fill(record.tone.base)
                    .scaleEffect(x: CGFloat(f), anchor: .leading)
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
