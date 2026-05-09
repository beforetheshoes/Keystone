import SwiftUI
import ComposableArchitecture
import Dependencies
#if canImport(MapKit)
import MapKit
import CoreLocation
#endif

/// Hybrid trip-detail augmentation injected into `RecordDetailView` when
/// the host record's `database_id == "trips"`. Standard property fields
/// (name / notes / start_date / end_date / is_protected) render above
/// this block; the generic `RELATED` / `LINKED FROM` / `NOTES` / assets
/// sections render below it.
///
/// Four sections, in order: itinerary timeline, embedded mini-calendar,
/// route map, totals card. Each fetches its slice from the shared
/// `TripChildren` payload loaded once when `record.id` changes.
struct TripDetailAugmentation: View {
    @Bindable var store: StoreOf<AppFeature>
    var db: DBRow
    var record: RecordRow

    @Dependency(\.databaseClient) private var databaseClient

    @State private var children: TripChildren = .empty
    @State private var pins: [TripMapPin] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !itineraryItems.isEmpty {
                TripSectionHeader(title: "ITINERARY", count: itineraryItems.count)
                TripItinerarySection(items: itineraryItems) { item in
                    store.send(.setNav(.record(databaseID: item.kind.databaseID, recordID: item.id)))
                }
                .padding(.bottom, 28)
            }

            if let calendarRange = calendarRange,
               !(children.activities.isEmpty && children.lodging.isEmpty) {
                TripSectionHeader(title: "CALENDAR", count: nil)
                TripCalendarSection(
                    accent: db.accent,
                    range: calendarRange,
                    activities: children.activities,
                    lodging: children.lodging,
                    onOpen: { rec in
                        store.send(.setNav(.record(databaseID: rec.databaseID, recordID: rec.id)))
                    }
                )
                .padding(.bottom, 28)
            }

            #if canImport(MapKit)
            if #available(iOS 26.0, macOS 26.0, *), !pins.isEmpty {
                TripSectionHeader(title: "ROUTE", count: pins.count)
                TripRouteMapSection(pins: pins)
                    .padding(.bottom, 28)
            }
            #endif

            if !children.isEmpty {
                TripSectionHeader(title: "TOTAL", count: nil)
                TripTotalsCard(children: children)
                    .padding(.bottom, 28)
            }
        }
        .task(id: record.id) { await reload() }
    }

    // MARK: - Loading

    private func reload() async {
        let loaded = (try? fetchChildren(tripID: record.id)) ?? .empty
        let loadedPins = loadPins(for: loaded)
        self.children = loaded
        self.pins = loadedPins
    }

    private func fetchChildren(tripID: String) throws -> TripChildren {
        // Pass `hiddenRecordIDs` so a child that's individually
        // privacy-locked (rare — children inherit the parent's lock via
        // cascade) doesn't leak through the timeline / calendar / map.
        let links = try databaseClient.incomingRelations(tripID, store.hiddenRecordIDs)
        var activities: [RecordRow] = []
        var lodging: [RecordRow] = []
        var transportation: [RecordRow] = []
        for link in links {
            // Per RelationReads.incoming, `targetDatabaseID` carries the
            // linker's database id and `sourceRecordID` is the linker's
            // record id.
            guard let row = try databaseClient.record(link.sourceRecordID) else { continue }
            switch link.targetDatabaseID {
            case "activities":     activities.append(row)
            case "lodging":        lodging.append(row)
            case "transportation": transportation.append(row)
            default: break
            }
        }
        return TripChildren(
            activities: activities,
            lodging: lodging,
            transportation: transportation
        )
    }

    private func loadPins(for children: TripChildren) -> [TripMapPin] {
        var out: [TripMapPin] = []
        let stops: [(RecordRow, ItineraryKind)] =
            children.activities.map { ($0, .activity) }
            + children.lodging.map { ($0, .lodging) }
        for (row, kind) in stops {
            guard let json = (try? databaseClient.propertyJSON(row.id, "address")) ?? nil,
                  let value = AddressValueCodec.parse(json),
                  let lat = value.lat, let lon = value.lon else { continue }
            out.append(TripMapPin(
                id: row.id,
                title: row.title,
                kind: kind,
                tone: row.tone,
                latitude: lat,
                longitude: lon
            ))
        }
        return out
    }

    // MARK: - Derived

    private var itineraryItems: [ItineraryItem] {
        var items: [ItineraryItem] = []
        for row in children.activities {
            if let start = parseDateTZ(row.values["start"]) {
                let end = parseDateTZ(row.values["end"])
                items.append(ItineraryItem(
                    id: row.id,
                    title: row.title,
                    kind: .activity,
                    glyph: row.glyph,
                    tone: row.tone,
                    start: start,
                    end: end
                ))
            }
        }
        for row in children.lodging {
            if let start = parseDateTZ(row.values["check_in"]) {
                let end = parseDateTZ(row.values["check_out"])
                items.append(ItineraryItem(
                    id: row.id,
                    title: row.title,
                    kind: .lodging,
                    glyph: row.glyph,
                    tone: row.tone,
                    start: start,
                    end: end
                ))
            }
        }
        return items.sorted { $0.start.date < $1.start.date }
    }

    private var calendarRange: ClosedRange<Date>? {
        if let start = parsePlainDate(record.values["start_date"]),
           let end = parsePlainDate(record.values["end_date"]),
           start <= end {
            return start ... end.addingTimeInterval(24 * 60 * 60 - 1)
        }
        // Fallback: derive from earliest/latest itinerary item.
        let starts = itineraryItems.map(\.start.date)
        let ends = itineraryItems.compactMap { $0.end?.date }
        guard let lo = starts.min() else { return nil }
        let hi = (ends + starts).max() ?? lo
        return lo ... hi
    }

    private func parseDateTZ(_ raw: String?) -> DateTZValue? {
        guard let raw, !raw.isEmpty else { return nil }
        return DateValueCodec.parseTZ(raw)
    }

    private func parsePlainDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return DateValueCodec.parse(raw)
    }
}

// MARK: - Models

struct TripChildren: Equatable {
    var activities: [RecordRow]
    var lodging: [RecordRow]
    var transportation: [RecordRow]

    static let empty = TripChildren(activities: [], lodging: [], transportation: [])

    var isEmpty: Bool {
        activities.isEmpty && lodging.isEmpty && transportation.isEmpty
    }

    /// Total leg count across all transportation rows. `legs` is a JSON
    /// array of leg objects; falls back to 0 for malformed entries.
    var legCount: Int {
        transportation.reduce(0) { acc, row in
            guard let raw = row.values["legs"], !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return acc }
            return acc + arr.count
        }
    }

    /// Sum of the `cost` property across activities, lodging, and
    /// transportation. Currency editor stores plain decimal strings.
    var costTotal: Decimal {
        var total: Decimal = 0
        for group in [activities, lodging, transportation] {
            for row in group {
                guard let raw = row.values["cost"], !raw.isEmpty,
                      let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { continue }
                total += value
            }
        }
        return total
    }
}

enum ItineraryKind: Equatable {
    case activity, lodging

    var databaseID: String {
        switch self {
        case .activity: return "activities"
        case .lodging:  return "lodging"
        }
    }
}

struct ItineraryItem: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: ItineraryKind
    let glyph: String
    let tone: AccentTone
    let start: DateTZValue
    let end: DateTZValue?
}

struct TripMapPin: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: ItineraryKind
    let tone: AccentTone
    let latitude: Double
    let longitude: Double
}

// MARK: - Section header

private struct TripSectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.kstText(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(KstColor.ink2)
            if let count {
                Text("\(count)")
                    .font(.kstText(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink3)
            }
        }
        .padding(.bottom, 10)
    }
}

// MARK: - Itinerary

private struct TripItinerarySection: View {
    let items: [ItineraryItem]
    let onOpen: (ItineraryItem) -> Void

    private var groups: [(dayKey: String, dayLabel: String, items: [ItineraryItem])] {
        var buckets: [String: [ItineraryItem]] = [:]
        var labels: [String: String] = [:]
        for item in items {
            let key = ItineraryFormat.dayKey(item.start)
            let label = ItineraryFormat.dayLabel(item.start)
            buckets[key, default: []].append(item)
            labels[key] = label
        }
        return buckets.keys.sorted().map { key in
            (key, labels[key] ?? key, buckets[key]!.sorted { $0.start.date < $1.start.date })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.dayKey) { idx, group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.dayLabel)
                        .font(.kstText(size: 12, weight: .semibold))
                        .foregroundStyle(KstColor.ink1)
                        .padding(.bottom, 2)

                    ForEach(group.items) { item in
                        Button(action: { onOpen(item) }) {
                            HStack(spacing: 10) {
                                Glyph(tone: item.tone, text: item.glyph, size: 18, radius: 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.kstText(size: 13, weight: .medium))
                                        .foregroundStyle(KstColor.ink0)
                                    Text(ItineraryFormat.timeLine(for: item))
                                        .font(.kstText(size: 11))
                                        .foregroundStyle(KstColor.ink2)
                                }
                                Spacer(minLength: 0)
                                KstPill(text: item.kind == .activity ? "Activity" : "Lodging")
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    if idx < groups.count - 1 {
                        Rectangle().fill(KstColor.paper3).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}

private enum ItineraryFormat {
    /// `yyyy-MM-dd` formatted in the event's own zone — the bucket key.
    static func dayKey(_ value: DateTZValue) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = value.timezone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: value.date)
    }

    /// "Mon, Jun 3" in the event's own zone — the visible day header.
    static func dayLabel(_ value: DateTZValue) -> String {
        let f = DateFormatter()
        f.timeZone = value.timezone
        f.dateFormat = "EEE, MMM d"
        return f.string(from: value.date)
    }

    static func timeLine(for item: ItineraryItem) -> String {
        let startText = formatTime(item.start)
        if let end = item.end {
            // If end falls on a different event-local day, surface the date too.
            if dayKey(end) != dayKey(item.start) {
                return "\(startText) → \(formatDateTime(end))"
            }
            return "\(startText) – \(formatTime(end))"
        }
        return startText
    }

    private static func formatTime(_ value: DateTZValue) -> String {
        if value.isAllDay { return "All day · \(value.timezone.identifier)" }
        let f = DateFormatter()
        f.timeZone = value.timezone
        f.dateStyle = .none
        f.timeStyle = .short
        let abbr = value.timezone.abbreviation(for: value.date) ?? value.timezone.identifier
        return "\(f.string(from: value.date)) \(abbr)"
    }

    private static func formatDateTime(_ value: DateTZValue) -> String {
        if value.isAllDay { return dayLabel(value) }
        let f = DateFormatter()
        f.timeZone = value.timezone
        f.dateFormat = "MMM d · h:mm a"
        let abbr = value.timezone.abbreviation(for: value.date) ?? ""
        return abbr.isEmpty ? f.string(from: value.date) : "\(f.string(from: value.date)) \(abbr)"
    }
}

// MARK: - Calendar (embedded)

/// Wraps the shared `CalendarView` for activities + lodging. Normalizes
/// each child's date keys onto a synthetic `start`/`end` pair so the
/// calendar's anchor pairing (`start` → `end`) works for both shapes.
private struct TripCalendarSection: View {
    let accent: AccentTone
    let range: ClosedRange<Date>
    let activities: [RecordRow]
    let lodging: [RecordRow]
    let onOpen: (RecordRow) -> Void

    private var normalized: [RecordRow] {
        var out: [RecordRow] = []
        for row in activities {
            var normalized = row
            normalized.values["start"] = row.values["start"] ?? ""
            normalized.values["end"] = row.values["end"] ?? ""
            out.append(normalized)
        }
        for row in lodging {
            var normalized = row
            normalized.values["start"] = row.values["check_in"] ?? ""
            normalized.values["end"] = row.values["check_out"] ?? ""
            out.append(normalized)
        }
        return out
    }

    private var syntheticDB: DBRow {
        DBRow(
            id: "trip-calendar-virtual",
            areaID: nil,
            name: "Trip",
            pluralName: nil,
            icon: "T",
            accent: accent,
            defaultView: .calendar,
            sortIndex: 0
        )
    }

    private var syntheticProperties: [PropertyRow] {
        [
            PropertyRow(id: "trip-calendar-virtual.start", key: "start", name: "Start", type: .dateTZ, sortIndex: 0, configJSON: "{}"),
            PropertyRow(id: "trip-calendar-virtual.end",   key: "end",   name: "End",   type: .dateTZ, sortIndex: 1, configJSON: "{}"),
        ]
    }

    var body: some View {
        CalendarView(
            db: syntheticDB,
            properties: syntheticProperties,
            records: normalized,
            onOpen: onOpen,
            initialMode: .week,
            initialAnchor: range.lowerBound,
            dateRangeFilter: range
        )
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
    }
}

// MARK: - Route map

#if canImport(MapKit)
@available(iOS 26.0, macOS 26.0, *)
private struct TripRouteMapSection: View {
    let pins: [TripMapPin]

    private var initialPosition: MapCameraPosition {
        guard let region = boundingRegion else {
            return .automatic
        }
        return .region(region)
    }

    private var boundingRegion: MKCoordinateRegion? {
        guard let first = pins.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for pin in pins.dropFirst() {
            minLat = min(minLat, pin.latitude); maxLat = max(maxLat, pin.latitude)
            minLon = min(minLon, pin.longitude); maxLon = max(maxLon, pin.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latDelta = max(0.01, (maxLat - minLat) * 1.4)
        let lonDelta = max(0.01, (maxLon - minLon) * 1.4)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    var body: some View {
        Map(initialPosition: initialPosition) {
            ForEach(pins) { pin in
                Marker(
                    pin.title,
                    coordinate: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
                )
            }
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
    }
}
#endif

// MARK: - Totals

private struct TripTotalsCard: View {
    let children: TripChildren

    private var costFormatted: String {
        let total = children.costTotal
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = Locale.current.currency?.identifier ?? "USD"
        return formatter.string(from: NSDecimalNumber(decimal: total)) ?? "—"
    }

    private var summaryLine: String {
        var parts: [String] = []
        if !children.activities.isEmpty {
            parts.append("\(children.activities.count) \(children.activities.count == 1 ? "activity" : "activities")")
        }
        if !children.lodging.isEmpty {
            parts.append("\(children.lodging.count) lodging")
        }
        let legs = children.legCount
        if legs > 0 {
            parts.append("\(legs) \(legs == 1 ? "leg" : "legs")")
        } else if !children.transportation.isEmpty {
            parts.append("\(children.transportation.count) transportation")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(costFormatted)
                .font(.kstDisplay(size: 28, weight: .semibold))
                .foregroundStyle(KstColor.ink0)
                .monospacedDigit()
            if !summaryLine.isEmpty {
                Text(summaryLine)
                    .font(.kstText(size: 12))
                    .foregroundStyle(KstColor.ink2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}
