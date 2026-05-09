import SwiftUI
import GRDB
import Dependencies
@preconcurrency import SQLiteData

/// Snapshot view of next-due / overdue maintenance for every vehicle.
/// Reads catalog + events + vehicle snapshots on appear and renders a
/// per-vehicle table grouped by vehicle. Tapping a row triggers
/// `onOpenRecord` which the caller can wire to deep-navigation.
///
/// Kept independent of `AppFeature`'s store so the view can be hosted
/// from multiple navigation targets (vehicle detail, dedicated tab,
/// etc.) without dragging the full TCA root in.
struct MaintenanceScheduleView: View {
    var onOpenRecord: ((_ databaseID: String, _ recordID: String) -> Void)? = nil
    /// Fired when the user taps "+ Log service" on a vehicle card.
    /// Caller is expected to create a blank `vehicle_maintenance`
    /// record, set its `vehicle` relation, and navigate to its detail
    /// for the user to fill in the rest. Optional so the view can be
    /// hosted in contexts (previews, sheets) that don't need it.
    var onLogService: ((_ vehicleID: String) -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var vehicles: [VehicleSnapshot] = []
    @State private var statusesByVehicle: [String: [MaintenanceStatus]] = [:]
    @State private var loaded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if !loaded {
                    Text("Loading…").foregroundStyle(.secondary)
                } else if vehicles.isEmpty {
                    Text("No vehicles in the workspace yet.").foregroundStyle(.secondary)
                }
                ForEach(vehicles) { vehicle in
                    VehicleCard(
                        vehicle: vehicle,
                        statuses: statusesByVehicle[vehicle.id] ?? [],
                        compact: hSize != .regular,
                        onLogService: { onLogService?(vehicle.id) },
                        onOpenCatalog: { catalogID in onOpenRecord?("service_catalog", catalogID) }
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task { reload() }
    }

    private func reload() {
        @Dependency(\.defaultDatabase) var database
        do {
            let payload: (vehicles: [VehicleSnapshot], byVehicle: [String: [MaintenanceStatus]]) = try database.read { db in
                let catalog = try MaintenanceReads.catalogItems(db)
                let events = try MaintenanceReads.events(db)
                let vehicles = try MaintenanceReads.vehicleSnapshots(db)
                let engine = MaintenanceStatusEngine()
                var by: [String: [MaintenanceStatus]] = [:]
                for v in vehicles {
                    by[v.id] = engine.computeStatuses(vehicle: v, catalog: catalog, events: events)
                }
                return (vehicles, by)
            }
            self.vehicles = payload.vehicles
            self.statusesByVehicle = payload.byVehicle
            self.loaded = true
        } catch {
            self.loaded = true
        }
    }
}

// MARK: - Vehicle card

private struct VehicleCard: View {
    let vehicle: VehicleSnapshot
    let statuses: [MaintenanceStatus]
    let compact: Bool
    var onLogService: () -> Void
    var onOpenCatalog: (_ catalogID: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if statuses.isEmpty {
                Text("No catalog items apply to this vehicle.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if compact {
                CompactStatusList(statuses: statuses, onOpenCatalog: onOpenCatalog)
            } else {
                MaintenanceTable(statuses: statuses, onOpenCatalog: onOpenCatalog)
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(vehicle.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                if let m = vehicle.currentMileage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(m.formatted()) mi")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        if let d = vehicle.currentMileageAsOf {
                            Text("last reading \(formatDate(d))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            Button {
                onLogService()
            } label: {
                Label("Log service", systemImage: "plus.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Regular-width grid table

private struct MaintenanceTable: View {
    let statuses: [MaintenanceStatus]
    var onOpenCatalog: (_ catalogID: String) -> Void

    private let statusWidth: CGFloat = 100
    private let dateWidth: CGFloat = 116
    private let mileageWidth: CGFloat = 116

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 0) {
            // Header
            GridRow {
                Text("STATUS").frame(width: statusWidth, alignment: .leading)
                Text("SERVICE").frame(maxWidth: .infinity, alignment: .leading)
                Text("LAST DATE").frame(width: dateWidth, alignment: .leading)
                Text("LAST MILEAGE").frame(width: mileageWidth, alignment: .leading)
                Text("DUE DATE").frame(width: dateWidth, alignment: .leading)
                Text("DUE MILEAGE").frame(width: mileageWidth, alignment: .leading)
            }
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            Divider().gridCellColumns(6)

            ForEach(Array(statuses.enumerated()), id: \.element.catalogID) { _, status in
                Button {
                    onOpenCatalog(status.catalogID)
                } label: {
                    GridRow(alignment: .firstTextBaseline) {
                        StatusBadge(kind: status.kind)
                            .frame(width: statusWidth, alignment: .leading)

                        Text(status.title)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        cell(text: status.lastEventDate.map(formatDate),
                             fallback: "never",
                             width: dateWidth,
                             highlighted: false)

                        cell(text: status.lastEventMileage.map { "\($0.formatted())" },
                             fallback: "—",
                             width: mileageWidth,
                             highlighted: false)

                        cell(text: status.nextDueDate.map(formatDate),
                             fallback: "—",
                             width: dateWidth,
                             highlighted: triggersDateColumn(status))

                        mileageDueCell(status: status)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().gridCellColumns(6).opacity(0.4)
            }
        }
    }

    /// "Did the date column drive this status?" Pink/red/orange tint
    /// if so. Visual signal of *why* the row is flagged.
    private func triggersDateColumn(_ s: MaintenanceStatus) -> Bool {
        switch s.kind {
        case .overdue, .dueSoon: return true
        default: return false
        }
    }

    @ViewBuilder
    private func cell(text: String?, fallback: String, width: CGFloat, highlighted: Bool) -> some View {
        let display = text ?? fallback
        Text(display)
            .font(.body)
            .foregroundStyle(text == nil ? .secondary : .primary)
            .monospacedDigit()
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, highlighted ? 6 : 0)
            .padding(.vertical, highlighted ? 3 : 0)
            .background(
                highlighted ? AnyShapeStyle(Color.orange.opacity(0.18)) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }

    /// Due-mileage cell with optional `MISSED` annotation. If the
    /// status was triggered by the mileage signal (later logged
    /// service crossed the threshold), the cell shows the threshold
    /// AND a small caption with the evidence event mileage. The
    /// background highlight matches the MISSED status color.
    @ViewBuilder
    private func mileageDueCell(status: MaintenanceStatus) -> some View {
        let nextDueText = status.nextDueMileage.map { "\($0.formatted())" }
        VStack(alignment: .leading, spacing: 2) {
            Text(nextDueText ?? "—")
                .foregroundStyle(nextDueText == nil ? .secondary : .primary)
            if let evidence = status.missedWindowEvidence {
                Text("crossed at \(evidence.eventMileage.formatted())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .monospacedDigit()
        .frame(width: mileageWidth, alignment: .leading)
        .padding(.horizontal, status.kind == .missedWindow ? 6 : 0)
        .padding(.vertical, status.kind == .missedWindow ? 3 : 0)
        .background(
            status.kind == .missedWindow
                ? AnyShapeStyle(Color.pink.opacity(0.18))
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
    }
}

// MARK: - Compact (iPhone) list

private struct CompactStatusList: View {
    let statuses: [MaintenanceStatus]
    var onOpenCatalog: (_ catalogID: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(statuses.enumerated()), id: \.element.catalogID) { idx, status in
                Button {
                    onOpenCatalog(status.catalogID)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        StatusBadge(kind: status.kind)
                            .frame(width: 88, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.title).font(.subheadline)
                            CompactRow(label: "Last", date: status.lastEventDate, mileage: status.lastEventMileage, neverWording: "never")
                            CompactRow(label: "Due", date: status.nextDueDate, mileage: status.nextDueMileage, neverWording: "—")
                            if let evidence = status.missedWindowEvidence {
                                Text("crossed at \(evidence.eventMileage.formatted()) mi (\(formatDate(evidence.eventDate)))")
                                    .font(.caption2)
                                    .foregroundStyle(.pink)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if idx < statuses.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
    }
}

private struct CompactRow: View {
    let label: String
    let date: Date?
    let mileage: Int?
    let neverWording: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(label):").foregroundStyle(.secondary)
            if let date {
                Text(formatDate(date))
            } else {
                Text(neverWording).foregroundStyle(.secondary)
            }
            if let mileage {
                Text("@ \(mileage.formatted()) mi").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

// MARK: - Status badge

private struct StatusBadge: View {
    let kind: MaintenanceStatusKind

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    private var label: String {
        switch kind {
        case .overdue:       return "OVERDUE"
        case .missedWindow:  return "MISSED"
        case .dueSoon:       return "DUE SOON"
        case .never:         return "NEVER"
        case .future:        return "FUTURE"
        }
    }

    private var color: Color {
        switch kind {
        case .overdue:       return .red
        case .missedWindow:  return .pink
        case .dueSoon:       return .orange
        case .never:         return .yellow
        case .future:        return .green.opacity(0.8)
        }
    }
}

// MARK: - Date formatting (file-level so all subviews share it)

private func formatDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}
