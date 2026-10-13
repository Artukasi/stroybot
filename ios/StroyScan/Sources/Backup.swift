import Compression
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Резервная копия в боте: все сканы, квартиры, прошлые съёмки, ремонт и электрика из 3D, логотип,
/// свои цены и данные бригады — одним zip. Если приложение удалили или переустановка сорвалась,
/// после подключения к боту всё возвращается одной кнопкой. 3D-модели Apple (USDZ) в копию не идут — они тяжёлые.
@MainActor
final class Backup: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var last: Date? = UserDefaults.standard.object(forKey: "backup.last") as? Date
    /// В боте есть копия, а в телефоне пусто — предлагаем восстановить
    @Published private(set) var offer: Date?
    @Published var message: String?

    nonisolated static let settingPrefixes = ["brand.", "price.", "on.", "place.list", "tile.", "lam."]

    /// Сохранить копию. auto — тихо, раз в 10 минут и только если что-то поменялось
    func save(_ store: ScanStore, _ link: BotLink, auto: Bool = false, throttle: Bool = true) async {
        guard link.connected, !busy else { return }
        let changes = store.changes
        if auto {
            guard UserDefaults.standard.integer(forKey: "backup.changes") != changes, !store.scans.isEmpty else { return }
            if throttle, let last, Date().timeIntervalSince(last) < 600 { return }
        }
        busy = true
        defer { busy = false }
        do {
            let root = store.folderURL
            let zip = try await Task.detached { try Self.pack(root) }.value
            try await link.uploadBackup(zip)
            let now = Date()
            last = now
            UserDefaults.standard.set(now, forKey: "backup.last")
            UserDefaults.standard.set(changes, forKey: "backup.changes")
            if !auto { message = "Копия сохранена в боте: \(fmtSize(zip.count))." }
        } catch {
            if !auto { message = LinkError.describe(error) }
        }
    }

    /// Пустой телефон после переустановки: есть ли копия в боте
    func check(_ store: ScanStore, _ link: BotLink) async {
        guard link.connected, store.scans.isEmpty, offer == nil else { return }
        offer = try? await link.backupInfo()
    }

    /// Вернуть из копии всё, чего нет в телефоне (то, что есть, не трогаем)
    func restore(_ store: ScanStore, _ link: BotLink) async {
        guard link.connected, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let zip = try await link.downloadBackup()
            try await apply(zip, store, from: "в боте")
        } catch {
            message = LinkError.describe(error)
        }
    }

    /// Копия в файл — для «Файлов», iCloud Drive, Telegram или почты. Бот не нужен
    func exportFile(_ store: ScanStore) async -> URL? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let root = store.folderURL
            let zip = try await Task.detached { try Self.pack(root) }.value
            let day = Date().formatted(.iso8601.year().month().day())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("СтройСкан-копия-\(day).zip")
            try zip.write(to: url, options: .atomic)
            let now = Date()
            last = now
            UserDefaults.standard.set(now, forKey: "backup.last")
            return url
        } catch {
            message = "Не получилось собрать копию: \(error.localizedDescription)"
            return nil
        }
    }

    /// Вернуть из файла копии (zip), выбранного в «Файлах»
    func restoreFile(_ url: URL, _ store: ScanStore) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let zip = try Data(contentsOf: url)
            try await apply(zip, store, from: "в файле")
        } catch {
            message = "Это не похоже на копию СтройСкана: \(error.localizedDescription)"
        }
    }

    private func apply(_ zip: Data, _ store: ScanStore, from place: String) async throws {
        let (tmp, dir) = try await Task.detached { try Self.unpack(zip) }.value
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let added = store.importBackup(from: dir) else {
            message = "Копия \(place) повреждена, восстановить не получилось."
            return
        }
        Self.restoreSettings(from: dir, root: store.folderURL)
        offer = nil
        message = added.rooms == 0
            ? "Всё из копии уже есть в телефоне."
            : "Вернули комнат: \(added.rooms)" + (added.flats > 0 ? ", квартир: \(added.flats)." : ".")
    }

    // MARK: - Упаковка

    /// Копия папки без USDZ + настройки → zip (системным упаковщиком iOS)
    nonisolated static func pack(_ root: URL) throws -> Data {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        let copy = stage.appendingPathComponent("StroyScan", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        let items = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = items?.nextObject() as? URL {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let target = copy.appendingPathComponent(rel)
            if isDir {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if url.pathExtension.lowercased() != "usdz" {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: target)
            }
        }
        var settings: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where settingPrefixes.contains(where: { k.hasPrefix($0) }) {
            if v is String || v is NSNumber || v is [String] { settings[k] = v }
        }
        let json = try JSONSerialization.data(withJSONObject: settings)
        try json.write(to: copy.appendingPathComponent("settings.json"))

        var zip: Data?
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: copy, options: .forUploading, error: &coordError) { url in
            do { zip = try Data(contentsOf: url) } catch { failure = error }
        }
        if let failure { throw failure }
        if let coordError { throw coordError }
        guard let zip else { throw LinkError.message("Не получилось упаковать копию.") }
        return zip
    }

    /// zip → временная папка (root — удалить после), dir — папка, где лежит index.json
    nonisolated static func unpack(_ zip: Data) throws -> (root: URL, dir: URL) {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try ZipReader.extract(zip, to: out)
        if fm.fileExists(atPath: out.appendingPathComponent("index.json").path) { return (out, out) }
        let dirs = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard let dir = dirs.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("index.json").path) }) else {
            try? fm.removeItem(at: out)
            throw LinkError.message("В копии нет списка сканов.")
        }
        return (out, dir)
    }

    /// Свои цены и бригада — только то, чего в телефоне ещё нет; логотип — если его нет
    private static func restoreSettings(from dir: URL, root: URL) {
        let d = UserDefaults.standard
        if let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (k, v) in json where settingPrefixes.contains(where: { k.hasPrefix($0) }) && d.object(forKey: k) == nil {
                d.set(v, forKey: k)
            }
        }
        let logo = dir.appendingPathComponent("logo.png"), mine = root.appendingPathComponent("logo.png")
        if !FileManager.default.fileExists(atPath: mine.path), FileManager.default.fileExists(atPath: logo.path) {
            try? FileManager.default.copyItem(at: logo, to: mine)
        }
    }

    private func fmtSize(_ bytes: Int) -> String {
        bytes < 1_000_000 ? "\(max(1, bytes / 1000)) КБ" : "\(fmt((Double(bytes) / 100_000).rounded() / 10)) МБ"
    }
}

/// Распаковка zip (без сжатия и deflate) — у iOS нет готовой. Читаем оглавление в конце файла
enum ZipReader {
    enum Failure: Error { case broken }

    static func extract(_ data: Data, to dir: URL) throws {
        let b = [UInt8](data)
        func u16(_ i: Int) throws -> Int {
            guard i >= 0, i + 2 <= b.count else { throw Failure.broken }
            return Int(b[i]) | Int(b[i + 1]) << 8
        }
        func u32(_ i: Int) throws -> Int {
            guard i >= 0, i + 4 <= b.count else { throw Failure.broken }
            return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        }
        // конец оглавления: подпись 50 4B 05 06 в последних 64 КБ
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65_535) {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.broken }
        let count = try u16(eocd + 10)
        var p = try u32(eocd + 16)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0..<count {
            guard try u32(p) == 0x0201_4B50 else { throw Failure.broken }
            let method = try u16(p + 10)
            let packed = try u32(p + 20), size = try u32(p + 24)
            let nameLen = try u16(p + 28), extra = try u16(p + 30), comment = try u16(p + 32)
            let local = try u32(p + 42)
            guard p + 46 + nameLen <= b.count else { throw Failure.broken }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extra + comment

            // защита: только пути внутри папки
            let parts = name.split(separator: "/").map(String.init)
            guard !name.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty, parts.first != "__MACOSX" else { continue }
            let target = parts.reduce(dir) { $0.appendingPathComponent($1) }
            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard try u32(local) == 0x0403_4B50 else { throw Failure.broken }
            let start = local + 30 + (try u16(local + 26)) + (try u16(local + 28))
            guard start + packed <= b.count, size <= 50_000_000 else { throw Failure.broken }
            let raw = Data(b[start..<(start + packed)])
            let file: Data
            switch method {
            case 0: file = raw
            case 8: file = try inflate(raw, size: size)
            default: throw Failure.broken
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.write(to: target)
        }
    }

    /// deflate без заголовка — это COMPRESSION_ZLIB у Apple
    private static func inflate(_ src: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw Failure.broken }
        return out
    }
}

/// Карточка на главном: резервная копия (в боте — сама, в файл — всегда)
struct BackupCard: View {
    @EnvironmentObject var store: ScanStore
    @EnvironmentObject var link: BotLink
    @EnvironmentObject var backup: Backup
    @State private var share: ShareFile?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if link.connected, let offer = backup.offer {
                Label("В боте есть копия ваших сканов", systemImage: "icloud.and.arrow.down").font(.headline)
                Text("Сохранена \(offer.formatted(date: .abbreviated, time: .shortened)). Вернуть комнаты, квартиры, ремонт из 3D и цены?")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { Task { await backup.restore(store, link) } } label: {
                    Group {
                        if backup.busy { ProgressView() } else { Label("Восстановить", systemImage: "arrow.down.circle.fill") }
                    }
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Palette.ink)
                }
                .disabled(backup.busy)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: backup.busy ? "arrow.triangle.2.circlepath" : "externaldrive.badge.checkmark")
                        .font(.title3).foregroundStyle(Palette.signal)
                        .rotationEffect(.degrees(backup.busy ? 360 : 0))
                        .animation(backup.busy ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: backup.busy)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Резервная копия").font(.subheadline.bold())
                        Text(backup.last.map { "сохранена \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "ещё не сохранялась")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button { Task { if let url = await backup.exportFile(store) { share = ShareFile(url: url) } } } label: {
                            Label("Сохранить в файл", systemImage: "square.and.arrow.up")
                        }
                        Button { importing = true } label: { Label("Вернуть из файла", systemImage: "folder") }
                        if link.connected {
                            Divider()
                            Button { Task { await backup.save(store, link) } } label: { Label("Сохранить в бот", systemImage: "arrow.up.circle") }
                            Button { Task { await backup.restore(store, link) } } label: { Label("Вернуть из бота", systemImage: "arrow.down.circle") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .disabled(backup.busy)
                }
                Text(link.connected
                     ? "В бот копия сохраняется сама. Ещё можно сохранить файл — в «Файлы», iCloud или Telegram."
                     : "Сохраните файл копии в «Файлы», iCloud или Telegram. Если приложение удалится, сканы вернутся из него.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .task { await backup.check(store, link) }
        .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { Task { await backup.restoreFile(url, store) } }
        }
    }
}
