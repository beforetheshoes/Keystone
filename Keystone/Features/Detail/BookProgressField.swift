import SwiftUI
import ComposableArchitecture

/// Reading-progress block for a Books detail view. Two modes:
///
/// - **Pages**: "Page X of Y" with ± steppers on X. Y defaults to
///   `page_count`, but the user can override via the `readable_pages`
///   property — useful when the book's total page count includes
///   appendices, index, etc.
/// - **Percent**: 0–100 number field with a slider.
///
/// In both modes a horizontal progress bar surfaces the same number
/// the gallery cover overlays.
struct BookProgressField: View {
    var store: StoreOf<AppFeature>
    var record: RecordRow

    private var mode: ProgressMode {
        let raw = (record.values["progress_mode"] ?? "").trimmingCharacters(in: .whitespaces)
        return raw == "percent" ? .percent : .pages
    }

    private enum ProgressMode: String { case pages, percent }

    private var pageCount: Int {
        Int(record.values["page_count"] ?? "") ?? 0
    }

    private var readablePages: Int {
        let raw = record.values["readable_pages"] ?? ""
        if let n = Int(raw), n > 0 { return n }
        return pageCount
    }

    private var currentPage: Int {
        Int(record.values["current_page"] ?? "") ?? 0
    }

    private var percent: Int {
        Int(record.values["progress_percent"] ?? "") ?? 0
    }

    private var fraction: Double {
        switch mode {
        case .pages:
            guard readablePages > 0 else { return 0 }
            return min(1.0, Double(currentPage) / Double(readablePages))
        case .percent:
            return min(1.0, Double(percent) / 100.0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Reading progress")
                    .font(.kstText(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(KstColor.ink2)
                Spacer()
                modePicker
            }

            switch mode {
            case .pages:
                pagesBody
            case .percent:
                percentBody
            }

            ProgressBar(fraction: fraction, tone: record.tone)
                .frame(height: 6)
        }
        .padding(14)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }

    private var modePicker: some View {
        Picker("", selection: Binding<ProgressMode>(
            get: { mode },
            set: { newMode in
                store.send(.updatePropertyValue(
                    recordID: record.id,
                    key: "progress_mode",
                    value: newMode.rawValue
                ))
            }
        )) {
            Text("Pages").tag(ProgressMode.pages)
            Text("Percent").tag(ProgressMode.percent)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
    }

    private var pagesBody: some View {
        HStack(spacing: 10) {
            Button { adjustPage(by: -1) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
            TextField("0", text: Binding(
                get: { String(currentPage) },
                set: { newRaw in
                    let n = max(0, min(readablePages, Int(newRaw) ?? 0))
                    setCurrentPage(n)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .monospacedDigit()
            Text("of")
                .font(.kstText(size: 12))
                .foregroundStyle(KstColor.ink2)
            ReadablePagesField(store: store, record: record, currentReadable: readablePages, pageCount: pageCount)
            Button { adjustPage(by: 1) } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
            Text("\(Int(fraction * 100))%")
                .font(.kstText(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(KstColor.ink0)
        }
    }

    private var percentBody: some View {
        HStack(spacing: 10) {
            TextField("0", text: Binding(
                get: { String(percent) },
                set: { newRaw in
                    let n = max(0, min(100, Int(newRaw) ?? 0))
                    store.send(.updatePropertyValue(
                        recordID: record.id,
                        key: "progress_percent",
                        value: String(n)
                    ))
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .monospacedDigit()
            Text("%")
                .font(.kstText(size: 12))
                .foregroundStyle(KstColor.ink2)
            Spacer()
        }
    }

    private func adjustPage(by delta: Int) {
        let next = max(0, min(readablePages, currentPage + delta))
        setCurrentPage(next)
    }

    private func setCurrentPage(_ value: Int) {
        store.send(.updatePropertyValue(
            recordID: record.id,
            key: "current_page",
            value: String(value)
        ))
    }
}

private struct ReadablePagesField: View {
    var store: StoreOf<AppFeature>
    var record: RecordRow
    var currentReadable: Int
    var pageCount: Int

    @State private var draft: String = ""

    var body: some View {
        TextField("\(pageCount)", text: $draft, onCommit: commit)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .monospacedDigit()
            .onAppear {
                draft = currentReadable > 0 ? String(currentReadable) : ""
            }
            .onChange(of: currentReadable) { _, new in
                draft = new > 0 ? String(new) : ""
            }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        let value = (Int(trimmed) ?? 0) > 0 ? trimmed : ""
        // Pass blank when the user clears the override — the field
        // falls back to `page_count`.
        store.send(.updatePropertyValue(
            recordID: record.id,
            key: "readable_pages",
            value: value
        ))
    }
}

/// Horizontal progress bar used by the book detail page's progress
/// block and by the stats "currently reading / watching" cards.
/// `internal` (vs file-private) so stats views in the Stats/ folder
/// can render the same shape without re-implementing it.
struct ProgressBar: View {
    var fraction: Double
    var tone: AccentTone

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(KstColor.paper2)
                Capsule()
                    .fill(tone.base)
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
        }
    }
}
