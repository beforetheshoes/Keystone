import SwiftUI

struct KstToolbar<Trailing: View>: View {
    struct Crumb {
        let label: String
        let action: (() -> Void)?
    }

    var crumbs: [Crumb]
    @ViewBuilder var trailing: () -> Trailing

    /// Convenience: plain non-clickable breadcrumb labels.
    init(breadcrumb: [String], @ViewBuilder trailing: @escaping () -> Trailing) {
        self.crumbs = breadcrumb.map { Crumb(label: $0, action: nil) }
        self.trailing = trailing
    }

    /// Each crumb may carry a tap handler. Terminal (last) crumb is always
    /// rendered as plain text regardless of whether it has an action, since
    /// you're already there.
    init(crumbs: [Crumb], @ViewBuilder trailing: @escaping () -> Trailing) {
        self.crumbs = crumbs
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, c in
                    if idx > 0 {
                        Text("/").foregroundStyle(KstColor.ink3)
                    }
                    let isLast = idx == crumbs.count - 1
                    if let action = c.action, !isLast {
                        Button(action: action) {
                            Text(c.label)
                                .font(.kstText(size: 13, weight: .medium))
                                .foregroundStyle(KstColor.ink2)
                        }
                        .buttonStyle(CrumbButtonStyle())
                    } else {
                        Text(c.label)
                            .font(.kstText(size: 13, weight: isLast ? .semibold : .medium))
                            .foregroundStyle(isLast ? KstColor.ink0 : KstColor.ink2)
                    }
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(KstColor.paper0)
        .overlay(alignment: .bottom) { KstHairline() }
    }
}

private struct CrumbButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(hovering ? KstColor.paper2 : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}
