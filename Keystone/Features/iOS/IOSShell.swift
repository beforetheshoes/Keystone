#if !os(macOS)
import SwiftUI
import UIKit
import ComposableArchitecture

/// Top-level adaptive shell for iOS. iPhone (compact horizontal size class)
/// gets the custom 5-tab layout designed in `mobile.jsx`. iPad / iPhone Plus
/// landscape (regular size class) gets the NavigationSplitView with sidebar.
struct IOSShell: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        Group {
            if hSize == .regular {
                iPadShell(store: store)
            } else {
                iPhoneTabsView(store: store)
            }
        }
        .background(KstColor.paper0)
    }
}
#endif
