import Foundation
import UIKit

/// Связь с ботом: подключение по коду и отправка сканов.
@MainActor
final class BotLink: ObservableObject {
    @Published private(set) var server: String = UserDefaults.standard.string(forKey: "server") ?? ""
    @Published private(set) var connected: Bool = UserDefaults.standard.string(forKey: "token") != nil
    @Published var message: String?
    @Published var busy = false
    /// Номер последнего отправленного скана на сервере (нужен для ИИ-ремонта)
    @Published var lastScanId: Int?

    private var token: String? { UserDefaults.standard.string(forKey: "token") }

    func pair(server rawServer: String, code: String) async {
        var server = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.hasPrefix("http") { server = "https://" + server }
        while server.hasSuffix("/") { server.removeLast() }
        busy = true
        defer { busy = false }
        do {
            let body: [String: String] = ["code": code, "device": UIDevice.current.name]
            let data = try await post(server + "/scan/pair", body: body, auth: false)
            guard let token = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String else {
                throw LinkError.message("Сервер ответил странно. Проверьте адрес.")
            }
            UserDefaults.standard.set(server, forKey: "server")
            UserDefaults.standard.set(token, forKey: "token")
            self.server = server
            connected = true
            message = "Подключено к боту. Сканы будут приходить в чат."
        } catch {
            message = (error as? LinkError)?.text ?? "Не удалось подключиться: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: "token")
        connected = false
    }

    func send(_ result: RoomResult) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let data = try await post(server + "/scan/rooms", body: result.payload, auth: true)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let n = json?["id"] as? NSNumber {
                lastScanId = n.intValue
            } else if let s = json?["id"] as? String {
                lastScanId = Int(s)
            }
            message = "Скан отправлен в бот."
            return true
        } catch {
            message = (error as? LinkError)?.text ?? "Не удалось отправить: \(error.localizedDescription)"
            return false
        }
    }

    /// ИИ перерисовывает фото комнаты в выбранном стиле. Возвращает ссылку на картинку.
    func design(scanId: Int, style: String) async throws -> (image: URL, credits: Int?) {
        let body: [String: Any] = ["id": scanId, "style": style]
        let data = try await post(server + "/scan/design", body: body, auth: true, timeout: 240, design: true)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let link = json?["image"] as? String, let url = URL(string: link) else {
            throw LinkError.message("Сервер ответил странно. Попробуйте ещё раз.")
        }
        let credits = (json?["credits"] as? NSNumber)?.intValue
        return (url, credits)
    }

    private func post(_ url: String, body: Any, auth: Bool,
                      timeout: TimeInterval = 30, design: Bool = false) async throws -> Data {
        guard let u = URL(string: url) else { throw LinkError.message("Неверный адрес сервера.") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299: return data
        case 401: disconnect(); throw LinkError.message("Подключение сброшено. Получите новый код командой /scanner в боте.")
        case 403: throw LinkError.message("Код не подошёл или устарел. Получите новый командой /scanner в боте.")
        case 402: throw LinkError.message("Не хватает кредитов. Пополните в боте.")
        case 409: throw LinkError.message("Нужно фото комнаты")
        case 429: throw LinkError.message("Слишком много попыток. Подождите 10 минут.")
        case 502 where design: throw LinkError.message("ИИ не ответил, кредиты вернули. Попробуйте ещё раз.")
        default: throw LinkError.message("Ошибка сервера (\(status)).")
        }
    }
}

enum LinkError: Error {
    case message(String)
    var text: String { if case .message(let t) = self { return t }; return "" }
}
