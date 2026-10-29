import SwiftUI

/// Apartment-level organizer built on the existing flat and per-room scan IDs.
/// Does not merge geometric coordinates or silently add quantities from incompatible units.
struct ApartmentProjectView: View {
    @EnvironmentObject private var store: ScanStore
    let flatID: UUID
    @StateObject private var project: WorkProjectStore
    @State private var newTask = ""

    init(flatID: UUID, name: String) {
        self.flatID = flatID
        _project = StateObject(wrappedValue: WorkProjectStore(id: flatID, name: name))
    }

    private var flat: SavedFlat? { store.flat(flatID) }
    private var rooms: [(SavedScan, RoomResult)] {
        guard let flat else { return [] }
        return flat.rooms.compactMap { id in
            guard let scan = store.scan(id), let result = store.result(id) else { return nil }
            return (scan, result)
        }
    }
    private var totalFloor: Double { rooms.reduce(0) { $0 + $1.1.floorArea } }
    private var totalWalls: Double { rooms.reduce(0) { $0 + $1.1.wallArea } }

    private var report: String {
        var lines = ["СТРОЙСКАН · ПРОЕКТ КВАРТИРЫ",
                     flat?.name ?? project.document.title,
                     "Комнат: \(rooms.count)",
                     "Общая площадь пола: \(String(format: "%.1f", totalFloor)) м²",
                     "Суммарная площадь стен: \(String(format: "%.1f", totalWalls)) м²",
                     "", "КОМНАТЫ:"]
        lines += rooms.map { "\( $0.0.room ): пол \(String(format: "%.1f", $0.1.floorArea)) м², стены \(String(format: "%.1f", $0.1.wallArea)) м²" }
        lines += ["", "ЗАДАЧИ ПО КВАРТИРЕ:"]
        lines += project.document.jobs.map { "\($0.status.rawValue): \($0.title)" }
        lines += ["", "Примечания:", project.document.notes,
                  "", "Материалы и проекты каждой комнаты ведутся отдельно. Это сводный рабочий отчёт, а не смета поставщика."]
        return lines.joined(separator: "\n")
    }

    var body: some View {
        List {
            Section("Вся квартира") {
                Text(flat?.name ?? "Квартира").font(.title2.bold())
                LabeledContent("Комнат", value: "\(rooms.count)")
                LabeledContent("Площадь пола", value: String(format: "%.1f м²", totalFloor))
                LabeledContent("Площадь стен", value: String(format: "%.1f м²", totalWalls))
                Text("Сквозная сумма измеренных площадей. Если комнаты перекрываются или в скане ошибочно распознаны стены, проверь размеры.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Комнаты и работы") {
                ForEach(rooms, id: \.0.id) { scan, room in
                    NavigationLink {
                        WorkProjectView(id: scan.id, result: room)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(scan.room).font(.headline)
                            Text(String(format: "Пол %.1f м² · стены %.1f м²", room.floorArea, room.wallArea))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Общие задачи квартиры") {
                HStack {
                    TextField("Добавить задачу", text: $newTask)
                    Button {
                        let title = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        project.edit { $0.jobs.append(.init(title: title)) }
                        newTask = ""
                    } label: { Image(systemName: "plus.circle.fill") }
                    .disabled(newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(project.document.jobs) { job in
                    Menu {
                        ForEach(WorkProject.TaskStatus.allCases) { status in
                            Button(status.rawValue) {
                                project.edit { data in
                                    if let i = data.jobs.firstIndex(where: { $0.id == job.id }) {
                                        data.jobs[i].status = status
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: job.status == .done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(job.status == .done ? .green : Palette.signal)
                            Text(job.title).foregroundStyle(.primary)
                            Spacer()
                            Text(job.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexes in project.edit { $0.jobs.remove(atOffsets: indexes) } }
            }
            Section("Общая закупка") {
                NavigationLink {
                    PetrovichPurchaseView()
                } label: {
                    Label("Калькулятор для Петровича", systemImage: "cart")
                }
                Text("Для точного объединения закупок каждой комнаты необходима проверка спецификаций и единиц измерения. Пока считай по комнатам, сводный калькулятор заполни вручную.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Заметки и отчёт") {
                TextEditor(text: Binding(
                    get: { project.document.notes },
                    set: { text in project.edit { $0.notes = String(text.prefix(4000)) } }
                )).frame(minHeight: 90)
                ShareLink(item: report) { Label("Поделиться отчётом по квартире", systemImage: "square.and.arrow.up") }
            }
        }
        .navigationTitle("Проект квартиры")
        .alert("Ошибка сохранения", isPresented: Binding(
            get: { project.problem != nil },
            set: { if !$0 { project.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(project.problem ?? "") }
    }
}
