import SwiftUI

/// Squircle avatar for a record. Renders the record's cover image when set,
/// otherwise falls back to a gradient + initials. Database and tag tiles
/// continue to use `Glyph` since they represent categories, not records.
struct RecordAvatar: View {
    var record: RecordRow
    var size: CGFloat = 18
    /// Accepted for source-compat with old `Glyph` call sites; the avatar's
    /// corner radius is computed from `size`.
    var radius: CGFloat = 0

    private var corner: CGFloat { size * 0.22 }

    var body: some View {
        ZStack {
            if let url = record.coverImageURL, let img = LocalImage.load(url) {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [record.tone.base, record.tone.ink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(record.glyph)
                    .font(.kstText(size: max(8, round(size * 0.45)), weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
