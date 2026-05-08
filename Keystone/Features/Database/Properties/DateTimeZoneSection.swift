import SwiftUI

/// Renders a parsed `DateTZValue` as two lines: event-local time on top,
/// viewer-local time underneath when the viewer's tz differs from the
/// event's. Reusable from `RecordDetailView`, table cells, and any future
/// place that wants a consistent date_tz display.
///
/// Read-only on its own — interactive editing lives in
/// `DateTimeZoneField` inside `PropertyValueField`. Tap-to-edit at the
/// row level is a parent-view concern.
struct DateTimeZoneSection: View {
    let value: DateTZValue

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(DateValueCodec.displayEventLocal(value))
                .font(.kstText(size: 13))
                .foregroundStyle(KstColor.ink0)

            if let viewerLine = DateValueCodec.displayViewerLocal(value) {
                Text("Your time: \(viewerLine)")
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink2)
            }
        }
    }
}
