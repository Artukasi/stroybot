import SwiftUI

/// Вещь, подобранная ботом по размерам скана, и ссылки на поиск в магазинах
struct FurnitureOffer: Identifiable {
    struct Shop: Identifiable {
        let id: String
        let url: URL
    }

    let id: Int
    let title: String
    /// Размер сейчас: «200 × 90 × 85 см»
    let now: String?
    /// Сколько места есть: «240 × 100 см»
    let limit: String?
    let note: String
    let shops: [Shop]

    init?(_ d: [String: Any], id: Int) {
        guard let title = d["title"] as? String else { return nil }
        self.id = id
        self.title = title
        let cm = { (v: Any?) -> Int? in (v as? NSNumber)?.intValue }
        let size = d["size"] as? [String: Any] ?? [:]
        if let w = cm(size["width"]), let dp = cm(size["depth"]) {
            now = cm(size["height"]).map { "\(w) × \(dp) × \($0) см" } ?? "\(w) × \(dp) см"
        } else {
            now = nil
        }
        let top = d["max"] as? [String: Any] ?? [:]
        if let w = cm(top["width"]), let dp = cm(top["depth"]) {
            limit = "\(w) × \(dp) см"
        } else {
            limit = nil
        }
        note = d["note"] as? String ?? ""
        shops = (d["links"] as? [[String: Any]] ?? []).compactMap { l in
            guard let shop = l["shop"] as? String, let s = l["url"] as? String, let url = URL(string: s) else { return nil }
            return Shop(id: shop, url: url)
        }
    }
}

/// «Мебель по размерам»: что встанет в комнату и где это купить
struct FurnitureSizesView: View {
    @EnvironmentObject var link: BotLink
    /// Отправить скан в бот (true — заново) и вернуть его номер
    let ensureScanId: (Bool) async throws -> Int
    @State private var offers: [FurnitureOffer] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Сколько места у каждой вещи по скану и что встанет на свободные стены. Кнопки открывают поиск в магазине сразу с нужными размерами.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !link.connected {
                    Text("Подключите бота на главном экране: размеры считает СтройБот.")
                        .font(.headline)
                } else if loading {
                    ProgressView("Считаю, что встанет…")
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if let failure {
                    Text(failure).foregroundStyle(.red)
                    Button("Ещё раз") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                } else if loaded && offers.isEmpty {
                    Text("Свободного места под новую мебель не нашлось.")
                }
                ForEach(offers) { card($0) }
            }
            .padding()
        }
        .navigationTitle("Мебель по размерам")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load() } }
        .refreshable { await load() }
    }

    private func card(_ o: FurnitureOffer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(o.title).font(.headline)
            if let now = o.now { Text("Сейчас: \(now)").font(.subheadline) }
            if let limit = o.limit { Text("Встанет до: \(limit)").font(.subheadline.bold()) }
            if !o.note.isEmpty { Text(o.note).font(.footnote).foregroundStyle(.secondary) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(o.shops) { shop in
                        Link(destination: shop.url) {
                            Text(shop.id).font(.subheadline.bold())
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Palette.signal, in: Capsule())
                                .foregroundStyle(Palette.ink)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func load() async {
        guard link.connected else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let items: [[String: Any]]
            do {
                let id = try await ensureScanId(false)
                items = try await link.furniture(scanId: id)
            } catch LinkError.scanMissing {
                // скан удалили в боте — отправляем заново
                let id = try await ensureScanId(true)
                items = try await link.furniture(scanId: id)
            }
            offers = items.enumerated().compactMap { FurnitureOffer($0.element, id: $0.offset) }
            loaded = true
        } catch {
            failure = LinkError.describe(error)
        }
    }
}
