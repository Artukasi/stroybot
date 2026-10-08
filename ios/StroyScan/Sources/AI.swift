import PhotosUI
import SwiftUI

// MARK: - Нейросети СтройБота прямо в приложении

/// Баланс, цены, стили и пакеты — из бота (/api/profile). Кредиты общие с ботом и Mini App
struct AIProfile {
    struct Pack: Identifiable {
        let id: String
        let credits: Int
        let stars: Int
    }

    var credits = 0
    var prices: [String: Int] = [:]
    var freeConsult = 0
    var styles: [(id: String, name: String)] = []
    var packs: [Pack] = []
    var reportMax = 10

    init() {}

    init(json d: [String: Any]) {
        let int = { (v: Any?) in (v as? NSNumber)?.intValue ?? 0 }
        credits = int(d["credits"])
        prices = (d["prices"] as? [String: Any] ?? [:]).mapValues { int($0) }
        freeConsult = int(d["free_consult_left"])
        let order = ["scandi", "loft", "modern", "classic", "japandi", "budget"]
        styles = (d["styles"] as? [String: String] ?? [:]).map { (id: $0.key, name: $0.value) }
            .sorted { (order.firstIndex(of: $0.id) ?? 99, $0.name) < (order.firstIndex(of: $1.id) ?? 99, $1.name) }
        packs = (d["packs"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return Pack(id: id, credits: int(p["credits"]), stars: int(p["stars"]))
        }
        reportMax = max(1, int(d["report_max_photos"]))
    }

    func price(_ kind: String) -> String {
        guard let p = prices[kind] else { return "" }
        return p == 0 ? "бесплатно" : "\(p) кр."
    }
}

enum AIText {
    /// Простой HTML из бота (b, i, code) → текст с жирным и курсивом
    static func attributed(_ html: String) -> AttributedString {
        var s = html
        for (a, b) in [("<b>", "**"), ("</b>", "**"), ("<strong>", "**"), ("</strong>", "**"),
                       ("<i>", "_"), ("</i>", "_"), ("<em>", "_"), ("</em>", "_"),
                       ("<code>", "`"), ("</code>", "`")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    /// Без разметки — скопировать или отправить
    static func plain(_ html: String) -> String {
        String(attributed(html).characters)
    }
}

/// Главный экран нейросетей: баланс, пополнение и все инструменты
struct AIView: View {
    @EnvironmentObject var link: BotLink
    /// Комната, из которой открыли: её размеры подставим в смету и КП
    var room: RoomResult? = nil
    @State private var profile: AIProfile?
    @State private var problem: String?
    @State private var buying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !link.connected {
                    Text("Нейросети работают через СтройБот. Подключите бота на главном экране: в боте команда /scanner.")
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                } else {
                    balance
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        NavigationLink { AIDesignView(profile: $profile) } label: {
                            card("Дизайн по фото", "paintbrush.pointed.fill", profile?.price("design") ?? "")
                        }
                        NavigationLink {
                            AITextView(kind: "consult", title: "Консультант", profile: $profile,
                                       placeholder: "Спросите что угодно про ремонт: чем выровнять стены, какой клей для плитки, сколько сохнет стяжка…")
                        } label: {
                            card("Консультант", "bubble.left.and.text.bubble.right.fill",
                                 (profile?.freeConsult ?? 0) > 0 ? "бесплатно: \(profile?.freeConsult ?? 0) сегодня" : profile?.price("consult") ?? "")
                        }
                        NavigationLink {
                            AITextView(kind: "estimate", title: "Смета", profile: $profile, prefill: room.map(AIView.roomText),
                                       placeholder: "Что за помещение и что делаем: «ванная 2×1,7 м, высота 2,6, плитка на стены и пол, замена труб»")
                        } label: {
                            card("Смета", "list.bullet.rectangle.portrait.fill", profile?.price("estimate") ?? "")
                        }
                        NavigationLink {
                            AITextView(kind: "kp", title: "Коммерческое предложение", profile: $profile, prefill: room.map(AIView.roomText),
                                       placeholder: "Для кого, какие работы, сроки и цена — соберу аккуратное КП для заказчика")
                        } label: {
                            card("КП заказчику", "doc.text.fill", profile?.price("kp") ?? "")
                        }
                        NavigationLink { AICheckView(profile: $profile) } label: {
                            card("Проверка работы", "checkmark.seal.fill", profile?.price("check") ?? "")
                        }
                        NavigationLink { AIReportView(profile: $profile) } label: {
                            card("Фотоотчёт PDF", "photo.stack.fill", profile?.price("report") ?? "")
                        }
                    }
                    .buttonStyle(PressStyle())
                    Text("Те же нейросети, что в чате СтройБота, и кредиты те же. Если ИИ не ответил — кредиты возвращаются сами.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Нейросети")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var balance: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Баланс").font(.caption).foregroundStyle(.white.opacity(0.7))
                if let p = profile {
                    Text("\(p.credits) кредитов").font(.title2.bold()).foregroundStyle(.white).contentTransition(.numericText())
                } else {
                    ProgressView().tint(.white)
                }
            }
            Spacer()
            Menu {
                ForEach(profile?.packs ?? []) { p in
                    Button("\(p.credits) кредитов — \(p.stars) ⭐") { Task { await buy(p) } }
                }
            } label: {
                HStack(spacing: 6) {
                    if buying { ProgressView() } else { Image(systemName: "plus.circle.fill") }
                    Text("Пополнить").bold()
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .background(Palette.signal, in: Capsule())
                .foregroundStyle(Palette.ink)
            }
            .disabled(profile?.packs.isEmpty ?? true)
        }
        .padding()
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 20))
    }

    private func card(_ title: String, _ icon: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(Palette.signal)
            Text(title).font(.headline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            Text(sub).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 18))
    }

    private func load() async {
        guard link.connected else { return }
        do {
            profile = AIProfile(json: try await link.api("GET", "/api/profile", timeout: 20))
            problem = nil
        } catch {
            problem = LinkError.describe(error)
        }
    }

    /// Оплата звёздами — в Telegram; кредиты придут в бот, баланс обновится, когда вернётесь
    private func buy(_ p: AIProfile.Pack) async {
        buying = true
        defer { buying = false }
        do {
            let answer = try await link.api("POST", "/api/invoice", json: ["pack": p.id], timeout: 20)
            if let s = answer["link"] as? String, let url = URL(string: s) {
                await UIApplication.shared.open(url)
            }
        } catch {
            problem = LinkError.describe(error)
        }
    }

    /// Размеры комнаты для сметы и КП
    static func roomText(_ r: RoomResult) -> String {
        let f = { (v: Double) in String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",") }
        var s = "\(r.room): пол \(f(r.floorArea)) м², стены \(f(r.wallArea)) м² (без проёмов), высота \(f(r.height)) м, периметр \(f(r.perimeter)) м"
        let windows = r.openings.filter { $0.kind == "window" }.count, doors = r.openings.filter { $0.kind != "window" }.count
        if windows + doors > 0 { s += ", окон \(windows), дверей \(doors)" }
        return s + ". Размеры сняты лидаром.\nЧто делаем: "
    }
}

/// Ошибка «нет кредитов» и прочие — одной строкой под кнопкой
private struct ProblemText: View {
    let text: String?
    var body: some View {
        if let text { Text(text).font(.footnote).foregroundStyle(.red) }
    }
}

/// Ответ ИИ: текст с жирным, копировать, отправить себе в чат с ботом
struct AIAnswer: View {
    @EnvironmentObject var link: BotLink
    let html: String
    let raw: String
    @State private var sent = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AIText.attributed(html)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = AIText.plain(html)
                    copied = true
                } label: { Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: AIText.plain(html)) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                Button {
                    Task { sent = (try? await link.api("POST", "/api/send", json: ["text": raw], timeout: 30)) != nil }
                } label: { Label(sent ? "В чате" : "В чат", systemImage: sent ? "checkmark" : "paperplane") }
            }
            .font(.subheadline.bold())
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Текстовые инструменты: консультант, смета, КП
struct AITextView: View {
    @EnvironmentObject var link: BotLink
    let kind: String
    let title: String
    @Binding var profile: AIProfile?
    var prefill: String? = nil
    let placeholder: String
    @State private var text = ""
    @State private var working = false
    @State private var answer: (html: String, raw: String)?
    @State private var problem: String?
    @StateObject private var dictation = Dictation()
    @State private var base = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                    }
                    TextEditor(text: $text).frame(minHeight: 140).scrollContentBackground(.hidden)
                }
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                DictateButton(dictation: dictation)
                Button { Task { await ask() } } label: {
                    HStack {
                        if working { ProgressView() }
                        Text(working ? "Думаю…" : kind == "consult" ? "Спросить" : "Составить").bold()
                        if let p = profile, !working {
                            Text(kind == "consult" && p.freeConsult > 0 ? "· бесплатно" : "· \(p.price(kind))").opacity(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Palette.ink)
                }
                .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                ProblemText(text: problem)
                if let a = answer { AIAnswer(html: a.html, raw: a.raw) }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if text.isEmpty, let prefill { text = prefill } }
        .onChange(of: dictation.running) { on in if on { base = text } }
        .onChange(of: dictation.text) { said in
            guard !said.isEmpty else { return }
            text = base.isEmpty ? said : base + " " + said
        }
        .onDisappear { dictation.stop() }
    }

    private func ask() async {
        dictation.stop()
        working = true
        problem = nil
        defer { working = false }
        do {
            let d = try await link.api("POST", "/api/ai/text", json: ["kind": kind, "text": text])
            answer = (d["html"] as? String ?? "", d["raw"] as? String ?? "")
            if let c = (d["credits"] as? NSNumber)?.intValue {
                profile?.credits = c
                if kind == "consult", let p = profile, p.freeConsult > 0 { profile?.freeConsult = p.freeConsult - 1 }
            }
        } catch {
            problem = LinkError.describe(error)
        }
    }
}

/// Выбор фото: камера или галерея
struct AIPhotoPicker: View {
    @Binding var photo: UIImage?
    @State private var camera = false
    @State private var picked: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 10) {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            HStack(spacing: 10) {
                Button { camera = true } label: {
                    Label("Снять", systemImage: "camera").frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                PhotosPicker(selection: $picked, matching: .images) {
                    Label("Галерея", systemImage: "photo").frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .font(.headline)
            .foregroundStyle(Palette.ink)
        }
        .fullScreenCover(isPresented: $camera) {
            PhotoCameraView { data in if let img = UIImage(data: data) { photo = TileImage.upright(img) } }
        }
        .onChange(of: picked) { item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = TileImage.upright(img) }
            }
        }
    }
}

/// Дизайн по фото: стиль и пожелания → картинка ремонта
struct AIDesignView: View {
    @EnvironmentObject var link: BotLink
    @Binding var profile: AIProfile?
    @State private var photo: UIImage?
    @State private var style = "scandi"
    @State private var wishes = ""
    @State private var working = false
    @State private var result: URL?
    @State private var problem: String?
    /// Фото уже в боте: другой стиль можно пробовать без повторной загрузки
    @State private var uploaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AIPhotoPicker(photo: $photo)
                    .onChange(of: photo) { _ in uploaded = false }
                if let styles = profile?.styles, !styles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(styles, id: \.id) { s in
                                Button { style = s.id } label: {
                                    Text(s.name).font(.subheadline.weight(.semibold))
                                        .padding(.vertical, 8).padding(.horizontal, 14)
                                        .background(style == s.id ? Palette.ink : Color(.secondarySystemGroupedBackground), in: Capsule())
                                        .foregroundStyle(style == s.id ? .white : Palette.ink)
                                }
                            }
                        }
                    }
                }
                TextField("Пожелания: светлее, тёплое дерево, без ковра…", text: $wishes, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                Button { Task { await make() } } label: {
                    HStack {
                        if working { ProgressView() }
                        Text(working ? "Рисую, до 3 минут…" : "Нарисовать ремонт").bold()
                        if let p = profile, !working { Text("· \(p.price("design"))").opacity(0.7) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Palette.ink)
                }
                .disabled(working || photo == nil)
                ProblemText(text: problem)
                if let result {
                    AsyncImage(url: result) { img in
                        img.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    } placeholder: {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                    HStack(spacing: 16) {
                        ShareLink(item: result) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                        Button { Task { _ = try? await link.api("POST", "/api/send", json: ["photo": result.absoluteString, "text": "Дизайн по фото"], timeout: 30) } } label: {
                            Label("В чат с ботом", systemImage: "paperplane")
                        }
                    }
                    .font(.subheadline.bold())
                    Text("Ссылка на картинку живёт несколько дней — отправьте её в чат, чтобы сохранилась.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Дизайн по фото")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func make() async {
        guard let photo, let jpeg = RoomResult.jpeg(photo) else { return }
        working = true
        problem = nil
        defer { working = false }
        do {
            let fields = [("style", style), ("wishes", wishes)]
            let d = try await link.apiForm("/api/ai/design", fields: fields, files: uploaded ? [] : [("photo", jpeg)])
            uploaded = true
            if let s = d["image"] as? String { result = URL(string: s) }
            if let c = (d["credits"] as? NSNumber)?.intValue { profile?.credits = c }
        } catch {
            uploaded = false
            problem = LinkError.describe(error)
        }
    }
}

/// Проверка работы по фото: ИИ ищет брак и говорит, что переделать
struct AICheckView: View {
    @EnvironmentObject var link: BotLink
    @Binding var profile: AIProfile?
    @State private var photo: UIImage?
    @State private var note = ""
    @State private var working = false
    @State private var answer: (html: String, raw: String)?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AIPhotoPicker(photo: $photo)
                TextField("Что смущает: шов, угол, пятна… (можно пусто)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                Button { Task { await check() } } label: {
                    HStack {
                        if working { ProgressView() }
                        Text(working ? "Смотрю…" : "Проверить").bold()
                        if let p = profile, !working { Text("· \(p.price("check"))").opacity(0.7) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Palette.ink)
                }
                .disabled(working || photo == nil)
                ProblemText(text: problem)
                if let a = answer { AIAnswer(html: a.html, raw: a.raw) }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Проверка работы")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func check() async {
        guard let photo, let jpeg = RoomResult.jpeg(photo) else { return }
        working = true
        problem = nil
        defer { working = false }
        do {
            let d = try await link.apiForm("/api/ai/check", fields: [("note", note)], files: [("photo", jpeg)])
            answer = (d["html"] as? String ?? "", d["raw"] as? String ?? "")
            if let c = (d["credits"] as? NSNumber)?.intValue { profile?.credits = c }
        } catch {
            problem = LinkError.describe(error)
        }
    }
}

/// Фотоотчёт: фото с подписями → PDF приходит в чат с ботом, его можно сразу переслать заказчику
struct AIReportView: View {
    @EnvironmentObject var link: BotLink
    @Binding var profile: AIProfile?
    @State private var photos: [UIImage] = []
    @State private var captions: [String] = []
    @State private var notes = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var working = false
    @State private var done: String?
    @State private var problem: String?

    private var limit: Int { profile?.reportMax ?? 10 }

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $picked, maxSelectionCount: max(1, limit - photos.count), matching: .images) {
                    Label("Добавить фото (до \(limit))", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(photos.count >= limit)
                ForEach(photos.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        Image(uiImage: photos[i]).resizable().scaledToFill().frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        TextField("Подпись: что сделано", text: $captions[i])
                    }
                }
                .onDelete { idx in
                    photos.remove(atOffsets: idx)
                    captions.remove(atOffsets: idx)
                }
            } header: {
                Text("Фото работ")
            }
            Section("Комментарий для заказчика") {
                TextField("Что сделано за этап, что дальше", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            Section {
                Button { Task { await send() } } label: {
                    HStack {
                        if working { ProgressView() }
                        Text(working ? "Собираю PDF…" : "Собрать отчёт").bold()
                        if let p = profile, !working { Text("· \(p.price("report"))").opacity(0.7) }
                    }
                }
                .disabled(working || photos.isEmpty)
                ProblemText(text: problem)
                if let done {
                    Label("PDF пришёл в чат с ботом — оттуда его можно переслать заказчику.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(AIText.attributed(done)).font(.footnote)
                }
            }
        }
        .navigationTitle("Фотоотчёт")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: picked) { items in
            guard !items.isEmpty else { return }
            Task {
                for it in items where photos.count < limit {
                    if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        photos.append(TileImage.upright(img))
                        captions.append("")
                    }
                }
                picked = []
            }
        }
    }

    private func send() async {
        working = true
        problem = nil
        defer { working = false }
        let files = photos.compactMap { RoomResult.jpeg($0) }.map { ("photos", $0) }
        var fields = captions.map { ("captions", $0) }
        fields.append(("notes", notes))
        do {
            let d = try await link.apiForm("/api/report", fields: fields, files: files, timeout: 300)
            done = d["summary"] as? String ?? ""
            if let c = (d["credits"] as? NSNumber)?.intValue { profile?.credits = c }
        } catch {
            problem = LinkError.describe(error)
        }
    }
}
