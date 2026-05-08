import Foundation

/// Parsed `address` property value. The structured fields come from a
/// MapKit autocomplete pick (`AddressAutocompleteField`); free-form text
/// addresses surface as the `display` field only with the rest nil.
struct AddressValue: Equatable, Sendable {
    var display: String
    var street: String?
    var city: String?
    var region: String?
    var postal: String?
    var country: String?
    var lat: Double?
    var lon: Double?
    var placeID: String?
}

/// JSON encode/decode + one-line composition for `address` properties.
enum AddressValueCodec {
    /// Parse a JSON object. Returns nil for invalid JSON, missing
    /// `display`, or empty input — callers treat that as plain text and
    /// store via the `text_value` column directly.
    static func parse(_ raw: String) -> AddressValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let display = (obj["display"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !display.isEmpty else { return nil }
        return AddressValue(
            display: display,
            street:  (obj["street"]   as? String).flatMap(nonEmpty),
            city:    (obj["city"]     as? String).flatMap(nonEmpty),
            region:  (obj["region"]   as? String).flatMap(nonEmpty),
            postal:  (obj["postal"]   as? String).flatMap(nonEmpty),
            country: (obj["country"]  as? String).flatMap(nonEmpty),
            lat:     obj["lat"]       as? Double,
            lon:     obj["lon"]       as? Double,
            placeID: (obj["place_id"] as? String).flatMap(nonEmpty)
        )
    }

    /// Encode for storage in `json_value`. Drops empty/nil fields to keep
    /// the row small and the diff readable in SQL inspection.
    static func encode(_ value: AddressValue) -> String {
        var obj: [String: Any] = ["display": value.display]
        if let v = value.street,  !v.isEmpty { obj["street"]   = v }
        if let v = value.city,    !v.isEmpty { obj["city"]     = v }
        if let v = value.region,  !v.isEmpty { obj["region"]   = v }
        if let v = value.postal,  !v.isEmpty { obj["postal"]   = v }
        if let v = value.country, !v.isEmpty { obj["country"]  = v }
        if let lat = value.lat              { obj["lat"]      = lat }
        if let lon = value.lon              { obj["lon"]      = lon }
        if let v = value.placeID, !v.isEmpty { obj["place_id"] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"display":"\#(value.display)"}"#
        }
        return str
    }

    /// Compose a one-line display from structured fields. Used when a
    /// MapKit lookup returns structured data without a pre-formatted line.
    /// Order: street · city · region · postal · country, joined by ", ",
    /// dropping nil/empty pieces.
    static func oneLine(from value: AddressValue) -> String {
        let parts: [String?] = [value.street, value.city, value.region, value.postal, value.country]
        let joined = parts.compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return joined.isEmpty ? value.display : joined
    }

    private static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
