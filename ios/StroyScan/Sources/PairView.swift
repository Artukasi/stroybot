import SwiftUI

/// Подключение к боту вручную: адрес сервера и код из команды /scanner.
struct PairView: View {
    @EnvironmentObject var link: BotLink
    @Environment(\.dismiss) private var dismiss
    @State private var server = UserDefaults.standard.string(forKey: "server") ?? ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("stroybot.example.ru", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Адрес бота") } footer: { Text("Он есть в сообщении бота после команды /scanner.") }
                Section {
                    TextField("ABCD2345", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.system(.title3, design: .monospaced))
                } header: { Text("Код") } footer: { Text("Код действует 10 минут.") }
                Section {
                    Button {
                        Task { await link.pair(server: server, code: code); if link.connected { dismiss() } }
                    } label: {
                        if link.busy { ProgressView() } else { Text("Подключить").bold() }
                    }
                    .disabled(server.isEmpty || code.count < 6 || link.busy)
                }
            }
            .navigationTitle("Подключить бота")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}
