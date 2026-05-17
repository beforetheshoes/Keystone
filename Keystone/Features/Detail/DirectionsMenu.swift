import SwiftUI

/// Pop-up menu rendered next to an `.address` property's value. Opens
/// directions to that address in the user's preferred maps app —
/// Apple Maps, Google Maps, Waze, or OpenStreetMap. When the stored
/// value isn't a parseable address (or is empty) the menu hides
/// itself entirely so the property row doesn't show a dangling icon.
///
/// We can't read the user's default maps app on macOS / iOS, so the
/// menu offers all four. URL schemes are universal across platforms.
struct DirectionsMenu: View {
    var rawValue: String

    @State private var pending: Destination?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let address = AddressValueCodec.parse(rawValue) ?? Self.plainAddress(from: rawValue) {
            Menu {
                ForEach(Self.destinations(for: address)) { dest in
                    Button {
                        // Stage the pick; the confirmation dialog
                        // below handles the actual `openURL` so a
                        // mis-tap on the menu doesn't yank the user
                        // out of Keystone into another app.
                        pending = dest
                    } label: {
                        Label(dest.label, systemImage: dest.symbol)
                    }
                }
            } label: {
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(KstColor.ink2)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: KstRadius.r1, style: .continuous)
                            .fill(KstColor.paper1)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .help("Get directions to \(address.display)")
            .confirmationDialog(
                "Open directions in \(pending?.label ?? "Maps")?",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                titleVisibility: .visible,
                presenting: pending
            ) { dest in
                Button("Open") { openURL(dest.url) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(address.display)
            }
        }
    }

    /// Fallback when the stored value is a plain string (not a MapKit-
    /// structured JSON object). We don't have coordinates in that
    /// case, but the display text is enough for every maps app's
    /// search-by-address fallback.
    private static func plainAddress(from raw: String) -> AddressValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AddressValue(
            display: trimmed,
            street: nil, city: nil, region: nil, postal: nil, country: nil,
            lat: nil, lon: nil, placeID: nil
        )
    }

    struct Destination: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let url: URL
    }

    /// Build the per-app URL list. Apple Maps first (native default
    /// on macOS / iOS), then Google, Waze, OSM. When the address has
    /// coordinates we hand them off — every app handles
    /// `lat,lon` more reliably than free-text addresses.
    private static func destinations(for address: AddressValue) -> [Destination] {
        var out: [Destination] = []

        let coordPair: String? = {
            if let lat = address.lat, let lon = address.lon {
                return "\(lat),\(lon)"
            }
            return nil
        }()
        let encoded = address.display.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? address.display

        // Apple Maps — `maps.apple.com` works on every Apple platform
        // and opens the system Maps app via the deep link handler.
        if let coord = coordPair,
           let url = URL(string: "http://maps.apple.com/?daddr=\(coord)") {
            out.append(.init(id: "apple", label: "Apple Maps",
                             symbol: "map", url: url))
        } else if let url = URL(string: "http://maps.apple.com/?daddr=\(encoded)") {
            out.append(.init(id: "apple", label: "Apple Maps",
                             symbol: "map", url: url))
        }

        // Google Maps Universal Link — opens the Google Maps app when
        // installed, else falls through to the web map.
        let googleDest = coordPair ?? encoded
        if let url = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(googleDest)") {
            out.append(.init(id: "google", label: "Google Maps",
                             symbol: "globe", url: url))
        }

        // Waze — requires coordinates for the navigate-true deep link;
        // fall back to the search URL when we only have free text.
        if let coord = coordPair,
           let url = URL(string: "https://waze.com/ul?ll=\(coord)&navigate=yes") {
            out.append(.init(id: "waze", label: "Waze",
                             symbol: "car.fill", url: url))
        } else if let url = URL(string: "https://waze.com/ul?q=\(encoded)") {
            out.append(.init(id: "waze", label: "Waze",
                             symbol: "car.fill", url: url))
        }

        // OpenStreetMap — no native navigate intent, but the
        // `directions` page resolves `to=` to a search.
        if let coord = coordPair,
           let url = URL(string: "https://www.openstreetmap.org/directions?to=\(coord)") {
            out.append(.init(id: "osm", label: "OpenStreetMap",
                             symbol: "globe.americas", url: url))
        } else if let url = URL(string: "https://www.openstreetmap.org/search?query=\(encoded)") {
            out.append(.init(id: "osm", label: "OpenStreetMap",
                             symbol: "globe.americas", url: url))
        }

        return out
    }
}
