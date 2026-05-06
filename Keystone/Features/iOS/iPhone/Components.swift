#if !os(macOS)
import SwiftUI

/// Section title used between cards on the iPhone Home / Profile screens.
struct iOSSectionTitle: View {
    var title: String
    var body: some View {
        Text(title.uppercased())
            .font(.kstText(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(KstColor.ink2)
            .padding(.horizontal, 4)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Cerulean-soft 44×44 date pill rendered next to events on the iPhone Home.
struct DateBadgeMobile: View {
    var date: String   // e.g. "Jan 30, 2026"
    var body: some View {
        let parts = date.split(separator: " ", maxSplits: 1).map(String.init)
        let mon = parts.first ?? ""
        let day: String = {
            guard parts.count > 1 else { return "" }
            return parts[1]
                .replacingOccurrences(of: ",", with: "")
                .split(separator: " ")
                .first.map(String.init) ?? ""
        }()
        VStack(spacing: 0) {
            Text(mon.uppercased())
                .font(.kstText(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(KstColor.ceruleanInk)
            Text(day)
                .font(.kstDisplay(size: 18, weight: .semibold))
                .foregroundStyle(KstColor.ceruleanInk)
        }
        .frame(width: 44, height: 44)
        .background(KstColor.ceruleanSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Generic rounded card with hairline-separated rows, used by Home, Detail, etc.
/// Rows are provided as a builder; the container handles the corner radius +
/// border and inserts a 0.5pt paper3 separator between every adjacent pair.
struct iOSCardList<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(_iOSCardSeparatorLayout()) {
                content()
            }
        }
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Layout that injects 0.5pt hairline separators between siblings.
private struct _iOSCardSeparatorLayout: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle()
                        .fill(KstColor.paper3)
                        .frame(height: 0.5)
                }
            }
        }
    }
}

/// Full-width row used inside `iOSCardList`. Tap target spans the full width.
struct iOSCardRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.kstText(size: 15, weight: .semibold))
                        .foregroundStyle(KstColor.ink0)
                    if let subtitle {
                        Text(subtitle)
                            .font(.kstText(size: 12))
                            .foregroundStyle(KstColor.ink2)
                    }
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Trailing chevron used on most card rows.
struct iOSChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(KstColor.ink3)
    }
}

/// Cerulean-soft action tile (Call / Message / Email) used in the iPhone detail.
struct iOSActionTile: View {
    var systemImage: String
    var label: String
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                Text(label)
                    .font(.kstText(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(enabled ? KstColor.ceruleanInk : KstColor.ink3)
            .background(enabled ? KstColor.ceruleanSoft : KstColor.paper2)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
#endif
