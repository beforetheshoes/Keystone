import SwiftUI
import ComposableArchitecture

/// Horizontal filter bar shown above a database table. Each active
/// filter renders as a chip with a type-specific editor popover; the
/// trailing `+ Filter` button adds a new filter from the available
/// columns.
struct FilterBar: View {
    @Bindable var store: StoreOf<AppFeature>
    var properties: [PropertyRow]
    /// All records in the database BEFORE filtering — used to derive
    /// the candidate value lists for `select` filters and the
    /// distinct-target list for `relation` filters when we don't have
    /// a separate read of the target db handy.
    var unfilteredRecords: [RecordRow]

    @Dependency(\.databaseClient) private var dbClient

    var body: some View {
        HStack(spacing: 8) {
            ForEach(store.filters) { filter in
                if let prop = properties.first(where: { $0.key == filter.propertyKey }) {
                    FilterChip(
                        store: store,
                        filter: filter,
                        property: prop,
                        unfilteredRecords: unfilteredRecords
                    )
                }
            }

            Menu {
                ForEach(filterableProperties) { p in
                    Button {
                        store.send(.addFilter(propertyKey: p.key))
                    } label: {
                        Label(p.name, systemImage: filterIconName(for: p.type))
                    }
                }
                if !store.filters.isEmpty {
                    Divider()
                    Button("Clear all", role: .destructive) {
                        store.send(.clearFilters)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(store.filters.isEmpty ? "Filter" : "+")
                        .font(.kstText(size: 12, weight: .semibold))
                }
                .foregroundStyle(KstColor.ink2)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(KstColor.paper1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(KstColor.ink4, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(KstColor.paper0)
        .overlay(alignment: .bottom) { KstHairline() }
    }

    /// Hide title — title is already searchable via the toolbar text
    /// search and adding a "title contains" filter would just duplicate
    /// it. Hide types we don't have editors for yet.
    private var filterableProperties: [PropertyRow] {
        properties.filter { p in
            switch p.type {
            case .title, .text, .relation, .date, .dateRange, .dateTZ,
                 .select, .multiSelect, .status, .number, .currency,
                 .checkbox:
                return true
            default:
                return false
            }
        }
    }

    private func filterIconName(for type: PropertyType) -> String {
        switch type {
        case .relation:                          return "link"
        case .date, .dateRange, .dateTZ:         return "calendar"
        case .select, .multiSelect, .status:     return "circle.dashed"
        case .number, .currency:                 return "number"
        case .checkbox:                          return "checkmark.square"
        case .title, .text:                      return "textformat"
        default:                                  return "magnifyingglass"
        }
    }
}

/// Cross-platform checkbox-style toggle. SwiftUI's `.toggleStyle(.checkbox)`
/// is macOS-only; on iOS the default toggle becomes a switch which is
/// far too bulky for a multi-select list. This is a button rendering an
/// SF symbol that flips on tap — works identically on both platforms.
private struct CheckboxRow: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? KstColor.ink0 : KstColor.ink3)
                Text(label)
                    .font(.kstText(size: 13))
                    .foregroundStyle(KstColor.ink0)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter chip

/// A single active filter as a pill in the bar. Tapping opens a popover
/// with the type-appropriate editor.
private struct FilterChip: View {
    @Bindable var store: StoreOf<AppFeature>
    let filter: Filter
    let property: PropertyRow
    let unfilteredRecords: [RecordRow]

    @State private var popoverOpen = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                popoverOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: chipIcon)
                        .font(.system(size: 10, weight: .medium))
                    Text(property.name)
                        .font(.kstText(size: 12, weight: .semibold))
                    if !summary.isEmpty {
                        Text("·")
                            .font(.kstText(size: 12))
                            .foregroundStyle(KstColor.ink3)
                        Text(summary)
                            .font(.kstText(size: 12))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(filter.predicate.isNoOp ? KstColor.ink2 : KstColor.ink0)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $popoverOpen, arrowEdge: .bottom) {
                FilterEditor(
                    store: store,
                    filter: filter,
                    property: property,
                    unfilteredRecords: unfilteredRecords
                )
                .padding(12)
                // Give the popover a real content size — without a
                // definite height, the ScrollView inside the relation /
                // select editors collapses to one row of visible
                // content. `idealHeight` lets the popover grow to fit
                // smaller lists; `maxHeight` caps it so a 200-vendor
                // database doesn't fill the screen.
                .frame(
                    minWidth: 260, idealWidth: 300,
                    minHeight: 120, idealHeight: 280, maxHeight: 480
                )
            }

            Button {
                store.send(.removeFilter(id: filter.id))
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KstColor.ink3)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(filter.predicate.isNoOp ? KstColor.paper1 : KstColor.paper2)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var chipIcon: String {
        switch property.type {
        case .relation:                       return "link"
        case .date, .dateRange, .dateTZ:      return "calendar"
        case .select, .multiSelect, .status:  return "circle.dashed"
        case .number, .currency:              return "number"
        case .checkbox:                       return "checkmark.square"
        default:                               return "textformat"
        }
    }

    /// Compact summary of the predicate value to render inside the chip
    /// without opening the editor — e.g. "3 selected", "Jan 1 – Mar 31",
    /// "$0–$500". Empty when the filter has no constraint applied.
    private var summary: String {
        switch filter.predicate {
        case .relationIsAnyOf(let ids):
            return ids.isEmpty ? "" : "\(ids.count) selected"
        case .dateRange(let from, let to):
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            switch (from, to) {
            case (nil, nil):              return ""
            case (let a?, nil):           return "from \(f.string(from: a))"
            case (nil, let b?):           return "until \(f.string(from: b))"
            case (let a?, let b?):        return "\(f.string(from: a)) – \(f.string(from: b))"
            }
        case .selectIsAnyOf(let values):
            return values.isEmpty ? "" : (values.count == 1 ? values[0] : "\(values.count) selected")
        case .textContains(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : "contains \"\(trimmed)\""
        case .numberRange(let lo, let hi):
            switch (lo, hi) {
            case (nil, nil):           return ""
            case (let a?, nil):        return "≥ \(formatNumber(a))"
            case (nil, let b?):        return "≤ \(formatNumber(b))"
            case (let a?, let b?):     return "\(formatNumber(a))–\(formatNumber(b))"
            }
        case .checkbox(let b):
            switch b {
            case nil:    return ""
            case true:   return "yes"
            case false:  return "no"
            }
        }
    }

    private func formatNumber(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(d))
            : String(format: "%.2f", d)
    }
}

// MARK: - Type-aware editor

/// Picks an editor view based on the predicate kind currently held by
/// `filter`. Each editor mutates by sending `.updateFilter(id:predicate:)`.
private struct FilterEditor: View {
    @Bindable var store: StoreOf<AppFeature>
    let filter: Filter
    let property: PropertyRow
    let unfilteredRecords: [RecordRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(property.name)
                .font(.kstText(size: 11, weight: .semibold))
                .foregroundStyle(KstColor.ink3)
                .tracking(0.6)
                .textCase(.uppercase)
            Divider()

            // The relation/select editors are scrollable lists that
            // need to fill the popover; without this the popover frame
            // collapses to the title row's height.
            Group {
            switch filter.predicate {
            case .relationIsAnyOf(let ids):
                RelationFilterEditor(
                    store: store, filter: filter, property: property, selected: ids
                )
            case .dateRange(let from, let to):
                DateRangeFilterEditor(
                    store: store, filter: filter, from: from, to: to
                )
            case .selectIsAnyOf(let values):
                SelectFilterEditor(
                    store: store, filter: filter, property: property,
                    unfilteredRecords: unfilteredRecords, selected: values
                )
            case .textContains(let str):
                TextContainsEditor(store: store, filter: filter, value: str)
            case .numberRange(let lo, let hi):
                NumberRangeEditor(store: store, filter: filter, low: lo, high: hi)
            case .checkbox(let b):
                CheckboxEditor(store: store, filter: filter, value: b)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Per-type editors

private struct RelationFilterEditor: View {
    @Bindable var store: StoreOf<AppFeature>
    let filter: Filter
    let property: PropertyRow
    let selected: [String]

    @State private var candidates: [(id: String, title: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if candidates.isEmpty {
                Text("Loading…")
                    .font(.kstText(size: 12))
                    .foregroundStyle(KstColor.ink3)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(candidates, id: \.id) { c in
                            CheckboxRow(
                                isOn: bindingForCandidate(c.id),
                                label: c.title
                            )
                        }
                    }
                    .padding(.trailing, 4) // breathing room for the
                                           // scroll-bar gutter
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadCandidates() }
    }

    private func bindingForCandidate(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                var next = selected
                if isOn { next.append(id) } else { next.removeAll { $0 == id } }
                store.send(.updateFilter(id: filter.id, predicate: .relationIsAnyOf(next)))
            }
        )
    }

    private func loadCandidates() async {
        @Dependency(\.databaseClient) var db
        // Look up the property's target database and read its records
        // to populate the candidate list. Falls back to an empty list
        // if the property's config doesn't carry `targetDatabaseID`
        // (shouldn't happen for valid relation properties).
        guard let targetDB = try? db.relationTargetDatabaseID(property.id) ?? nil else { return }
        let records = (try? db.records(targetDB)) ?? []
        candidates = records.map { ($0.id, $0.title) }.sorted { $0.title < $1.title }
    }
}

private struct DateRangeFilterEditor: View {
    @Bindable var store: StoreOf<AppFeature>
    let filter: Filter
    let from: Date?
    let to: Date?

    @State private var fromDraft: Date = Date()
    @State private var toDraft: Date = Date()
    @State private var fromOn: Bool = false
    @State private var toOn: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CheckboxRow(isOn: $fromOn, label: "From")
            if fromOn {
                DatePicker("", selection: $fromDraft, displayedComponents: .date)
                    .labelsHidden()
            }
            CheckboxRow(isOn: $toOn, label: "To")
            if toOn {
                DatePicker("", selection: $toDraft, displayedComponents: .date)
                    .labelsHidden()
            }
        }
        .onAppear {
            fromOn = from != nil
            toOn = to != nil
            if let from { fromDraft = from }
            if let to { toDraft = to }
        }
        .onChange(of: fromOn) { _, _ in commit() }
        .onChange(of: toOn) { _, _ in commit() }
        .onChange(of: fromDraft) { _, _ in commit() }
        .onChange(of: toDraft) { _, _ in commit() }
    }

    private func commit() {
        store.send(.updateFilter(
            id: filter.id,
            predicate: .dateRange(from: fromOn ? fromDraft : nil, to: toOn ? toDraft : nil)
        ))
    }
}

private struct SelectFilterEditor: View {
    @Bindable var store: StoreOf<AppFeature>
    let filter: Filter
    let property: PropertyRow
    let unfilteredRecords: [RecordRow]
    let selected: [String]

    private var distinctValues: [String] {
        let key = filter.propertyKey
        let values = unfilteredRecords.compactMap { rec -> String? in
            let v = rec.values[key] ?? ""
            return v.isEmpty ? nil : v
        }
        return Array(Set(values)).sorted()
    }

    var body: some View {
        if distinctValues.isEmpty {
            Text("No values found in current records")
                .font(.kstText(size: 12))
                .foregroundStyle(KstColor.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(distinctValues, id: \.self) { v in
                        CheckboxRow(isOn: bindingForValue(v), label: v)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bindingForValue(_ v: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(v) },
            set: { isOn in
                var next = selected
                if isOn { next.append(v) } else { next.removeAll { $0 == v } }
                store.send(.updateFilter(id: filter.id, predicate: .selectIsAnyOf(next)))
            }
        )
    }
}

private struct TextContainsEditor: View {
    @Bindable var store: StoreOf<AppFeature>
    let filter: Filter
    let value: String

    @State private var draft: String = ""

    var body: some View {
        TextField("Contains…", text: $draft)
            .textFieldStyle(.roundedBorder)
            .onAppear { draft = value }
            .onChange(of: draft) { _, new in
                store.send(.updateFilter(id: filter.id, predicate: .textContains(new)))
            }
    }
}

private struct NumberRangeEditor: View {
    @Bindable var store: StoreOf<AppFeature>
    let filter: Filter
    let low: Double?
    let high: Double?

    @State private var lowDraft: String = ""
    @State private var highDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Min").font(.kstText(size: 12)).frame(width: 36, alignment: .leading)
                TextField("any", text: $lowDraft)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Max").font(.kstText(size: 12)).frame(width: 36, alignment: .leading)
                TextField("any", text: $highDraft)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onAppear {
            lowDraft = low.map { String($0) } ?? ""
            highDraft = high.map { String($0) } ?? ""
        }
        .onChange(of: lowDraft) { _, _ in commit() }
        .onChange(of: highDraft) { _, _ in commit() }
    }

    private func commit() {
        let lo = Double(lowDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        let hi = Double(highDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        store.send(.updateFilter(id: filter.id, predicate: .numberRange(min: lo, max: hi)))
    }
}

private struct CheckboxEditor: View {
    @Bindable var store: StoreOf<AppFeature>
    let filter: Filter
    let value: Bool?

    var body: some View {
        Picker("", selection: Binding<Int>(
            get: {
                switch value { case nil: 0; case true?: 1; case false?: 2 }
            },
            set: { idx in
                let pred: FilterPredicate = switch idx {
                case 1:  .checkbox(true)
                case 2:  .checkbox(false)
                default: .checkbox(nil)
                }
                store.send(.updateFilter(id: filter.id, predicate: pred))
            }
        )) {
            Text("Any").tag(0)
            Text("Yes").tag(1)
            Text("No").tag(2)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
