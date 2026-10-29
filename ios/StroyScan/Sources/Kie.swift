import Foundation
import Security
import SwiftUI

// MARK: - Нейросети напрямую из приложения (kie.ai), без бота и компьютера

/// Ключ kie.ai — только в связке ключей iPhone, в коде и в копиях его нет
enum KieKey {
    private static let service = "ru.stroybot.stroyscan.kie"

    static var value: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func set(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum KieError: Error {
    case noKey, money, http(Int, String), task(String), timeout, empty

    var text: String {
        switch self {
        case .noKey: return "Нужен ключ kie.ai: «Нейросети» → шестерёнка."
        case .money: return "На kie.ai закончились кредиты. Пополните баланс на kie.ai."
        case .http(401, _): return "Ключ kie.ai не подошёл. Проверьте его в настройках нейросетей."
        case .http(let c, let details): return "Ошибка kie.ai (\(c)): \(details.isEmpty ? "проверь модель, баланс и подключение" : String(details.prefix(180)))"
        case .task(let why): return "Нейросеть не справилась: \(why). Попробуйте ещё раз."
        case .timeout: return "Нейросеть долго думает. Попробуйте ещё раз."
        case .empty: return "Нейросеть ответила пусто. Попробуйте ещё раз."
        }
    }

    static func describe(_ e: Error) -> String {
        if let k = e as? KieError { return k.text }
        if let u = e as? URLError {
            return u.code == .notConnectedToInternet ? "Нет интернета." : "Нет связи с нейросетью. Проверьте интернет."
        }
        return "Не получилось: \(e.localizedDescription)"
    }
}

/// Клиент kie.ai: те же модели и запросы, что у бота (bot/kie.py)
enum Kie {
    static let api = "https://api.kie.ai"
    static let upload = "https://kieai.redpandaai.co"

    /// Модели можно поменять в настройках, если kie.ai переименует
    // Gemini 3.5 Flash was discontinued; migrate the shipped default while respecting custom models.
    static let defaultTextPath = "/gemini-3-8-flash-openai/v1/chat/completions"
    static let defaultTextModel = "gemini-3-8-flash"
    static var textPath: String {
        let saved = UserDefaults.standard.string(forKey: "kie.textPath")
        return saved == nil || saved == "/gemini-3-5-flash-openai/v1/chat/completions"
            ? defaultTextPath : saved!
    }
    static var textModel: String {
        let saved = UserDefaults.standard.string(forKey: "kie.textModel")
        return saved == nil || saved == "gemini-3-5-flash" ? defaultTextModel : saved!
    }
    static let editModel = "google/nano-banana-edit"
    static let t2iModel = "google/nano-banana"

    static var ready: Bool { KieKey.value != nil }

    private static func request(_ url: String, method: String = "POST", json: Any? = nil, timeout: TimeInterval = 60) throws -> URLRequest {
        guard let key = KieKey.value else { throw KieError.noKey }
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private static func send(_ r: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (body["code"] as? NSNumber)?.intValue ?? status
        if status == 402 || code == 402 { throw KieError.money }
        if status == 401 || code == 401 { throw KieError.http(401, "") }
        if !(200...299).contains(status) {
            let detail = (body["msg"] as? String) ?? (body["message"] as? String) ?? ""
            throw KieError.http(status, detail.isEmpty
                ? (String(data: data.prefix(300), encoding: .utf8) ?? "") : detail)
        }
        // Kie.ai can return HTTP 200 with a failed business code.
        if body["code"] != nil && code != 200 && code != 0 {
            let detail = (body["msg"] as? String) ?? (body["message"] as? String) ?? ""
            throw KieError.http(code, detail)
        }
        return body
    }

    /// Остаток кредитов на kie.ai
    static func balance() async throws -> Double {
        let b = try await send(try request(api + "/api/v1/chat/credit", method: "GET", timeout: 20))
        if let n = b["data"] as? NSNumber { return n.doubleValue }
        if let d = b["data"] as? [String: Any], let n = (d["credit"] ?? d["credits"] ?? d["balance"]) as? NSNumber { return n.doubleValue }
        throw KieError.empty
    }

    /// Фото → временная ссылка (живёт ~3 дня)
    static func uploadImage(_ jpeg: Data) async throws -> String {
        let mime = jpeg.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        let payload: [String: Any] = ["base64Data": "data:\(mime);base64," + jpeg.base64EncodedString(),
                                      "uploadPath": "stroyscan", "fileName": "\(UUID().uuidString).\(mime == "image/png" ? "png" : "jpg")"]
        let b = try await send(try request(upload + "/api/file-base64-upload", json: payload, timeout: 120))
        let d = b["data"] as? [String: Any]
        guard let url = (d?["downloadUrl"] ?? d?["fileUrl"]) as? String else { throw KieError.task("фото не загрузилось") }
        return url
    }

    private static func createTask(_ model: String, _ input: [String: Any]) async throws -> String {
        let b = try await send(try request(api + "/api/v1/jobs/createTask", json: ["model": model, "input": input]))
        guard let id = (b["data"] as? [String: Any])?["taskId"] as? String else {
            throw KieError.task((b["msg"] as? String) ?? "задача не создалась")
        }
        return id
    }

    private static func waitTask(_ id: String, timeout: TimeInterval = 600) async throws -> [String] {
        var delay: UInt64 = 3, waited: UInt64 = 0
        while TimeInterval(waited) < timeout {
            try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            waited += delay
            let b = try await send(try request(api + "/api/v1/jobs/recordInfo?taskId=\(id)", method: "GET", timeout: 30))
            let d = b["data"] as? [String: Any] ?? [:]
            switch d["state"] as? String {
            case "success":
                var result = d["resultJson"]
                if let s = result as? String { result = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
                let urls = (result as? [String: Any])?["resultUrls"] as? [String] ?? []
                if urls.isEmpty { throw KieError.empty }
                return urls
            case "fail":
                throw KieError.task((d["failMsg"] as? String) ?? "ошибка")
            default:
                delay = min(delay + 2, 10)
            }
        }
        throw KieError.timeout
    }

    /// Перерисовать фото по описанию (ремонт на фото, «как в жизни»)
    static func editImage(_ jpeg: Data, prompt: String) async throws -> URL {
        let url = try await uploadImage(jpeg)
        let id = try await createTask(editModel, ["prompt": prompt, "image_urls": [url], "output_format": "png"])
        guard let out = URL(string: try await waitTask(id)[0]) else { throw KieError.empty }
        return out
    }

    /// Картинка по описанию, без фото
    static func generateImage(prompt: String, aspect: String = "4:3") async throws -> URL {
        let id = try await createTask(t2iModel, ["prompt": prompt, "output_format": "png", "image_size": aspect])
        guard let out = URL(string: try await waitTask(id)[0]) else { throw KieError.empty }
        return out
    }

    /// The provider may return an OpenAI response, Gemini response, or a nested data payload.
    /// Return a meaningful error when the model completed without user-visible text.
    static func extractChatText(_ response: [String: Any]) throws -> String {
        let body = (response["data"] as? [String: Any]) ?? response
        if let choices = body["choices"] as? [[String: Any]], let choice = choices.first {
            if let message = choice["message"] as? [String: Any] {
                let raw = message["content"]
                if let string = raw as? String,
                   !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let parts = raw as? [[String: Any]] {
                    let joined = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if let refusal = message["refusal"] as? String, !refusal.isEmpty {
                    throw KieError.task("Модель отказала в ответе: " + String(refusal.prefix(150)))
                }
            }
            let reason = choice["finish_reason"] as? String ?? "неизвестна"
            let usage = body["usage"] as? [String: Any]
            let tokens = (usage?["completion_tokens"] as? NSNumber)?.intValue ?? 0
            let thinking = (usage?["completion_tokens_details"] as? [String: Any])?
                ["reasoning_tokens"] as? NSNumber
            if reason == "length" {
                throw KieError.task("Модель исчерпала лимит ответа (\(tokens) токенов). Укороти задачу или повтори.")
            }
            if reason == "content_filter" {
                throw KieError.task("Ответ ограничен фильтром содержимого.")
            }
            if let thinking, thinking.intValue > 0 {
                throw KieError.task("Модель потратила \(thinking.intValue) токенов на размышление, но не выдала текста. Повтори с более коротким запросом.")
            }
            throw KieError.task("Сервер вернул пустой ответ (причина завершения: \(reason)). Попробуй ещё раз.")
        }
        if let candidates = body["candidates"] as? [[String: Any]],
           let candidate = candidates.first {
            if let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
                let joined = parts.filter { ($0["thought"] as? Bool) != true }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return joined.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let reason = candidate["finishReason"] as? String ?? "неизвестна"
            throw KieError.task("Gemini не вернул текст (причина: \(reason)).")
        }
        // No body or unexpected schema: avoid printing payloads, which can contain user content.
        throw KieError.task("Ответ сервера имеет неизвестный формат (нет choices/candidates).")
    }

    static func chat(system: String, text: String, image: Data? = nil,
                     maxTokens: Int = 4096) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let image {
            content.append(["type": "image_url", "image_url": ["url": try await uploadImage(image)]])
        }
        let payload: [String: Any] = [
            "model": textModel,
            "stream": false,
            // Requests with large renovation plans must reserve budget for the final text.
            "max_tokens": max(512, maxTokens),
            "reasoning_effort": "low",
            "include_thoughts": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content]
            ]
        ]
        let body = try await send(try request(api + textPath, json: payload, timeout: 180))
        return try extractChatText(body)
    }
}

/// Ключ и модели kie.ai
struct KieSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var has = Kie.ready
    @State private var textModel = Kie.textModel
    @State private var textPath = Kie.textPath
    @State private var checking = false
    @State private var testing = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if has {
                        Label("Ключ сохранён в этом iPhone", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Удалить ключ", role: .destructive) { KieKey.set(nil); has = false; status = nil }
                    }
                    SecureField(has ? "Новый ключ (если меняете)" : "Вставьте ключ API", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        if let s = UIPasteboard.general.string { key = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } label: { Label("Вставить из буфера", systemImage: "doc.on.clipboard") }
                    Button { Task { await save() } } label: {
                        HStack {
                            if checking { ProgressView() }
                            Text("Сохранить и проверить").bold()
                        }
                    }
                    .disabled(key.isEmpty || checking)
                    if let status { Text(status).font(.footnote) }
                } header: {
                    Text("Ключ kie.ai")
                } footer: {
                    Text("Тот же ключ, что у бота (KIE_API_KEY). Взять или пополнить баланс: kie.ai → API Key. Ключ хранится только в связке ключей iPhone, в копии и файлы не попадает.")
                }
                Section {
                    Button {
                        Task {
                            testing = true
                            defer { testing = false }
                            do {
                                let response = try await Kie.chat(
                                    system: "Проверка соединения. Ответь одним словом: Работает.",
                                    text: "Проверка ИИ",
                                    maxTokens: 80
                                )
                                status = "✅ ИИ отвечает: " + String(response.prefix(160))
                            } catch {
                                status = "❌ " + KieError.describe(error)
                            }
                        }
                    } label: {
                        HStack {
                            if testing { ProgressView() }
                            Label("Проверить ответ ИИ", systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(!has || testing || checking)
                    Text("Пробный запрос тратит небольшое количество кредитов kie.ai.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Link(destination: URL(string: "https://kie.ai/api-key")!) { Label("Открыть kie.ai", systemImage: "safari") }
                }
                Section {
                    TextField("Модель", text: $textModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Адрес", text: $textPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Восстановить актуальную модель") {
                        textModel = Kie.defaultTextModel
                        textPath = Kie.defaultTextPath
                    }
                } header: {
                    Text("Текстовая модель (обычно трогать не нужно)")
                } footer: {
                    Text("Если в боте в .env указаны другие TEXT_MODEL и TEXT_MODEL_PATH — впишите их сюда.")
                }
            }
            .navigationTitle("Нейросети")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        UserDefaults.standard.set(textModel.trimmingCharacters(in: .whitespaces), forKey: "kie.textModel")
                        UserDefaults.standard.set(textPath.trimmingCharacters(in: .whitespaces), forKey: "kie.textPath")
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() async {
        let old = KieKey.value
        KieKey.set(key)
        checking = true
        defer { checking = false }
        do {
            let b = try await Kie.balance()
            has = true
            key = ""
            status = "✅ Ключ работает. На балансе kie.ai: \(Int(b)) кредитов."
        } catch KieError.http(401, _) {
            KieKey.set(old)
            has = old != nil
            status = "❌ Ключ не подошёл. Скопируйте его на kie.ai ещё раз."
        } catch {
            // баланс не прочитался, но ключ мог быть верным — оставляем
            has = true
            key = ""
            status = "Ключ сохранён. Баланс не прочитался (\(KieError.describe(error))) — проверьте первым запросом."
        }
    }
}
