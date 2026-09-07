import CodexRunwayCore
import Foundation
import SwiftUI

struct NetworkProxyDraft: Equatable {
    var mode: NetworkProxyMode
    var host: String
    var port: String
    var usesAuthentication: Bool
    var username = ""
    var password = ""
    var credentialID: String?

    init(_ configuration: NetworkProxyConfiguration = NetworkProxyConfiguration()) {
        mode = configuration.mode
        host = configuration.host
        port = configuration.port > 0 ? String(configuration.port) : ""
        usesAuthentication = configuration.usesAuthentication
        credentialID = configuration.credentialID
    }

    func configuration() throws -> NetworkProxyConfiguration {
        let number = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
        guard mode == .system || number != nil else { throw NetworkProxyError.invalidPort }
        return try NetworkProxyConfiguration(
            mode: mode, host: host, port: number ?? 0,
            usesAuthentication: usesAuthentication, credentialID: credentialID).validated()
    }

    var enteredCredentials: NetworkProxyCredentials? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        return NetworkProxyCredentials(username: username, password: password)
    }
}

@MainActor
struct NetworkProxySettingsView: View {
    @ObservedObject var settings: RunwaySettings
    var onLayoutChange: () -> Void = {}
    @State private var draft = NetworkProxyDraft()
    @State private var alertTitle: L10nKey?
    @State private var alertMessage: L10nKey?
    @State private var isTesting = false
    @State private var connectionTest: Task<Void, Never>?

    private var l10n: L10n { settings.l10n }

    private var isAlertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 {
                alertTitle = nil
                alertMessage = nil
            }})
    }

    init(settings: RunwaySettings, onLayoutChange: @escaping () -> Void = {}) {
        self.settings = settings
        self.onLayoutChange = onLayoutChange
        _draft = State(initialValue: NetworkProxyDraft(settings.networkProxy))
    }

    var body: some View {
        SettingsSection {
            SectionLabel(l10n.text(.networkProxy))
            editor.disabled(isTesting)
            if let error = settings.proxyError {
                Text(l10n.text(error.l10nKey))
                    .font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .textFieldStyle(.roundedBorder)
        .alert(l10n.text(alertTitle ?? .networkProxy), isPresented: isAlertPresented) {
            Button(l10n.text(.ok), role: .cancel) {}
        } message: {
            Text(l10n.text(alertMessage ?? .ok))
        }
        .onAppear { draft = NetworkProxyDraft(settings.networkProxy) }
        .onChange(of: draft.mode) { _ in onLayoutChange() }
        .onChange(of: draft.usesAuthentication) { _ in onLayoutChange() }
        .onDisappear {
            connectionTest?.cancel()
            connectionTest = nil
            draft.username = ""
            draft.password = ""
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrailingControlRow(title: l10n.text(.networkProxyMode)) {
                Picker(l10n.text(.networkProxyMode), selection: editing(\.mode)) {
                    Text(l10n.text(.networkProxySystem)).tag(NetworkProxyMode.system)
                    Text(l10n.text(.networkProxyHTTP)).tag(NetworkProxyMode.http)
                    Text(l10n.text(.networkProxySOCKS5)).tag(NetworkProxyMode.socks5)
                }
                .labelsHidden()
            }
            if draft.mode != .system {
                addressFields
                TrailingControlRow(title: l10n.text(.networkProxyAuthentication)) {
                    Toggle(l10n.text(.networkProxyAuthentication), isOn: editing(\.usesAuthentication))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if draft.usesAuthentication { authenticationFields }
            }
        }
    }

    private var addressFields: some View {
        VStack(spacing: 10) {
            TrailingControlRow(title: l10n.text(.networkProxyHost)) {
                TextField("127.0.0.1", text: editing(\.host))
                    .accessibilityLabel(l10n.text(.networkProxyHost))
            }
            TrailingControlRow(title: l10n.text(.networkProxyPort)) {
                TextField("8080", text: editing(\.port))
                    .accessibilityLabel(l10n.text(.networkProxyPort))
            }
        }
    }

    private var authenticationFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TrailingControlRow(title: l10n.text(.networkProxyUsername)) {
                TextField(l10n.text(.networkProxyUsername), text: editing(\.username))
            }
            TrailingControlRow(title: l10n.text(.networkProxyPassword)) {
                SecureField(l10n.text(.networkProxyPassword), text: editing(\.password))
            }
            if draft.credentialID != nil {
                Text(l10n.text(.networkProxySavedCredentials))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    Button(l10n.text(.networkProxyLoadCredentials), action: loadCredentials)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(l10n.text(.networkProxySave), action: save)
                .buttonStyle(.borderedProminent)
            Button(l10n.text(isTesting ? .networkProxyTesting : .networkProxyTest), action: testConnection)
                .buttonStyle(.bordered)
                .help(l10n.text(.networkProxyTestScope))
            if isTesting { ProgressView().controlSize(.small) }
        }
        .disabled(isTesting)
    }

    private func loadCredentials() {
        do {
            let credentials = try settings.loadSavedProxyCredentials()
            draft.username = credentials.username
            draft.password = credentials.password
        } catch { present(.networkProxyLoadCredentials, error: error) }
    }

    private func save() {
        do {
            let cleanedUp = try settings.saveNetworkProxy(
                draft.configuration(), credentials: draft.enteredCredentials)
            draft = NetworkProxyDraft(settings.networkProxy)
            present(.networkProxySave, cleanedUp ? .networkProxySaved : .networkProxyCleanupFailed)
        } catch { present(.networkProxySave, error: error) }
    }

    private func testConnection() {
        do {
            let configuration = try draft.configuration()
            let credentials = try settings.proxyCredentials(for: configuration, entered: draft.enteredCredentials)
            let context = try RunwayNetworkContext(configuration: configuration, credentials: credentials)
            isTesting = true
            connectionTest = Task {
                defer {
                    isTesting = false
                    connectionTest = nil
                }
                do {
                    let (_, response) = try await context.data(for: URLRequest(url: Self.testURL), policy: .standard)
                    guard let response = response as? HTTPURLResponse,
                          (200..<300).contains(response.statusCode)
                    else { throw NetworkProxyError.connectionFailed }
                    try Task.checkCancellation()
                    present(.networkProxyTest, .networkProxyTestSucceeded)
                } catch {
                    if !Task.isCancelled { present(.networkProxyTest, error: error) }
                }
            }
        } catch { present(.networkProxyTest, error: error) }
    }

    private func present(_ title: L10nKey, _ message: L10nKey) {
        alertTitle = title
        alertMessage = message
    }

    private func present(_ title: L10nKey, error: Error) {
        present(title, (error as? NetworkProxyError ?? .connectionFailed).l10nKey)
    }

    private func editing<Value>(_ field: WritableKeyPath<NetworkProxyDraft, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: field] },
            set: { draft[keyPath: field] = $0 })
    }

    private static var testURL: URL {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return URL(string: "https://github.com/Licoy/codex-runway/releases/latest/download/appcast-\(architecture).xml")!
    }
}

private struct TrailingControlRow<Control: View>: View {
    var title: String
    var controlWidth: CGFloat = 230
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
            Spacer(minLength: 16)
            control.frame(width: controlWidth, alignment: .trailing)
        }
    }
}
