import SwiftUI

/// One row in the Settings → API Keys section. Bound to an `APIKeyKind`,
/// loads the saved value from the Keychain on appear, saves on blur, and
/// surfaces a `Test` button that fires a no-op API call against the saved
/// key so the user can confirm it actually works before depending on it.
struct APIKeyRow: View {
    let kind: APIKeyKind

    @State private var value: String = ""
    @State private var savedValue: String = ""
    @State private var status: TestStatus = .idle
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(kind.displayName)
                    .font(.kstText(size: 13, weight: .medium))
                    .frame(minWidth: 140, alignment: .leading)

                SecureField("Paste key", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.kstMono(size: 12))
                    .focused($isFocused)
                    .onSubmit { commit() }

                Button("Test") {
                    Task { await runTest() }
                }
                .buttonStyle(.bordered)
                .disabled(savedValue.isEmpty || status == .testing)

                statusIcon
                    .frame(width: 16)
            }

            Text(kind.purpose)
                .font(.kstText(size: 11))
                .foregroundStyle(KstColor.ink2)
        }
        .onAppear {
            let stored = APIKeys.get(kind) ?? ""
            value = stored
            savedValue = stored
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedValue else { return }
        APIKeys.set(kind, trimmed.isEmpty ? nil : trimmed)
        savedValue = trimmed
        status = .idle
    }

    private func runTest() async {
        // Always test what's saved — that's what the next enrichment pass
        // will see. If the user just typed a key, commit() runs first via
        // the focus change before the Test button enables.
        commit()
        guard !savedValue.isEmpty else { return }
        status = .testing
        let ok: Bool
        switch kind {
        case .googleBooks:
            ok = await testGoogleBooksKey()
        case .tmdb:
            ok = await TMDBClient.testKey()
        }
        status = ok ? .success : .failure
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func testGoogleBooksKey() async -> Bool {
        guard let key = APIKeys.get(.googleBooks)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return false }
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q",          value: "isbn:9780553418026"),  // a single known book; minimal payload
            URLQueryItem(name: "maxResults", value: "1"),
            URLQueryItem(name: "key",        value: key),
        ]
        guard let url = components.url else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private enum TestStatus: Equatable {
        case idle
        case testing
        case success
        case failure
    }
}
