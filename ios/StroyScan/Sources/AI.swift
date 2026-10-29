import PhotosUI
import SwiftUI

// MARK: - Нейросети прямо в приложении: свой ключ kie.ai, без бота и компьютера

enum AIText {
    /// Простой HTML из ответа модели (b, i, code) → текст с жирным и курсивом
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

    /// Без разметки — скопировать или переслать
    static func plain(_ html: String) -> String {
        String(attributed(html).characters)
    }
}

/// Баланс kie.ai, общий для всех экранов нейросетей
@MainActor
final class AIState: ObservableObject {
    @Published var ready = Kie.ready
    @Published var balance: Double?

    func refresh() async {
        ready = Kie.ready
        guard ready else { balance = nil; return }
        balance = try? await Kie.balance()
    }
}

/// Главный экран нейросетей
struct AIView: View {
    /// Комната, из которой открыли: её размеры подставим в смету и КП
    var room: RoomResult? = nil
    @StateObject private var state = AIState()
    @State private var settings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !state.ready {
                    setup
                } else {
                    balance
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        NavigationLink { AIDesignView(state: state) } label: {
                            card("Дизайн по фото", "paintbrush.pointed.fill", "ремонт на вашем фото")
                        }
                        NavigationLink {
                            AITextView(kind: .foreman, state: state,
                                       placeholder: "Например: потолок ГКЛ 50 м², два слоя, нужен список материалов и все этапы с проверкой качества")
                        } label: {
                            card("План работ ИИ", "hammer.fill", "пошаговый наставник для новичка")
                        }
                        NavigationLink {
                            AITextView(kind: .consult, state: state,
                                       placeholder: "Спросите что угодно про ремонт: чем выровнять стены, какой клей для плитки, сколько сохнет стяжка…")
                        } label: {
                            card("Консультант", "bubble.left.and.text.bubble.right.fill", "вопрос голосом или текстом")
                        }
                        NavigationLink {
                            AITextView(kind: .estimate, state: state, prefill: room.map { AIPrompts.estimateRequest($0) + "\nЧто делаем: " },
                                       placeholder: "Что за помещение и что делаем: «ванная 2×1,7 м, высота 2,6, плитка на стены и пол, замена труб»")
                        } label: {
                            card("Смета", "list.bullet.rectangle.portrait.fill", room == nil ? "по описанию" : "по размерам скана")
                        }
                        NavigationLink {
                            AITextView(kind: .kp, state: state, prefill: room.map { AIPrompts.estimateRequest($0) + "\nЗаказчик и работы: " },
                                       placeholder: "Для кого, какие работы, сроки и цена — соберу аккуратное КП для заказчика")
                        } label: {
                            card("КП заказчику", "doc.text.fill", "этапы, сроки, цена")
                        }
                        NavigationLink { AICheckView(state: state) } label: {
                            card("Проверка работы", "checkmark.seal.fill", "брак по фото")
                        }
                        NavigationLink { AIReportView(state: state) } label: {
                            card("Фотоотчёт PDF", "photo.stack.fill", "заказчику за минуту")
                        }
                    }
                    .buttonStyle(PressStyle())
                    Text("Работает без бота и компьютера: приложение само обращается к нейросетям kie.ai с вашим ключом. Нужен только интернет. Тратятся кредиты kie.ai.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Нейросети")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Ключ и модели")
            }
        }
        .sheet(isPresented: $settings, onDismiss: { Task { await state.refresh() } }) { KieSettingsView() }
        .task { await state.refresh() }
        .refreshable { await state.refresh() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Подключите нейросети", systemImage: "key.fill").font(.headline)
            Text("Нужен ключ kie.ai — тот же, что у бота. Вставьте его один раз: он хранится только в этом iPhone, и дальше всё работает без бота и компьютера.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { settings = true } label: {
                Text("Вставить ключ").bold().frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(Palette.ink)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var balance: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Баланс kie.ai").font(.caption).foregroundStyle(.white.opacity(0.7))
                Text(state.balance.map { "\(Int($0)) кредитов" } ?? "—").font(.title2.bold()).foregroundStyle(.white)
            }
            Spacer()
            Link(destination: URL(string: "https://kie.ai/billing")!) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("Пополнить").bold()
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .background(Palette.signal, in: Capsule())
                .foregroundStyle(Palette.ink)
            }
        }
        .padding()
        .background(Palette.black, in: RoundedRectangle(cornerRadius: 20))
    }

    private func card(_ title: String, _ icon: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(Palette.signal)
            Text(title).font(.headline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            Text(sub).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.black, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Ошибка одной строкой под кнопкой
private struct ProblemText: View {
    let text: String?
    var body: some View {
        if let text { Text(text).font(.footnote).foregroundStyle(.red) }
    }
}

/// Большая жёлтая кнопка с крутилкой
private struct GoButton: View {
    let title: String
    let busyTitle: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if busy { ProgressView() }
                Text(busy ? busyTitle : title).bold()
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(Palette.ink)
        }
    }
}

/// Ответ ИИ: текст с жирным, копировать, переслать
struct AIAnswer: View {
    let html: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AIText.attributed(html)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 18) {
                Button {
                    UIPasteboard.general.string = AIText.plain(html)
                    copied = true
                } label: { Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: AIText.plain(html)) { Label("Переслать", systemImage: "square.and.arrow.up") }
            }
            .font(.subheadline.bold())
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Текстовые инструменты: консультант, смета, КП
struct AITextView: View {
    enum Kind {
        case consult, estimate, kp, foreman
        var title: String {
            switch self {
            case .consult: return "Консультант"
            case .estimate: return "Смета"
            case .kp: return "Коммерческое предложение"
            case .foreman: return "План работ ИИ"
            }
        }
        var system: String {
            switch self {
            case .consult: return AIPrompts.consult
            case .estimate: return AIPrompts.estimate
            case .kp: return AIPrompts.kp
            case .foreman: return AIPrompts.foreman
            }
        }
    }

    let kind: Kind
    @ObservedObject var state: AIState
    var prefill: String? = nil
    let placeholder: String
    @State private var text = ""
    @State private var working = false
    @State private var answer: String?
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
                GoButton(title: kind == .consult ? "Спросить" : "Составить", busyTitle: "Думаю…", busy: working) {
                    Task { await ask() }
                }
                .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                ProblemText(text: problem)
                if let answer { AIAnswer(html: answer) }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(kind.title)
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
            answer = try await Kie.chat(system: kind.system, text: String(text.prefix(4000)))
            await state.refresh()
        } catch {
            problem = KieError.describe(error)
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

/// Картинка из нейросети: показать, сохранить в «Фото», переслать
struct AIImageResult: View {
    let url: URL
    @State private var image: UIImage?
    @State private var saved = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 18) {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        saved = true
                    } label: { Label(saved ? "В «Фото»" : "Сохранить", systemImage: saved ? "checkmark" : "square.and.arrow.down") }
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Ремонт", image: Image(uiImage: image))) {
                        Label("Переслать", systemImage: "square.and.arrow.up")
                    }
                }
                .font(.subheadline.bold())
            } else if failed {
                Text("Картинка не загрузилась.").foregroundStyle(.secondary)
                Link("Открыть в браузере", destination: url)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            saved = false
            if let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d) { image = img } else { failed = true }
        }
    }
}

/// Дизайн по фото: стиль и пожелания → картинка ремонта
struct AIDesignView: View {
    @ObservedObject var state: AIState
    @State private var photo: UIImage?
    @State private var style = "scandi"
    @State private var wishes = ""
    @State private var working = false
    @State private var result: URL?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AIPhotoPicker(photo: $photo)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AIPrompts.styles, id: \.id) { s in
                            Button { style = s.id } label: {
                                Text(s.name).font(.subheadline.weight(.semibold))
                                    .padding(.vertical, 8).padding(.horizontal, 14)
                                    .background(style == s.id ? Palette.signal : Color(.secondarySystemGroupedBackground), in: Capsule())
                                    .foregroundStyle(style == s.id ? .white : Palette.ink)
                            }
                        }
                    }
                }
                TextField("Пожелания: светлее, тёплое дерево, без ковра…", text: $wishes, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                GoButton(title: "Нарисовать ремонт", busyTitle: "Рисую, до 3 минут…", busy: working) { Task { await make() } }
                    .disabled(working || photo == nil)
                ProblemText(text: problem)
                if let result { AIImageResult(url: result) }
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
        let w = wishes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            result = try await Kie.editImage(jpeg, prompt: AIPrompts.fill(AIPrompts.design, [
                "style": AIPrompts.styleEn(style), "extra": w.isEmpty ? "" : "Client wishes (in Russian): \(w)"]))
            await state.refresh()
        } catch {
            problem = KieError.describe(error)
        }
    }
}

/// Проверка работы по фото: ИИ ищет брак и говорит, что переделать
struct AICheckView: View {
    @ObservedObject var state: AIState
    @State private var photo: UIImage?
    @State private var note = ""
    @State private var working = false
    @State private var answer: String?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AIPhotoPicker(photo: $photo)
                TextField("Что смущает: шов, угол, пятна… (можно пусто)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                GoButton(title: "Проверить", busyTitle: "Смотрю…", busy: working) { Task { await check() } }
                    .disabled(working || photo == nil)
                ProblemText(text: problem)
                if let answer { AIAnswer(html: answer) }
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
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            answer = try await Kie.chat(system: AIPrompts.check,
                                        text: "Оцени качество работы на фото." + (n.isEmpty ? "" : " Комментарий заказчика: \(n)"), image: jpeg)
            await state.refresh()
        } catch {
            problem = KieError.describe(error)
        }
    }
}

/// Фотоотчёт: фото с подписями → ИИ пишет резюме → PDF в телефоне, сразу переслать заказчику
struct AIReportView: View {
    @ObservedObject var state: AIState
    @State private var title = ""
    @State private var photos: [UIImage] = []
    @State private var captions: [String] = []
    @State private var notes = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var working = false
    @State private var share: ShareFile?
    @State private var problem: String?

    private let limit = 12

    var body: some View {
        Form {
            Section("Объект") {
                TextField("Например: ЖК Солнечный, кв. 45", text: $title)
            }
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
            Section("Комментарий прораба") {
                TextField("Что сделано за этап, что дальше", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            Section {
                Button { Task { await make() } } label: {
                    HStack {
                        if working { ProgressView() }
                        Text(working ? "Собираю PDF…" : "Собрать отчёт").bold()
                    }
                }
                .disabled(working || photos.isEmpty)
                ProblemText(text: problem)
            } footer: {
                Text("ИИ напишет заказчику короткое резюме по подписям, приложение соберёт PDF с вашим логотипом — и сразу откроет «Поделиться».")
            }
        }
        .navigationTitle("Фотоотчёт")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
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

    private func make() async {
        working = true
        problem = nil
        defer { working = false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let caps = captions.enumerated().map { "Фото \($0.offset + 1): \($0.element.isEmpty ? "без подписи" : $0.element)" }.joined(separator: "\n")
        do {
            let summary = try await Kie.chat(system: AIPrompts.report,
                                             text: "Объект: \(name.isEmpty ? "не указан" : name)\nОбщий комментарий прораба: \(notes.isEmpty ? "нет" : notes)\n\(caps)",
                                             maxTokens: 800)
            if let url = PlanPDF.photoReport(title: name.isEmpty ? "Фотоотчёт о ходе работ" : "Фотоотчёт: \(name)", summary: summary,
                                             photos: Array(zip(photos, captions))) {
                share = ShareFile(url: url)
            } else {
                problem = "Не получилось собрать PDF."
            }
            await state.refresh()
        } catch {
            problem = KieError.describe(error)
        }
    }
}
