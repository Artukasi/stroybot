import PhotosUI
import SwiftUI
import simd

/// Стили ИИ-ремонта на фото. Ключи совпадают с bot/prompts.py → DESIGN_STYLES.
struct DesignStyle: Identifiable {
    let key: String
    let title: String
    var id: String { key }
}

let designStyles: [DesignStyle] = [
    DesignStyle(key: "scandi", title: "Скандинавский"),
    DesignStyle(key: "loft", title: "Лофт"),
    DesignStyle(key: "modern", title: "Современный"),
    DesignStyle(key: "classic", title: "Неоклассика"),
    DesignStyle(key: "japandi", title: "Джапанди"),
    DesignStyle(key: "budget", title: "Бюджетный ремонт"),
]

/// Комната из истории: читаем с диска один раз
struct SavedRoomView: View {
    @EnvironmentObject var store: ScanStore
    @EnvironmentObject var hub: ScanHub
    let id: UUID
    let onRescan: () -> Void
    @State private var loaded: RoomResult?
    @State private var missing = false

    var body: some View {
        Group {
            if let loaded {
                ResultView(savedID: id, result: loaded, canContinue: hub.rooms(for: id) != nil, onRescan: onRescan)
            } else if missing {
                Text("Скан не найден. Возможно, его удалили.").foregroundStyle(.secondary).padding()
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard loaded == nil else { return }
            loaded = store.result(id)
            missing = loaded == nil
        }
    }
}

/// Результат скана: план сверху с длинами стен, площади и отправка в бот.
struct ResultView: View {
    @EnvironmentObject var link: BotLink
    @EnvironmentObject var store: ScanStore
    @EnvironmentObject var hub: ScanHub
    /// Запись в истории «Мои комнаты»
    let savedID: UUID
    @State var result: RoomResult
    /// Телефон ещё помнит комнату: «Доснять» продолжит этот скан
    var canContinue = false
    /// «Доснять / Переснять»
    var onRescan: (() -> Void)? = nil
    @State private var drawn: CGFloat = 0
    @State private var sent = false
    /// Номер скана в боте (у каждой комнаты свой)
    @State private var scanId: Int?
    @State private var loadedLook = false
    @State private var counted = false
    @State private var sending = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var designStyle = "scandi"
    @State private var designing = false
    @State private var designURL: URL?
    @State private var designError: String?
    @State private var credits: Int?
    /// Ремонт, собранный в 3D (стиль, отделка, мебель)
    @State private var look = RenoStyle.scandi.finishes
    @State private var camera = false
    @State private var share: ShareFile?
    @State private var note: String?
    private let rooms = ["Комната", "Кухня", "Ванная", "Санузел", "Спальня", "Гостиная", "Детская", "Коридор", "Балкон"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AssembleView(result: result)
                planView
                qualityCard

                Picker("Помещение", selection: $result.room) {
                    ForEach(rooms, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                statsGrid
                if !result.engineering.isEmpty { engineeringCard }
                DefectsSection(scanID: savedID, result: $result)
                if !result.items.isEmpty { furnitureList }
                photoSection

                if !result.wallLines.isEmpty {
                    NavigationLink {
                        Renovation3DView(result: result, look: $look, engineering: $result.engineering, liveScan: canContinue,
                                         scanId: sent ? scanId : nil) { fresh in
                            try await ensureScanId(fresh: fresh)
                        }
                    } label: {
                        Label("Ремонт в 3D: крутить и менять", systemImage: "cube.transparent")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Palette.draft, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.white)
                    }
                }

                NavigationLink {
                    FurnitureSizesView { fresh in try await ensureScanId(fresh: fresh) }
                } label: {
                    Label("Мебель по размерам", systemImage: "sofa")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(Palette.ink)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    NavigationLink { EstimateView(result: result) } label: {
                        tool("Смета", "rublesign.circle", "материалы и работы")
                    }
                    NavigationLink { ClientDocView(scanID: savedID, result: result) } label: {
                        tool("Клиенту", "signature", "смета, план, подпись")
                    }
                    if result.plan.count > 2 {
                        NavigationLink { TileLayoutView(result: result) } label: {
                            tool("Раскладка", "square.grid.3x3", "плитка и ламинат")
                        }
                        NavigationLink { WarmFloorView(result: result) } label: {
                            tool("Тёплый пол", "thermometer.sun", "кабель, мат, вода")
                        }
                    }
                    if !result.wallLines.isEmpty {
                        NavigationLink { KitchenView(result: result) } label: {
                            tool("Кухня", "cooktop", "модули по размерам")
                        }
                    }
                    if versionCount > 0 {
                        NavigationLink { CompareView(id: savedID, now: result) } label: {
                            tool("Было — стало", "clock.arrow.2.circlepath", versionCount == 1 ? "прошлая съёмка" : "съёмок: \(versionCount)")
                        }
                    } else {
                        Button { shareDXF() } label: { tool("Чертёж DXF", "pencil.and.ruler", "для AutoCAD") }
                    }
                }
                .buttonStyle(PressStyle())

                sendButton
                if sent, let scanId { designSection(scanId) }
                Button { sharePDF() } label: {
                    Label("План в PDF — для клиента или магазина", systemImage: "doc.richtext")
                }
                if versionCount > 0 {
                    Button { shareDXF() } label: {
                        Label("Чертёж DXF — для AutoCAD и дизайнера", systemImage: "pencil.and.ruler")
                    }
                }
                Button { shareScanFile() } label: {
                    Label("Файл скана для бота", systemImage: "doc.badge.arrow.up")
                }
                Text("Пришлите этот файл в чат СтройБота — ремонт и смета посчитаются прямо по размерам скана.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let usdz = result.usdz {
                    ShareLink(item: usdz) { Label("3D-модель комнаты (USDZ)", systemImage: "cube") }
                }
            }
            .padding()
        }
        .navigationTitle(result.room)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .onAppear {
            scanId = store.botScanId(savedID, server: link.server)
            sent = scanId != nil
            if !loadedLook, let saved = store.look(savedID) { look = saved }
            loadedLook = true
        }
        .onChange(of: look) { l in
            if loadedLook { store.setLook(savedID, l) }
        }
        .onChange(of: result.room) { _ in store.update(savedID, result: result) }
        .onChange(of: result.engineering) { _ in store.update(savedID, result: result) }
        .onChange(of: result.defects) { _ in store.update(savedID, result: result) }
        .fullScreenCover(isPresented: $camera) {
            PhotoCameraView { data in usePhoto(data) }
        }
        .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Качество скана

    @ViewBuilder private var qualityCard: some View {
        let q = result.quality
        if q.issues.isEmpty {
            Label("Скан без замечаний · \(q.score) из 100", systemImage: "checkmark.seal.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Нужно доснять").font(.headline)
                    Spacer()
                    Text("\(q.score) из 100").font(.subheadline.bold()).foregroundStyle(.secondary)
                }
                ForEach(Array(q.issues.enumerated()), id: \.offset) { _, issue in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(issue).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                }
                if !q.weakWalls.isEmpty {
                    Text("Оранжевые номера на плане — стены, которые стоит доснять.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let onRescan {
                    Button { onRescan() } label: {
                        Label("Доснять / Переснять", systemImage: "arrow.clockwise")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Palette.ink)
                    }
                    Text(canContinue
                         ? "Скан продолжится с того же места: доснимите только места из списка — они сами добавятся к комнате."
                         : "Скан начнётся заново: снимите комнату целиком, задержитесь на местах из списка.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - План

    private var planView: some View {
        PlanShape(points: result.plan)
            .trim(from: 0, to: drawn)
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            .background(PlanShape(points: result.plan).fill(Palette.draft.opacity(0.1)))
            .background(PlanFurniture(points: result.plan, items: result.items).opacity(drawn >= 1 ? 1 : 0))
            .overlay(PlanLabels(points: result.plan).opacity(drawn >= 1 ? 1 : 0))
            .overlay(PlanWalls(points: result.plan, lines: result.wallLines, weak: result.quality.weakWalls)
                .opacity(drawn >= 1 ? 1 : 0))
            .overlay(PlanEngineering(eng: result.engineering, points: result.plan).opacity(drawn >= 1 ? 1 : 0))
            .overlay(PlanDefects(defects: result.defects, points: result.plan).opacity(drawn >= 1 ? 1 : 0))
            .aspectRatio(max(0.6, min(1.8, result.length / max(result.width, 0.1))), contentMode: .fit)
            .padding(28)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .onAppear { withAnimation(.easeOut(duration: 1.4)) { drawn = 1 } }
    }

    // MARK: - Электрика и сантехника

    private var engineeringCard: some View {
        let rows = result.engineering.summary(ceiling: result.height, wallLines: result.wallLines)
        return VStack(alignment: .leading, spacing: 8) {
            Label("Электрика и сантехника", systemImage: "bolt.horizontal.circle").font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Circle().fill(row.group == .electric ? Color(EngKind.electricColor) : Color(EngKind.coldColor))
                        .frame(width: 8, height: 8)
                    Text(row.title)
                    Spacer()
                    Text(row.value).bold().monospacedDigit()
                }
                .font(.subheadline)
            }
            Text("Расставляется в «Ремонт в 3D» → Электрика / Сантехника. Кабель и трубы — оценка с запасом.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Цифры

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            stat("Пол", result.floorArea, "м²", 0)
            stat("Стены без проёмов", result.wallArea, "м²", 1)
            stat("Периметр", result.perimeter, "м", 2)
            stat("Высота", result.height, "м", 3)
            stat("Длина × ширина", "\(fmt(result.length)) × \(fmt(result.width))", "м", 4)
            stat("Окна и двери", "\(result.windows) и \(result.doors)", "шт", 5)
            stat("Плинтус", result.skirting, "м", 6)
            stat("Откосы окон", result.slopes, "м", 7)
        }
        .onAppear {
            guard !counted else { return }
            withAnimation(.easeOut(duration: 1.3).delay(0.3)) { counted = true }
        }
    }

    /// Число набегает от нуля, карточки появляются по очереди
    private func stat(_ title: String, _ value: Double, _ unit: String, _ i: Int) -> some View {
        statCard(title, i) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountUp(value: counted ? value : 0).font(.title3.bold())
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ unit: String, _ i: Int) -> some View {
        statCard(title, i) {
            Text(value).font(.title3.bold()) + Text(" \(unit)").font(.subheadline).foregroundColor(.secondary)
        }
    }

    private func statCard<C: View>(_ title: String, _ i: Int, @ViewBuilder _ value: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .opacity(counted ? 1 : 0)
        .offset(y: counted ? 0 : 14)
        .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.05 * Double(i)), value: counted)
    }

    private var furnitureList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Мебель и техника").font(.headline)
            ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(furnitureColor(item.kind)).frame(width: 14, height: 14)
                    Text(item.title)
                    Spacer()
                    Text(sizeText(item)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("Ширина × глубина × высота, см").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func sizeText(_ item: RoomResult.Item) -> String {
        let w = Int((item.width * 100).rounded())
        let d = Int((item.depth * 100).rounded())
        let h = Int((item.height * 100).rounded())
        return "\(w) × \(d) × \(h)"
    }

    // MARK: - Фото

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Фото комнаты").font(.headline)
            if let data = result.photo, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Text("Фото нет. Выберите снимок комнаты, чтобы ИИ показал ремонт.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { hub.pause(); camera = true } label: {
                Label("Снять фото камерой", systemImage: "camera")
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Выбрать фото из галереи", systemImage: "photo.on.rectangle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = RoomResult.jpeg(image) else { return }
        usePhoto(jpeg)
    }

    private func usePhoto(_ jpeg: Data) {
        result.photo = jpeg
        // новое фото нужно заново отправить в бот
        sent = false
        scanId = nil
        designURL = nil
        store.update(savedID, result: result, resend: true)
    }

    private func sharePDF() {
        if let url = PlanPDF.room(result, photos: { store.defectPhoto(savedID, $0) }) {
            share = ShareFile(url: url)
        } else {
            note = "Не получилось собрать PDF."
        }
    }

    private var versionCount: Int { store.versionCount(savedID) }

    private func tool(_ title: String, _ icon: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.title2).foregroundStyle(Palette.signal)
            Text(title).font(.headline).foregroundStyle(.white)
            Text(sub).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 18))
    }

    private func shareDXF() {
        if let url = PlanDXF.room(result) {
            share = ShareFile(url: url)
        } else {
            note = "Не получилось собрать чертёж."
        }
    }

    private func shareScanFile() {
        if let url = result.exportFile(look: look) {
            share = ShareFile(url: url)
        } else {
            note = "Не получилось сохранить файл."
        }
    }

    /// Ремонт в 3D меняли — его стоит сохранить в боте вместе со сканом
    private var lookChanged: Bool {
        look != (RenoStyle(rawValue: look.style) ?? .scandi).finishes
    }

    /// Номер скана в боте; если скан ещё не отправлен (или fresh) — отправляет молча
    private func ensureScanId(fresh: Bool) async throws -> Int {
        if !fresh, sent, let id = scanId { return id }
        guard link.connected else { throw LinkError.message("Подключите бота на главном экране.") }
        guard let id = try await link.sendScan(result) else {
            throw LinkError.message("Сервер ответил странно. Попробуйте ещё раз.")
        }
        sent = true
        scanId = id
        store.setSent(savedID, botScanId: id, server: link.server)
        if lookChanged { try? await link.saveLook(scanId: id, look: look.json) }
        return id
    }

    // MARK: - Отправка

    private var pending: Bool { store.scan(savedID)?.pending ?? false }

    private var sendButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { Task { await send() } } label: {
                Group {
                    if sending { ProgressView() }
                    else if sent { Label("Отправлено в СтройБот", systemImage: "checkmark") }
                    else if pending { Label("Ждёт связи с ботом", systemImage: "clock.arrow.circlepath") }
                    else { Label("Отправить в СтройБот", systemImage: "paperplane.fill") }
                }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(pending && !sent ? Color.orange.opacity(0.25) : Palette.signal, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(Palette.ink)
            }
            .disabled(sending)
            if pending && !sent {
                Text("Скан в очереди: уйдёт в бот сам, как только появится связь. Нажмите, чтобы попробовать сейчас.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !link.connected {
                Text("Бот не подключён — скан встанет в очередь и уйдёт, когда подключите.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: store.scan(savedID)?.botScanId) { id in
            // ушёл из очереди, пока экран открыт
            if let id, !sent, store.scan(savedID)?.botServer == link.server { scanId = id; sent = true }
        }
    }

    /// Отправить; нет связи — в очередь, уйдёт сам
    private func send() async {
        guard link.connected else {
            store.setPending(savedID, true)
            note = "Скан в очереди: уйдёт в бот, когда подключите бота."
            return
        }
        sending = true
        defer { sending = false }
        do {
            guard let id = try await link.sendScan(result) else { throw LinkError.message("Сервер ответил странно. Попробуйте ещё раз.") }
            scanId = id
            sent = true
            store.setSent(savedID, botScanId: id, server: link.server)
            if lookChanged { try? await link.saveLook(scanId: id, look: look.json) }
            note = "Скан отправлен в бот."
        } catch LinkError.offline(let why) {
            store.setPending(savedID, true)
            note = "\(why)\n\nСкан в очереди: уйдёт в бот сам, как только бот станет доступен."
        } catch {
            note = LinkError.describe(error)
        }
    }

    // MARK: - ИИ-ремонт на фото

    private func designSection(_ scanId: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ремонт на фото").font(.headline)
            Text("ИИ перерисует фото комнаты в выбранном стиле. Тратит кредиты в боте.")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Стиль", selection: $designStyle) {
                ForEach(designStyles) { Text($0.title).tag($0.key) }
            }
            .pickerStyle(.menu)
            Button {
                Task { await runDesign(scanId) }
            } label: {
                HStack {
                    if designing { ProgressView() }
                    Text(designing ? "ИИ рисует, это до 3 минут…" : "Показать ремонт на фото").bold()
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(Palette.ink)
            }
            .disabled(designing || result.photo == nil)
            if result.photo == nil {
                Text("Нужно фото комнаты").font(.footnote).foregroundStyle(.secondary)
            }
            if let designError {
                Text(designError).font(.footnote).foregroundStyle(.red)
            }
            if let designURL { designResult(designURL) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func designResult(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    Text("Не удалось загрузить картинку.").foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
                ShareLink(item: url) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                Spacer()
                if let credits { Text("Кредитов: \(credits)").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private func runDesign(_ scanId: Int) async {
        designing = true
        designError = nil
        defer { designing = false }
        do {
            let answer = try await link.design(scanId: scanId, style: designStyle, look: lookChanged ? look.json : nil)
            designURL = answer.image
            credits = answer.credits
        } catch {
            designError = (error as? LinkError)?.text ?? "Не получилось: \(error.localizedDescription)"
        }
    }
}

/// Цвет мебели на плане
func furnitureColor(_ kind: String) -> Color {
    switch kind {
    case "sofa", "bed", "chair": return Color(red: 0.36, green: 0.55, blue: 0.80)
    case "table", "storage", "stairs": return Color(red: 0.72, green: 0.53, blue: 0.34)
    case "sink", "toilet", "bathtub": return Color(red: 0.45, green: 0.75, blue: 0.80)
    case "refrigerator", "stove", "oven", "dishwasher", "washerDryer": return Color(red: 0.55, green: 0.58, blue: 0.62)
    case "television": return Color(red: 0.25, green: 0.25, blue: 0.3)
    default: return Color(red: 0.6, green: 0.6, blue: 0.6)
    }
}

/// Контур пола, вписанный в рамку
struct PlanShape: Shape {
    let points: [SIMD2<Double>]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pts = fit(points, in: rect)
        guard let first = pts.first else { return p }
        p.move(to: first)
        pts.dropFirst().forEach { p.addLine(to: $0) }
        p.closeSubpath()
        return p
    }
}

/// Мебель на плане: повёрнутые прямоугольники
struct PlanFurniture: View {
    let points: [SIMD2<Double>]
    let items: [RoomResult.Item]

    var body: some View {
        Canvas { context, size in
            guard let frame = planFrame(points, in: CGRect(origin: .zero, size: size)) else { return }
            for item in items {
                let w = CGFloat(item.width) * frame.k
                let d = CGFloat(item.depth) * frame.k
                let cx = frame.ox + CGFloat(item.x) * frame.k
                let cy = frame.oy + CGFloat(item.y) * frame.k
                var t = CGAffineTransform(translationX: cx, y: cy)
                t = t.rotated(by: CGFloat(item.angle))
                let rect = CGRect(x: -w / 2, y: -d / 2, width: w, height: d)
                let path = Path(roundedRect: rect, cornerRadius: 2).applying(t)
                let color = furnitureColor(item.kind)
                context.fill(path, with: .color(color.opacity(0.55)))
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
        }
    }
}

/// Длины стен у каждой стороны плана
struct PlanLabels: View {
    let points: [SIMD2<Double>]

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let pts = fit(points, in: rect)
            let cx = pts.map(\.x).reduce(0, +) / CGFloat(max(pts.count, 1))
            let cy = pts.map(\.y).reduce(0, +) / CGFloat(max(pts.count, 1))
            ForEach(Array(points.indices), id: \.self) { i in
                let j = (i + 1) % points.count
                let len = simd_distance(points[i], points[j])
                if len > 0.4, pts.count == points.count {
                    let mx = (pts[i].x + pts[j].x) / 2
                    let my = (pts[i].y + pts[j].y) / 2
                    let d = max(hypot(mx - cx, my - cy), 1)
                    Text(fmt(len))
                        .font(.caption.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Palette.signal, in: Capsule())
                        .foregroundStyle(Palette.ink)
                        .position(x: mx + (mx - cx) / d * 16, y: my + (my - cy) / d * 16)
                }
            }
        }
    }
}

/// Номера стен на плане; стены, которые стоит доснять (weak), — оранжевым кружком
struct PlanWalls: View {
    let points: [SIMD2<Double>]
    let lines: [SIMD4<Double>]
    let weak: Set<Int>

    var body: some View {
        GeometryReader { geo in
            if let f = planFrame(points, in: CGRect(origin: .zero, size: geo.size)) {
                let map = { (x: Double, y: Double) in CGPoint(x: f.ox + CGFloat(x) * f.k, y: f.oy + CGFloat(y) * f.k) }
                let center = map(points.map(\.x).reduce(0, +) / Double(max(points.count, 1)),
                                 points.map(\.y).reduce(0, +) / Double(max(points.count, 1)))
                ForEach(Array(lines.indices), id: \.self) { i in
                    let m = map((lines[i].x + lines[i].z) / 2, (lines[i].y + lines[i].w) / 2)
                    let d = max(hypot(center.x - m.x, center.y - m.y), 1)
                    Text("\(i + 1)")
                        .font(.caption2.bold())
                        .frame(width: 18, height: 18)
                        .background(weak.contains(i) ? Color.orange : Color(.systemGray3), in: Circle())
                        .foregroundStyle(Color.white)
                        .position(x: m.x + (center.x - m.x) / d * 16, y: m.y + (center.y - m.y) / d * 16)
                }
            }
        }
    }
}

/// Масштаб и сдвиг, которыми план вписывается в рамку
func planFrame(_ points: [SIMD2<Double>], in rect: CGRect) -> (k: CGFloat, ox: CGFloat, oy: CGFloat)? {
    guard let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max(), maxX > 0, maxY > 0 else { return nil }
    let k = min(rect.width / CGFloat(maxX), rect.height / CGFloat(maxY))
    let ox = rect.minX + (rect.width - CGFloat(maxX) * k) / 2
    let oy = rect.minY + (rect.height - CGFloat(maxY) * k) / 2
    return (k, ox, oy)
}

func fit(_ points: [SIMD2<Double>], in rect: CGRect) -> [CGPoint] {
    guard let f = planFrame(points, in: rect) else { return [] }
    return points.map { CGPoint(x: f.ox + CGFloat($0.x) * f.k, y: f.oy + CGFloat($0.y) * f.k) }
}
