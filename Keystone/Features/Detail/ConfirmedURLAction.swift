import SwiftUI

/// Two-step Link affordance: tapping the button doesn't open the URL
/// immediately — it raises a confirmation dialog asking the user to
/// confirm. Avoids the "I just accidentally called the restaurant /
/// opened Waze / left the app" footgun on dense detail pages where
/// the icons sit a few pixels from editable text.
///
/// Usage:
///
///     ConfirmedURLAction(
///         url: telURL,
///         prompt: "Call \(value)?",
///         primaryLabel: "Call"
///     ) {
///         Image(systemName: "phone.fill")
///     }
struct ConfirmedURLAction<Label: View>: View {
    let url: URL
    let prompt: String
    /// Optional secondary line shown under the prompt — typically the
    /// URL itself so the user can verify what they're about to open.
    var detail: String? = nil
    var primaryLabel: String = "Open"
    @ViewBuilder var label: () -> Label

    @State private var asking = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            asking = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            prompt,
            isPresented: $asking,
            titleVisibility: .visible
        ) {
            Button(primaryLabel) {
                openURL(url)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let detail { Text(detail) }
        }
    }
}
