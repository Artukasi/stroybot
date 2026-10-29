import SwiftUI

@main
struct StroyScanApp: App {
    @StateObject private var link = BotLink()
    @StateObject private var store = ScanStore()
    @StateObject private var hub = ScanHub()
    @StateObject private var backup = Backup()
    @StateObject private var tiles = TileLibrary()

    var body: some Scene {
        WindowGroup {
            StroyScanShell()
                .environmentObject(link)
                .environmentObject(store)
                .environmentObject(hub)
                .environmentObject(backup)
                .environmentObject(tiles)
                .tint(Palette.signal)
                .preferredColorScheme(.dark)
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
    static let signal = Color(red: 0.89, green: 0.12, blue: 0.25)   // #E31F40 — алый акцент
    static let ink = Color.primary                                 // адаптивный текст и контур
    static let black = Color(red: 0.035, green: 0.035, blue: 0.045) // #09090B — тёмные поверхности
    static let draft = Color(red: 0.43, green: 0.075, blue: 0.15)  // #6E1326 — глубокий бордо
    static let paper = Color(red: 0.045, green: 0.043, blue: 0.05) // #0B0B0D — фон приложения
}

enum AppMotion {
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.92)
    static let state = Animation.spring(response: 0.30, dampingFraction: 0.92)
    static let reveal = Animation.spring(response: 0.38, dampingFraction: 1)
    static let fade = Animation.easeOut(duration: 0.16)

    static func adaptive(reduceMotion: Bool, full: Animation) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : full
    }
}
