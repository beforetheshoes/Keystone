import SwiftUI

struct GalleryView: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]
    var onOpen: (RecordRow) -> Void

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(records) { r in
                    GalleryCard(db: db, properties: properties, record: r) { onOpen(r) }
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
                // Striped tinted hero
                ZStack(alignment: .bottomLeading) {
                    if let url = record.coverImageURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                StripedHero(tone: record.tone)
                            }
                        }
                        .frame(height: 110)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    } else {
                        StripedHero(tone: record.tone)
                            .frame(height: 110)
                        Glyph(tone: record.tone, text: record.glyph, size: 28, radius: 7)
                            .padding(10)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(record.title)
                        .font(.kstDisplay(size: 15, weight: .semibold))
                        .foregroundStyle(KstColor.ink0)
                    PropertyMetaRow(properties: properties.dropFirst().prefix(3).map { $0 }, record: record)
                }
                .padding(12)
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

private struct PropertyMetaRow: View {
    var properties: [PropertyRow]
    var record: RecordRow

    var body: some View {
        let visible: [(PropertyRow, String)] = properties.compactMap { p in
            let v = record.values[p.key] ?? ""
            return (v.isEmpty || v == "—") ? nil : (p, v)
        }

        HStack(spacing: 5) {
            ForEach(Array(visible.enumerated()), id: \.element.0.id) { idx, pair in
                if idx > 0 {
                    Text("·").foregroundStyle(KstColor.ink4)
                }
                HStack(spacing: 0) {
                    Text("\(pair.0.name): ").foregroundStyle(KstColor.ink3)
                    Text(pair.1).foregroundStyle(KstColor.ink2)
                }
            }
        }
        .font(.kstText(size: 11))
    }
}
