import SwiftUI
import ComposableArchitecture

struct GalleryView: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]
    var onOpen: (RecordRow) -> Void
    /// Optional store handle so the right-click context menu can
    /// dispatch actions ("Re-enrich…"). When nil, the menu is hidden.
    var store: StoreOf<AppFeature>? = nil

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(records) { r in
                    GalleryCard(db: db, properties: properties, record: r) { onOpen(r) }
                        .contextMenu {
                            if let store, LookupRegistry.provider(for: db.id) != nil {
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
            .padding(20)
        }
        .background(KstColor.paper0)
    }
}

private struct GalleryCard: View {
    var db: DBRow
    var properties: [PropertyRow]
    var record: RecordRow
    var onTap: () -> Void

    @State private var hovering = false

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
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    default:
                                        Color.clear
                                    }
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
            .overlay(
                RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                    .strokeBorder(KstColor.ink4, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
            .offset(y: hovering ? -1 : 0)
            .modifier(GalleryHoverShadow(active: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

private struct GalleryHoverShadow: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active { AnyView(content.kstShadow2()) } else { AnyView(content) }
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
/// relations, checkboxes, JSON, asset references).
private struct PropertyMetaRow: View {
    var properties: [PropertyRow]
    var record: RecordRow

    /// Property keys that are noise in a gallery cell — they're either
    /// long opaque numbers (ISBN, TMDB ID, Apple Place ID) or already
    /// implied by the cover image and title.
    private static let suppressedKeys: Set<String> = [
        "isbn", "tmdb_id", "place_id", "imdb_id", "asin",
    ]

    private static func isRenderable(_ p: PropertyRow) -> Bool {
        switch p.type {
        case .title, .relation, .checkbox, .json, .file, .multiSelect, .rollup, .computed:
            return false
        default:
            return !suppressedKeys.contains(p.key)
        }
    }

    var body: some View {
        let visible: [String] = properties
            .filter(Self.isRenderable)
            .compactMap { p -> String? in
                let v = (record.values[p.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty, v != "—" else { return nil }
                return v
            }
            .prefix(2)
            .map { $0 }

        // Always render exactly one line — even when there's nothing
        // to show — so the meta row contributes consistent height to
        // every card. A non-breaking space keeps the text view from
        // collapsing to zero height when `visible` is empty.
        Text(visible.isEmpty ? "\u{00A0}" : visible.joined(separator: " · "))
            .font(.kstText(size: 11))
            .foregroundStyle(KstColor.ink2)
            .lineLimit(1, reservesSpace: true)
            .truncationMode(.tail)
    }
}
