import Combine
import Photos
import SceneKit
import SwiftUI

/// Снимок «как в жизни» от бота и кадр 3D, с которого он нарисован
struct RenderShot: Identifiable {
    let id = UUID()
    let url: URL
    let before: UIImage
    let credits: Int?
}

/// Файл для «Поделиться»
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Сцена SceneKit из редактора
struct EditorScene: UIViewRepresentable {
    let editor: RenoEditor

    func makeUIView(context: Context) -> SCNView { editor.view }
    func updateUIView(_ uiView: SCNView, context: Context) {}
}

// MARK: - Экран «Ремонт в 3D»

/// Ремонт в 3D по скану: крутить, смотреть из комнаты, менять отделку, свет, шторы и мебель.
struct Renovation3DView: View {
    @EnvironmentObject var link: BotLink
    @StateObject private var editor: RenoEditor
    @Binding var look: Look
    /// Отправить скан в бот (true — заново) и вернуть его номер
    let ensureScanId: (Bool) async throws -> Int
    @State private var scanId: Int?
    @State private var saveTask: Task<Void, Never>?
    @State private var synced = false
    @State private var rendering = false
    @State private var alert: String?
    @State private var shot: RenderShot?
    @State private var share: ShareFile?

    init(result: RoomResult, look: Binding<Look>, scanId: Int?, ensureScanId: @escaping (Bool) async throws -> Int) {
        _editor = StateObject(wrappedValue: RenoEditor(result: result, look: look.wrappedValue))
        _look = look
        _scanId = State(initialValue: scanId)
        self.ensureScanId = ensureScanId
    }

    var body: some View {
        VStack(spacing: 0) {
            styleChips
            ZStack {
                EditorScene(editor: editor)
                if !editor.ready {
                    ProgressView("Собираю комнату…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                VStack(spacing: 0) {
                    modeBar
                    Spacer()
                    if editor.pick == nil && editor.ready { hintBar }
                }
            }
            if let pick = editor.pick {
                EditPanel(editor: editor, pick: pick, alert: $alert)
            }
            bottomBar
        }
        .navigationTitle("Ремонт в 3D")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { shareScanFile() } label: { Label("Файл скана для бота", systemImage: "doc") }
                    Button {
                        if let url = editor.exportUSDZ() { share = ShareFile(url: url) } else { alert = "Не получилось сохранить модель." }
                    } label: { Label("3D-модель (USDZ)", systemImage: "cube") }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Поделиться")
            }
        }
        .onAppear { editor.start() }
        .onDisappear { editor.stop() }
        .task { await syncLook() }
        .onReceive(editor.$look.dropFirst()) { new in
            look = new
            scheduleSave(new)
        }
        .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
        .fullScreenCover(item: $shot) { RenderResultView(shot: $0) }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("Понятно", role: .cancel) {}
        }
    }

    // MARK: Панели

    private var styleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RenoStyle.allCases) { s in
                    Button { editor.setStyle(s) } label: {
                        Text(s.title).font(.subheadline.bold())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(s.rawValue == editor.look.style ? Palette.signal : Color(.secondarySystemGroupedBackground),
                                        in: Capsule())
                            .foregroundStyle(Palette.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            Picker("Вид", selection: Binding(get: { editor.inside }, set: { editor.setInside($0) })) {
                Text("Сверху").tag(false)
                Text("Из комнаты").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            if editor.inside {
                Button { editor.nextViewpoint() } label: {
                    Label("Другой угол", systemImage: "arrow.triangle.2.circlepath.camera")
                        .font(.footnote.bold())
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private var hintBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editor.inside ? "Ведите пальцем — осмотреться, двумя — приблизить. Нажмите на вещь, чтобы поменять."
                               : "Крутите пальцем, двумя — двигайте и приближайте. Нажмите на вещь, чтобы поменять.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quick("Стены", "paintbrush") { editor.select(.wall(editor.firstWall)) }
                    quick("Пол", "square.grid.3x3") { editor.select(.floor) }
                    quick("Свет", "lightbulb") { editor.select(.ceiling) }
                    if let w = editor.firstWindow {
                        quick("Шторы", "curtains.closed") { editor.select(.window(w)) }
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(10)
    }

    private func quick(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(.systemBackground).opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                furnitureMenu
                Button { Task { await makeReal() } } label: {
                    HStack(spacing: 8) {
                        if rendering { ProgressView() } else { Image(systemName: "camera.filters") }
                        Text(rendering ? "Рисую, до 3 минут…" : "Как в жизни").bold()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Palette.ink)
                }
                .disabled(rendering || !editor.ready)
            }
            if editor.pick == nil {
                Text("«Как в жизни» — ИИ превратит вид из комнаты в фото. Тратит кредиты в боте.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var furnitureMenu: some View {
        Menu {
            Section("Добавить мебель") {
                ForEach(LookOptions.addable) { c in
                    let variants = LookOptions.variants(c.id)
                    if variants.isEmpty {
                        Button(c.title) { addItem(c.id, "default") }
                    } else {
                        Menu(c.title) {
                            ForEach(variants) { v in
                                Button(v.title) { addItem(c.id, v.id) }
                            }
                        }
                    }
                }
            }
            if editor.hasHidden {
                Button { editor.restoreHidden() } label: {
                    Label("Вернуть убранное", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label("Мебель", systemImage: "plus")
                .font(.headline)
                .padding(.vertical, 14).padding(.horizontal, 16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(Palette.ink)
        }
    }

    // MARK: Действия

    private func addItem(_ kind: String, _ variant: String) {
        switch editor.add(kind: kind, variant: variant) {
        case .tooMany: alert = "Добавить можно не больше \(Look.maxAdded) вещей."
        case .noRoom: alert = "Эта вещь не помещается в комнату."
        case .added: break
        }
    }

    private func shareScanFile() {
        if let url = editor.result.exportFile(look: editor.look) {
            share = ShareFile(url: url)
        } else {
            alert = "Не получилось сохранить файл."
        }
    }

    private func currentScanId(fresh: Bool) async throws -> Int {
        if !fresh, let scanId { return scanId }
        let id = try await ensureScanId(fresh)
        scanId = id
        return id
    }

    /// Снимок 3D из комнаты → бот дорисовывает его до фото
    private func makeReal() async {
        guard link.connected else {
            alert = "Подключите бота на главном экране — фото рисует СтройБот."
            return
        }
        rendering = true
        defer { rendering = false }
        editor.select(nil)
        if !editor.inside {
            editor.setInside(true)
            // даём камере привыкнуть к свету
            try? await Task.sleep(nanoseconds: 1_600_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let before = editor.snapshot()
        guard let jpeg = RoomResult.jpeg(before) else {
            alert = "Не получилось снять 3D. Попробуйте ещё раз."
            return
        }
        let current = editor.look
        do {
            let answer: (image: URL, credits: Int?)
            do {
                let id = try await currentScanId(fresh: false)
                answer = try await link.render(scanId: id, image: jpeg, style: current.style, look: current.json)
            } catch LinkError.scanMissing {
                let id = try await currentScanId(fresh: true)
                answer = try await link.render(scanId: id, image: jpeg, style: current.style, look: current.json)
            }
            shot = RenderShot(url: answer.image, before: before, credits: answer.credits)
        } catch {
            alert = LinkError.describe(error)
        }
    }

    /// Ремонт, собранный в боте или Mini App, — если здесь ещё ничего не меняли
    private func syncLook() async {
        guard !synced, let id = scanId, link.connected else { return }
        synced = true
        guard editor.look == (RenoStyle(rawValue: editor.look.style) ?? .scandi).finishes else { return }
        guard let raw = try? await link.look(scanId: id), !raw.isEmpty else { return }
        editor.replace(Look(json: raw, base: editor.look))
    }

    /// Сохраняем ремонт в боте через секунду после последней правки
    private func scheduleSave(_ new: Look) {
        saveTask?.cancel()
        guard let id = scanId, link.connected else { return }
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            try? await link.saveLook(scanId: id, look: new.json)
        }
    }
}

// MARK: - Панель правки

struct EditPanel: View {
    @ObservedObject var editor: RenoEditor
    let pick: RenoEditor.Pick
    /// Сообщение на экране ремонта (вещь не помещается и т.п.)
    @Binding var alert: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { editor.select(nil) } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Закрыть")
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var title: String {
        switch pick {
        case .wall(let i): return editor.look.accent?.wall == i ? "Стена \(i + 1) — акцент" : "Стены"
        case .floor: return "Пол"
        case .ceiling: return "Потолок и свет"
        case .window: return "Окна"
        case .door: return "Дверь"
        case .object(let i): return editor.result.items.indices.contains(i) ? editor.result.items[i].title : "Мебель"
        case .added(let j):
            return editor.look.added.indices.contains(j) ? RoomResult.itemTitle(editor.look.added[j].kind) : "Мебель"
        }
    }

    @ViewBuilder private var content: some View {
        switch pick {
        case .wall(let i):
            wall(i)
        case .floor:
            Chips(items: LookOptions.floorFinishes, selected: editor.look.floor.finish) { editor.setFloor(finish: $0) }
            Swatches(colors: LookOptions.floorColors, selected: editor.look.floor.color) { editor.setFloor(color: $0) }
        case .ceiling:
            Chips(items: LookOptions.lights, selected: editor.look.ceiling.light) { editor.setCeiling(light: $0) }
            Text("Цвет потолка").font(.caption).foregroundStyle(.secondary)
            Swatches(colors: LookOptions.ceilingColors, selected: editor.look.ceiling.color) { editor.setCeiling(color: $0) }
        case .window:
            Text("Шторы на всех окнах").font(.caption).foregroundStyle(.secondary)
            Chips(items: LookOptions.curtains, selected: editor.look.curtains) { editor.setCurtains($0) }
        case .door:
            Text("Двери и наличники меняются вместе со стилем.").font(.subheadline).foregroundStyle(.secondary)
        case .object(let i):
            object(i)
        case .added(let j):
            added(j)
        }
    }

    @ViewBuilder private func wall(_ i: Int) -> some View {
        let accent = editor.look.accent?.wall == i
        let f = editor.wallFinish(i)
        Picker("Какие стены", selection: Binding(get: { accent }, set: { editor.setAccent($0 ? i : nil) })) {
            Text("Все стены").tag(false)
            Text("Только эта стена").tag(true)
        }
        .pickerStyle(.segmented)
        Chips(items: LookOptions.wallFinishes, selected: f.finish) { editor.editWall(i, finish: $0) }
        if f.finish == "wallpaper" {
            Chips(items: LookOptions.patterns, selected: f.pattern) { editor.editWall(i, pattern: $0) }
        }
        Swatches(colors: LookOptions.wallColors, selected: f.color) { editor.editWall(i, color: $0) }
    }

    @ViewBuilder private func object(_ i: Int) -> some View {
        if editor.result.items.indices.contains(i) {
            let item = editor.result.items[i]
            let variant = editor.variant(ofItem: i)
            let variants = LookOptions.variants(item.kind)
            Text("\(sizeText(item.width, item.depth, item.height)) — размер из скана")
                .font(.caption).foregroundStyle(.secondary)
            if !variants.isEmpty {
                Chips(items: variants, selected: variant) { editor.setObject(i, variant: $0) }
            }
            Swatches(colors: LookOptions.colors(kind: item.kind, variant: variant), selected: editor.color(ofItem: i)) {
                editor.setObject(i, color: $0)
            }
            Button(role: .destructive) { editor.hideObject(i) } label: {
                Label("Убрать", systemImage: "trash").font(.subheadline.bold())
            }
        }
    }

    @ViewBuilder private func added(_ j: Int) -> some View {
        if editor.look.added.indices.contains(j) {
            let a = editor.look.added[j]
            let variants = LookOptions.variants(a.kind)
            Text("\(sizeText(a.width, a.depth, a.height)). Двигайте пальцем по полу.")
                .font(.caption).foregroundStyle(.secondary)
            if !variants.isEmpty {
                Chips(items: variants, selected: a.variant) {
                    if !editor.setAdded(j, variant: $0) { alert = "Такой вариант в комнату не помещается." }
                }
            }
            Swatches(colors: LookOptions.colors(kind: a.kind, variant: a.variant), selected: a.color) {
                editor.setAdded(j, color: $0)
            }
            HStack(spacing: 16) {
                Button {
                    if !editor.rotateAdded(j) { alert = "Повёрнутой эта вещь в комнату не помещается." }
                } label: {
                    Label("Повернуть", systemImage: "rotate.right").font(.subheadline.bold())
                }
                Button(role: .destructive) { editor.removeAdded(j) } label: {
                    Label("Убрать", systemImage: "trash").font(.subheadline.bold())
                }
            }
        }
    }

    /// «200 × 90 × 85 см»
    private func sizeText(_ w: Double, _ d: Double, _ h: Double) -> String {
        let cm = { (v: Double) in Int((v * 100).rounded()) }
        return "\(cm(w)) × \(cm(d)) × \(cm(h)) см"
    }
}

/// Кнопки-варианты в ряд
struct Chips: View {
    let items: [Choice]
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { c in
                    Button { onPick(c.id) } label: {
                        Text(c.title).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(c.id == selected ? Palette.signal : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(c.id == selected ? Palette.ink : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Цвета кружками
struct Swatches: View {
    let colors: [String]
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(colors, id: \.self) { hex in
                    Button { onPick(hex) } label: {
                        Circle()
                            .fill(Color(UIColor(hex: hex)))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay(Circle().stroke(Palette.signal, lineWidth: hex == selected?.lowercased() ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Цвет \(hex)")
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Фото «как в жизни»

struct RenderResultView: View {
    let shot: RenderShot
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var data: Data?
    @State private var failed = false
    @State private var comparing = false
    @State private var note: String?
    @State private var share: ShareFile?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: comparing ? shot.before : image)
                        .resizable().scaledToFit()
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in comparing = true }
                            .onEnded { _ in comparing = false })
                    VStack {
                        Spacer()
                        Text(comparing ? "Это 3D-модель" : "Держите палец на картинке — покажу 3D, с которого она нарисована")
                            .font(.footnote).foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding()
                    }
                } else if failed {
                    VStack(spacing: 14) {
                        Text("Не удалось загрузить картинку.").foregroundStyle(.white)
                        Button("Ещё раз") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Как в жизни")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { Task { await save() } } label: { Label("Сохранить", systemImage: "square.and.arrow.down") }
                        .disabled(image == nil)
                    Spacer()
                    if let credits = shot.credits { Text("Кредитов: \(credits)").font(.footnote) }
                    Spacer()
                    Button { shareImage() } label: { Label("Поделиться", systemImage: "square.and.arrow.up") }
                        .disabled(data == nil)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
        }
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            let (d, resp) = try await URLSession.shared.data(from: shot.url)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
            guard (200...299).contains(status), let img = UIImage(data: d) else {
                failed = true
                return
            }
            data = d
            image = img
        } catch {
            failed = true
        }
    }

    private func save() async {
        guard let image else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            note = "Сохранено в «Фото»."
        } catch {
            note = "Не получилось сохранить. Разрешите доступ: Настройки → СтройСкан → Фото."
        }
    }

    private func shareImage() {
        guard let data else { return }
        let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(png ? "Ремонт.png" : "Ремонт.jpg")
        try? FileManager.default.removeItem(at: url)
        guard (try? data.write(to: url)) != nil else { return }
        share = ShareFile(url: url)
    }
}
