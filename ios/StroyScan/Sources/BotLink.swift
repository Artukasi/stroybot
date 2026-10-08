import Foundation
import UIKit

/// Связь с ботом: подключение по коду, отправка сканов, картинки ремонта, мебель по размерам.
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
            let data = try await call("POST", server + "/scan/pair", body: body, auth: false)
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

    /// Кнопка «Отправить в СтройБот»: с сообщением об успехе или ошибке
    func send(_ result: RoomResult) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            _ = try await sendScan(result)
            message = "Скан отправлен в бот."
            return true
        } catch {
            message = (error as? LinkError)?.text ?? "Не удалось отправить: \(error.localizedDescription)"
            return false
        }
    }

    /// Отправляет скан молча и возвращает его номер на сервере
    func sendScan(_ result: RoomResult) async throws -> Int? {
        let data = try await call("POST", server + "/scan/rooms", body: result.payload, timeout: 90)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var id: Int?
        if let n = json?["id"] as? NSNumber {
            id = n.intValue
        } else if let s = json?["id"] as? String {
            id = Int(s)
        }
        if let id { lastScanId = id }
        return id
    }

    /// ИИ перерисовывает фото комнаты в выбранном стиле. Возвращает ссылку на картинку.
    func design(scanId: Int, style: String, look: [String: Any]? = nil) async throws -> (image: URL, credits: Int?) {
        var body: [String: Any] = ["scan_id": scanId, "id": scanId, "style": style]
        if let look { body["look"] = look }
        let data = try await call("POST", server + "/scan/design", body: body, timeout: 240, design: true)
        return try imageAnswer(data)
    }

    /// Снимок 3D-модели → фото «как в жизни» в том же ремонте
    func render(scanId: Int, image: Data, style: String, look: [String: Any]) async throws -> (image: URL, credits: Int?) {
        let body: [String: Any] = ["scan_id": scanId, "image": image.base64EncodedString(), "style": style, "look": look]
        let data = try await call("POST", server + "/scan/render", body: body, timeout: 300, design: true)
        return try imageAnswer(data)
    }

    /// Мебель по размерам скана: что встанет и ссылки на магазины
    func furniture(scanId: Int) async throws -> [[String: Any]] {
        let body: [String: Any] = ["scan_id": scanId]
        let data = try await call("POST", server + "/scan/furniture", body: body, timeout: 60)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["items"] as? [[String: Any]] ?? []
    }

    /// Ремонт в 3D, сохранённый в боте (пустой — ещё не сохраняли)
    func look(scanId: Int) async throws -> [String: Any] {
        let data = try await call("GET", server + "/scan/look?scan_id=\(scanId)", body: nil)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["look"] as? [String: Any] ?? [:]
    }

    func saveLook(scanId: Int, look: [String: Any]) async throws {
        let body: [String: Any] = ["scan_id": scanId, "look": look]
        _ = try await call("PUT", server + "/scan/look", body: body)
    }

    private func imageAnswer(_ data: Data) throws -> (image: URL, credits: Int?) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let link = json?["image"] as? String, let url = URL(string: link) else {
            throw LinkError.message("Сервер ответил странно. Попробуйте ещё раз.")
        }
        return (url, (json?["credits"] as? NSNumber)?.intValue)
    }

    private func call(_ method: String, _ url: String, body: Any?, auth: Bool = true,
                      timeout: TimeInterval = 30, design: Bool = false) async throws -> Data {
        guard let u = URL(string: url) else { throw LinkError.message("Неверный адрес сервера.") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let answer: (Data, URLResponse)
        do {
            answer = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw LinkError.offline("Бот долго не отвечает. Попробуйте ещё раз.")
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost {
            throw LinkError.offline("Нет интернета.")
        } catch is URLError {
            throw LinkError.offline("Бот сейчас недоступен: компьютер с ботом выключен или адрес сменился.")
        }
        let (data, resp) = answer
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (200...299).contains(status) { return data }
        let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
        switch status {
        case 401: disconnect(); throw LinkError.message("Подключение сброшено. Получите новый код командой /scanner в боте.")
        case 402: throw LinkError.message("Не хватает кредитов. Пополните в боте.")
        case 403: throw LinkError.message("Код не подошёл или устарел. Получите новый командой /scanner в боте.")
        case 404 where code == "scan": throw LinkError.scanMissing
        case 404, 405: throw LinkError.message("Бот ещё не умеет это. Обновите бота на сервере.")
        case 409: throw LinkError.message("Нужно фото комнаты")
        case 413: throw LinkError.message("Слишком большой файл.")
        case 400 where code == "image": throw LinkError.message("Снимок 3D не подошёл. Попробуйте ещё раз.")
        case 400 where code == "style": throw LinkError.message("Бот не знает этот стиль. Обновите бота.")
        case 400: throw LinkError.message("Бот не понял запрос. Обновите приложение и бота.")
        case 429: throw LinkError.message("Слишком много попыток. Подождите 10 минут.")
        case 502 where design: throw LinkError.message("ИИ не ответил, кредиты вернули. Попробуйте ещё раз.")
        case 500...599: throw LinkError.offline("Бот сейчас недоступен. Попробуйте позже.")
        default: throw LinkError.message("Ошибка сервера (\(status)).")
        }
    }
}

enum LinkError: Error {
    case message(String)
    /// Нет связи с ботом (интернет, бот выключен) — можно отправить позже
    case offline(String)
    /// Скана нет в боте (удалили или другой аккаунт) — надо отправить заново
    case scanMissing

    var text: String {
        switch self {
        case .message(let t), .offline(let t): return t
        case .scanMissing: return "Скан не найден в боте. Отправьте его ещё раз."
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LinkError)?.text ?? "Не получилось: \(error.localizedDescription)"
    }
}
