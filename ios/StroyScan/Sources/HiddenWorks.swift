import PhotosUI
import SwiftUI

/// Evidence captured before covering cables, pipes, waterproofing and studs.
/// Files stay in the device's StroyScan folder, included in regular ZIP backups.
struct HiddenWorkPhoto: Codable, Identifiable {
    let id: UUID
    let created: Date
    let trade: String
    let note: String
    var filename: String { id.uuidString + ".jpg" }
}

@MainActor
final class HiddenWorkStore: ObservableObject {
    @Published private(set) var photos: [HiddenWorkPhoto] = []
    @Published var error: String?
    private let directory: URL
    private let index: URL

    init(scanID: UUID) {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StroyScan/HiddenWorks", isDirectory: true)
        directory = root.appendingPathComponent(scanID.uuidString, isDirectory: true)
        index = directory.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: index),
           let list = try? JSONDecoder().decode([HiddenWorkPhoto].self, from: data) {
            photos = list
        }
    }

    func imageURL(_ photo: HiddenWorkPhoto) -> URL {
        directory.appendingPathComponent(photo.filename)
    }

    func add(_ jpeg: Data, trade: String, note: String) {
        let record = HiddenWorkPhoto(id: UUID(), created: Date(), trade: trade,
                                     note: String(note.prefix(800)))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: imageURL(record), options: .atomic)
            photos.insert(record, at: 0)
            try persist()
        } catch {
            photos.removeAll { $0.id == record.id }
            try? FileManager.default.removeItem(at: imageURL(record))
            self.error = "Фото не сохранилось: \(error.localizedDescription)"
        }
    }

    func remove(_ photo: HiddenWorkPhoto) {
        let old = photos
        photos.removeAll { $0.id == photo.id }
        do {
            try persist()
            try? FileManager.default.removeItem(at: imageURL(photo))
        } catch {
            photos = old
            self.error = "Не удалось удалить запись: \(error.localizedDescription)"
        }
    }

    private func persist() throws {
        try JSONEncoder().encode(photos).write(to: index, options: .atomic)
        // The existing backup scheduler checks this counter.
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "store.changes") + 1, forKey: "store.changes")
    }
}

struct HiddenWorksView: View {
    let scanID: UUID
    @StateObject private var store: HiddenWorkStore
    @State private var picked: PhotosPickerItem?
    @State private var trade = "ГКЛ и каркас"
    @State private var note = ""
    @State private var saving = false
    @State private var preview: HiddenWorkPhoto?

    private let trades = ["ГКЛ и каркас", "Электрика", "Сантехника",
                          "Гидроизоляция", "Тёплый пол", "Отделка", "Другое"]

    init(scanID: UUID) {
        self.scanID = scanID
        _store = StateObject(wrappedValue: HiddenWorkStore(scanID: scanID))
    }

    var body: some View {
        List {
            Section {
                Text("Фотографируй то, что скоро закроют ГКЛ, плиткой или стяжкой: расположение труб, кабелей, креплений и узлов. Фото привязаны к этой комнате.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Вид работы", selection: $trade) {
                    ForEach(trades, id: \.self) { Text($0) }
                }
                TextField("Место и пояснение, например: стена 2, кабель на высоте 30 см", text: $note,
                          axis: .vertical)
                    .lineLimit(2...4)
                PhotosPicker(selection: $picked, matching: .images) {
                    Label(saving ? "Сохраняю…" : "Добавить фото скрытых работ", systemImage: "camera.fill")
                }
                .disabled(saving)
                Text("Перед началом следующего этапа проверь комплектность фотографий. Они не заменяют исполнительную документацию и контроль специалиста.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("История фото · \(store.photos.count)") {
                if store.photos.isEmpty {
                    Text("Пока нет фотографий").foregroundStyle(.secondary)
                }
                ForEach(store.photos) { photo in
                    HStack(alignment: .top, spacing: 12) {
                        if let image = UIImage(contentsOfFile: store.imageURL(photo).path) {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 9))
                        } else {
                            Image(systemName: "photo").frame(width: 76, height: 76)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(photo.trade).font(.subheadline.bold())
                            Text(photo.note.isEmpty ? "Без пояснения" : photo.note)
                                .font(.caption)
                            Text(photo.created, style: .date).font(.caption2).foregroundStyle(.secondary)
                            ShareLink(item: store.imageURL(photo)) {
                                Label("Поделиться", systemImage: "square.and.arrow.up").font(.caption)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) { store.remove(photo) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Скрытые работы")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: picked) { item in
            guard let item else { return }
            saving = true
            Task {
                defer { saving = false; picked = nil }
                do {
                    guard let bytes = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: bytes),
                          let jpeg = image.jpegData(compressionQuality: 0.82) else {
                        store.error = "Не удалось прочитать фото. Выберите другое изображение."
                        return
                    }
                    store.add(jpeg, trade: trade, note: note)
                    note = ""
                } catch {
                    store.error = "Не удалось загрузить изображение: \(error.localizedDescription)"
                }
            }
        }
        .alert("Ошибка фото", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.error ?? "") }
    }
}
