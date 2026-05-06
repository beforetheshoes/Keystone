import SwiftUI

/// In-app rendering of the Keystone app icon. Loads the same artwork from the
/// `AppLogo` image set so the sidebar header, iPhone Home / Profile, and
/// Settings all match the Dock / Springboard icon exactly.
struct KeystoneLogo: View {
    var size: CGFloat = 22
    var radius: CGFloat = 6

    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
