import SwiftUI

struct Glyph: View {
    var tone: AccentTone
    var text: String
    var size: CGFloat = 18
    var radius: CGFloat = 5

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tone.base)
            .frame(width: size, height: size)
            .overlay {
                Text(text)
                    .font(.kstText(size: max(8, round(size * 0.5)), weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
            }
    }
}

struct DBIcon: View {
    var icon: String
    var tone: AccentTone
    var size: CGFloat = 16
    var radius: CGFloat = 4

    var body: some View {
        Glyph(tone: tone, text: icon, size: size, radius: radius)
    }
}
