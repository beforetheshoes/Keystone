import SwiftUI

struct KstButton<Label: View>: View {
    enum Style { case standard, primary, ghost }

    var style: Style = .standard
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .font(.kstText(size: 12, weight: .medium))
                .frame(height: 26)
                .padding(.horizontal, 10)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous))
                .overlay(stroke)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .standard:
            (hovering ? KstColor.paper2 : KstColor.paper0)
        case .primary:
            (hovering ? Color(oklch: 0.55, 0.13, 235) : KstColor.cerulean)
        case .ghost:
            (hovering ? KstColor.paper2 : Color.clear)
        }
    }

    private var foreground: Color {
        switch style {
        case .standard, .ghost: KstColor.ink1
        case .primary:          .white
        }
    }

    @ViewBuilder
    private var stroke: some View {
        if style == .standard {
            RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        } else {
            EmptyView()
        }
    }
}

struct KstPill: View {
    var text: String
    var background: Color = KstColor.paper2
    var foreground: Color = KstColor.ink1

    var body: some View {
        Text(text)
            .font(.kstText(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(Capsule())
    }
}

struct KstHairline: View {
    var color: Color = KstColor.ink4
    var body: some View {
        Rectangle()
            .fill(color.opacity(0.55))
            .frame(height: 0.5)
    }
}
