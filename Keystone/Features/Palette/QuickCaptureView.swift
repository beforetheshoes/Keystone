import SwiftUI
import ComposableArchitecture

struct QuickCaptureView: View {
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { store.send(.closeCapture) }

            VStack {
                Spacer().frame(height: 110)
                card
                    .frame(width: 480)
                Spacer()
            }
        }
        .onAppear { focused = true }
        #if os(macOS)
        .onExitCommand { store.send(.closeCapture) }
        #endif
    }

    private var card: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK CAPTURE")
                    .font(.kstText(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(KstColor.ink2)
                TextField("New \(store.captureKind.rawValue)…", text: $store.captureName)
                    .textFieldStyle(.plain)
                    .font(.kstDisplay(size: 22, weight: .medium))
                    .foregroundStyle(KstColor.ink0)
                    .focused($focused)
                    .onSubmit { store.send(.captureSubmit) }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(KstColor.paper3).frame(height: 0.5)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(AppFeature.CaptureKind.allCases, id: \.self) { kind in
                    Button(action: { store.send(.captureKindChanged(kind)) }) {
                        HStack(spacing: 8) {
                            Glyph(tone: kind.accent, text: kind.icon, size: 18, radius: 4)
                            Text(kind.label)
                                .font(.kstText(size: 12.5, weight: .medium))
                                .foregroundStyle(KstColor.ink1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(store.captureKind == kind ? KstColor.paper2 : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)

            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Text("Saves to ").foregroundStyle(KstColor.ink2)
                    Text("~/Keystone/\(store.captureKind.saveKind)")
                        .foregroundStyle(KstColor.ink0)
                        .fontWeight(.semibold)
                }
                .font(.kstText(size: 11))
                Spacer()
                Text("↵ create").font(.kstMono(size: 11)).foregroundStyle(KstColor.ink2)
                Text("esc cancel").font(.kstMono(size: 11)).foregroundStyle(KstColor.ink2)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(KstColor.paper1)
            .overlay(alignment: .top) { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }
        }
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r4, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r4, style: .continuous))
        .kstShadowPop()
    }
}
