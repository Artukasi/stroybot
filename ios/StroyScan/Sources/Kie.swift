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
        case .http(let c, _): return "Нейросеть ответила ошибкой (\(c)). Попробуйте ещё раз."
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
    static var textPath: String { UserDefaults.standard.string(forKey: "kie.textPath") ?? "/gemini-3-5-flash-openai/v1/chat/completions" }
    static var textModel: String { UserDefaults.standard.string(forKey: "kie.textModel") ?? "gemini-3-5-flash" }
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
            throw KieError.http(status, String(data: data.prefix(300), encoding: .utf8) ?? "")
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

    /// Текстовая модель; ответ бывает в формате choices (OpenAI) или candidates (Gemini)
    static func chat(system: String, text: String, image: Data? = nil, maxTokens: Int = 2000) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let image {
            content.append(["type": "image_url", "image_url": ["url": try await uploadImage(image)]])
        }
        let payload: [String: Any] = ["model": textModel, "stream": false, "max_tokens": maxTokens,
                                      "messages": [["role": "system", "content": system], ["role": "user", "content": content]]]
        let b = try await send(try request(api + textPath, json: payload, timeout: 180))
        var out = ""
        if let c = (b["choices"] as? [[String: Any]])?.first, let m = c["message"] as? [String: Any] {
            if let s = m["content"] as? String { out = s }
            if let parts = m["content"] as? [[String: Any]] { out = parts.compactMap { $0["text"] as? String }.joined() }
        } else if let c = (b["candidates"] as? [[String: Any]])?.first,
                  let parts = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
            out = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { throw KieError.empty }
        return out
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
                    Link(destination: URL(string: "https://kie.ai/api-key")!) { Label("Открыть kie.ai", systemImage: "safari") }
                }
                Section {
                    TextField("Модель", text: $textModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Адрес", text: $textPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Как у бота по умолчанию") {
                        textModel = "gemini-3-5-flash"
                        textPath = "/gemini-3-5-flash-openai/v1/chat/completions"
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
