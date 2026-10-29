import SwiftUI

/// Единый рабочий маршрут: скан -> задачи -> смета -> закупки -> выполнение -> отчёт.
/// Хранится отдельно от сканов, поэтому не меняет и не удаляет старые RoomResult.
enum WorkProject {
    enum Phase: String, CaseIterable, Codable, Identifiable {
        case survey = "Замеры и обследование"
        case design = "Планирование и 3D"
        case estimate = "Материалы и смета"
        case purchase = "Закупка"
        case build = "Выполнение работ"
        case finish = "Приёмка и отчёт"
        var id: String { rawValue }
        var tip: String {
            switch self {
            case .survey: return "Проверь размеры, основание и скрытые инженерные сети."
            case .design: return "Разметь каркас ГКЛ, инженерные точки и трассы."
            case .estimate: return "Проверь объёмы, упаковки, запас и цены по документам производителя."
            case .purchase: return "Отмечай, какие материалы уже куплены."
            case .build: return "Веди задачи и фиксируй выполнение."
            case .finish: return "Проверь качество и передай отчёт клиенту."
            }
        }
    }
    enum TaskStatus: String, Codable, CaseIterable, Identifiable {
        case todo = "Не начато"
        case active = "В работе"
        case done = "Готово"
        var id: String { rawValue }
    }
    struct Job: Identifiable, Codable {
        var id = UUID()
        var title: String
        var status: TaskStatus = .todo
        var notes: String = ""
        var phase: Phase = .build
    }
    struct Purchase: Identifiable, Codable {
        var id = UUID()
        var title: String
        var quantity: String
        var bought = false
        var notes = ""
    }
    struct Data: Codable {
        var title: String = ""
        var client: String = ""
        var jobs: [Job] = []
        var shopping: [Purchase] = []
        var checked: Set<String> = []
        var notes: String = ""
        var updated: Date = Date()
    }
    static let defaults = ["Подготовка основания", "Электрика и сантехника (по проекту)",
                           "ГКЛ / каркас и обшивка", "Штукатурка и шпаклёвка",
                           "Гидроизоляция и плитка", "Окраска / напольное покрытие", "Финальная приёмка"]
    static func make(_ name: String) -> Data {
        Data(title: name, jobs: defaults.map { Job(title: $0) })
    }
}

/// Документ проекта — один JSON для каждого UUID существующего скана.
/// Сохранение атомарное, ошибки не замалчиваются.
@MainActor
final class WorkProjectStore: ObservableObject {
    @Published var document: WorkProject.Data
    @Published var problem: String?
    private let url: URL

    init(id: UUID, name: String) {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StroyScan/Projects", isDirectory: true)
        url = root.appendingPathComponent(id.uuidString + ".json")
        if let input = try? Foundation.Data(contentsOf: url),
           let restored = try? JSONDecoder().decode(WorkProject.Data.self, from: input) {
            document = restored
        } else {
            document = WorkProject.make(name)
        }
    }

    func edit(_ block: (inout WorkProject.Data) -> Void) {
        block(&document)
        document.updated = Date()
        save()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
            // Trigger existing backup scheduler even if no room scan was edited.
            let defaults = UserDefaults.standard
            defaults.set(defaults.integer(forKey: "store.changes") + 1, forKey: "store.changes")
            problem = nil
        } catch {
            problem = "Не удалось сохранить проект: \(error.localizedDescription)"
        }
    }
}

struct WorkProjectView: View {
    @StateObject private var model: WorkProjectStore
    let result: RoomResult
    let scanID: UUID
    @State private var newJob = ""
    @State private var newMaterial = ""
    @State private var newAmount = ""
    @State private var stage: WorkProject.Phase = .survey
    @State private var showingInfo = false

    init(id: UUID, result: RoomResult) {
        scanID = id
        self.result = result
        _model = StateObject(wrappedValue: WorkProjectStore(id: id, name: result.room))
    }

    private var done: Int { model.document.jobs.filter { $0.status == .done }.count }
    private var estimated: [Estimate.Row] { Estimate.rows(for: result).filter { $0.section == .materials && Estimate.isOn($0) } }
    private var report: String {
        let d = model.document
        var text = ["СТРОЙСКАН · ПРОЕКТ РЕМОНТА", d.title, "Клиент: \(d.client)",
                    "Помещение: \(result.room)", "Пол: \(fmt(result.floorArea)) м², стены: \(fmt(result.wallArea)) м²",
                    "Выполнено: \(done) из \(d.jobs.count)", "", "ЗАДАЧИ:"]
        text += d.jobs.map { "• \($0.title) — \($0.status.rawValue) \( $0.notes.isEmpty ? "" : "(\($0.notes))" )" }
        text += ["", "ЗАКУПКИ:"]
        text += d.shopping.map { "• \($0.bought ? "КУПЛЕНО" : "НУЖНО"): \($0.title) — \($0.quantity)" }
        text += ["", "ЗАМЕТКИ:", d.notes, "", "Это рабочий отчёт, не проект электрики, сантехники или несущих конструкций."]
        return text.joined(separator: "\n")
    }
    private func fmt(_ x: Double) -> String { String(format: "%.1f", x) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.document.title.isEmpty ? result.room : model.document.title).font(.title2.bold())
                    Text("Пол: \(fmt(result.floorArea)) м² · стены: \(fmt(result.wallArea)) м² · высота: \(fmt(result.height)) м")
                        .font(.footnote).foregroundStyle(.secondary)
                    ProgressView(value: Double(done), total: Double(max(1, model.document.jobs.count)))
                        .tint(Palette.signal)
                    Text("Выполнено: \(done) из \(model.document.jobs.count) задач")
                        .font(.caption)
                }
            } header: { Text("Объект") }

            Section("Информация для заказчика") {
                TextField("Название объекта", text: Binding(
                    get: { model.document.title },
                    set: { new in model.edit { $0.title = String(new.prefix(120)) } }
                ))
                TextField("Клиент / контакт", text: Binding(
                    get: { model.document.client },
                    set: { new in model.edit { $0.client = String(new.prefix(120)) } }
                ))
            }

            Section("Этапы проекта") {
                ForEach(WorkProject.Phase.allCases) { phase in
                    Button {
                        stage = phase
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: stage == phase ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(stage == phase ? Palette.signal : .secondary)
                            Text(phase.rawValue).foregroundStyle(.primary)
                            Spacer()
                            if model.document.checked.contains(phase.id) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            }
                        }
                    }
                }
            }

            Section(stage.rawValue) {
                Text(stage.tip).font(.subheadline).foregroundStyle(.secondary)
                if stage == .survey {
                    LabeledContent("Площадь пола", value: "\(fmt(result.floorArea)) м²")
                    LabeledContent("Площадь стен", value: "\(fmt(result.wallArea)) м²")
                    LabeledContent("Дверей", value: "\(result.doors)")
                    LabeledContent("Окон", value: "\(result.windows)")
                    Text("Перед закупкой уточните состояние основания, толщины слоёв и скрытые сети.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if stage == .design {
                    Label("3D-каркас ГКЛ, трубы и кабели доступны в карточке комнаты. После правок вернитесь сюда.", systemImage: "cube.transparent")
                    NavigationLink {
                        GKLFrameView(result: result)
                    } label: { Label("Каркас гипсокартона 3D", systemImage: "square.grid.3x3") }
                    NavigationLink {
                        DraftRouteView(room: result, engineering: .constant(result.engineering))
                    } label: { Label("Просмотр черновых трасс (без сохранения)", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                    Text("Для сохранения трасс откройте инженерный редактор из карточки комнаты.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if stage == .estimate {
                    NavigationLink {
                        PetrovichPurchaseView(room: result) { chosen in
                            model.edit { data in
                                for item in chosen {
                                    let key = "petrovich:" + item.id
                                    let qty = "\(item.packages) \(item.package)"
                                    if let index = data.shopping.firstIndex(where: { $0.notes == key }) {
                                        data.shopping[index].quantity = qty
                                    } else {
                                        data.shopping.append(.init(title: item.name, quantity: qty,
                                                                   notes: key))
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Сформировать закупку для Петровича", systemImage: "cart.fill")
                    }
                    NavigationLink {
                        EstimateView(result: result)
                    } label: { Label("Открыть полную смету", systemImage: "rublesign.circle") }
                    NavigationLink {
                        ForemanGuideView(initialFloorArea: result.floorArea, initialWallArea: result.wallArea)
                    } label: { Label("Пошаговый помощник по работам", systemImage: "hammer") }
                    Text("Ниже — только материалы из типовой сметы. Состав и расход уточняйте по фактической технологии.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(estimated) { row in
                        HStack {
                            Text(row.title).font(.subheadline)
                            Spacer()
                            Text("\(Estimate.qty(row.qty, row.unit)) \(row.unit)").font(.caption)
                            PetrovichMaterialLink(name: row.title)
                        }
                    }
                    Button("Перенести материалы в закупки") {
                        model.edit { data in
                            for row in estimated where !data.shopping.contains(where: { $0.notes == row.id }) {
                                data.shopping.append(.init(title: row.title,
                                                            quantity: "\(Estimate.qty(row.qty, row.unit)) \(row.unit)",
                                                            notes: row.id))
                            }
                        }
                    }
                }
                if stage == .purchase {
                    HStack {
                        TextField("Материал", text: $newMaterial)
                        TextField("Кол-во", text: $newAmount).frame(maxWidth: 85)
                        Button {
                            let name = newMaterial.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            model.edit { $0.shopping.append(.init(title: name, quantity: newAmount)) }
                            newMaterial = ""; newAmount = ""
                        } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(newMaterial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(model.document.shopping) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                model.edit { data in
                                    if let i = data.shopping.firstIndex(where: { $0.id == entry.id }) {
                                        data.shopping[i].bought.toggle()
                                    }
                                }
                            } label: {
                                Image(systemName: entry.bought ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(entry.bought ? .green : Palette.signal)
                            }
                            .buttonStyle(.borderless)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).foregroundStyle(.primary)
                                Text(entry.quantity).font(.caption).foregroundStyle(.secondary)
                                PetrovichMaterialLink(name: entry.title)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        model.edit { data in data.shopping.remove(atOffsets: offsets) }
                    }
                }
                if stage == .build {
                    HStack {
                        TextField("Добавить работу", text: $newJob)
                        Button {
                            let name = newJob.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            model.edit { $0.jobs.append(.init(title: name)) }
                            newJob = ""
                        } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(newJob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(model.document.jobs) { job in
                        Menu {
                            ForEach(WorkProject.TaskStatus.allCases) { status in
                                Button(status.rawValue) {
                                    model.edit { data in
                                        if let i = data.jobs.firstIndex(where: { $0.id == job.id }) { data.jobs[i].status = status }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: job.status == .done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(job.status == .done ? .green : Palette.signal)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.title).foregroundStyle(.primary)
                                    Text(job.status.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }
                        }
                    }.onDelete { offsets in model.edit { $0.jobs.remove(atOffsets: offsets) } }
                }
                if stage == .finish {
                    NavigationLink {
                        HiddenWorksView(scanID: scanID)
                    } label: {
                        Label("Фото скрытых работ и узлов", systemImage: "camera")
                    }
                    Text("Отметьте проверку качества, фото скрытых работ и передачу документов перед закрытием объекта.")
                        .font(.subheadline)
                    ShareLink(item: report) { Label("Отправить отчёт клиенту", systemImage: "square.and.arrow.up") }
                    Button("Скопировать отчёт") {
                        UIPasteboard.general.string = report
                        showingInfo = true
                    }
                }
                Button {
                    model.edit { data in
                        if data.checked.contains(stage.id) { data.checked.remove(stage.id) }
                        else { data.checked.insert(stage.id) }
                    }
                } label: {
                    Label(model.document.checked.contains(stage.id) ? "Этап отмечен выполненным" : "Отметить этап выполненным",
                          systemImage: model.document.checked.contains(stage.id) ? "checkmark.circle.fill" : "circle")
                }
            }
            Section("Заметки по объекту") {
                TextEditor(text: Binding(
                    get: { model.document.notes },
                    set: { new in model.edit { $0.notes = String(new.prefix(4000)) } }
                )).frame(minHeight: 80)
            }
            Section {
                ShareLink(item: report) {
                    Label("Поделиться всем проектом", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Проект ремонта")
        .navigationBarTitleDisplayMode(.inline)
        .alert("СтройСкан", isPresented: $showingInfo) {
            Button("OK", role: .cancel) {}
        } message: { Text("Отчёт скопирован") }
        .alert("Ошибка сохранения", isPresented: Binding(
            get: { model.problem != nil },
            set: { if !$0 { model.problem = nil } }
        )) {
            Button("OK", role: .cancel) { model.problem = nil }
        } message: { Text(model.problem ?? "") }
    }
}

/// Проекты существующих комнат, без дублирования сканов.
struct WorkProjectsHubView: View {
    @EnvironmentObject var store: ScanStore
    var body: some View {
        List {
            Section {
                Text("Выбери отсканированную комнату. Её размеры попадут в рабочий проект; задачи и закупки будут храниться отдельно.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Квартиры") {
                ForEach(store.flats) { flat in
                    NavigationLink {
                        ApartmentProjectView(flatID: flat.id, name: flat.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(flat.name).font(.headline)
                            Text("\(flat.rooms.count) комнат · общий рабочий проект")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Комнаты") {
                if store.scans.isEmpty {
                    Text("Пока нет сканов. На главном экране нажми «Сканировать комнату».")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.scans) { entry in
                    if let result = store.result(entry.id) {
                        NavigationLink {
                            WorkProjectView(id: entry.id, result: result)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.room).font(.headline)
                                Text("\(String(format: "%.1f", entry.floorArea)) м² · \(entry.place ?? "Без адреса")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Проекты ремонта")
    }
}
