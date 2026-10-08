import SwiftUI

@main
struct StroyScanApp: App {
    @StateObject private var link = BotLink()
    @StateObject private var store = ScanStore()
    @StateObject private var hub = ScanHub()
    @StateObject private var backup = Backup()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .environmentObject(store)
                .environmentObject(hub)
                .environmentObject(backup)
                .tint(Palette.signal)
                // ссылка из бота: stroyscan://pair?server=https://…&code=ABCD2345
                .onOpenURL { url in
                    guard url.scheme == "stroyscan", url.host == "pair",
                          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                          let server = items.first(where: { $0.name == "server" })?.value,
                          let code = items.first(where: { $0.name == "code" })?.value else { return }
                    Task { await link.pair(server: server, code: code) }
                }
        }
    }
}

enum Palette {
    static let signal = Color(red: 0.96, green: 0.77, blue: 0.09)   // #F5C518
    static let ink = Color(red: 0.08, green: 0.13, blue: 0.18)      // #14202E
    static let draft = Color(red: 0.24, green: 0.44, blue: 0.68)    // #3D6FAE
    static let paper = Color(red: 0.90, green: 0.93, blue: 0.95)    // #E6ECF2
}
