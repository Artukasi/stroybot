import SwiftUI
import UIKit

// MARK: - Окна и двери на заказ

/// Размеры проёмов из скана и ориентир, что заказывать. Финальный замер всё равно делает замерщик
enum OrderSizes {
    struct Line: Identifiable {
        let id: Int
        /// «Окно 1», «Дверь 2», «Проём 1»
        let title: String
        let kind: String
        let wall: Int?
        /// Проём в миллиметрах
        let width: Int
        let height: Int
        /// Низ проёма от пола, мм (подоконник у окна)
        let bottom: Int
        /// Что заказывать — коротко
        let order: String
        /// Пояснение
        let note: String
    }

    static let doorLeaves = [600, 700, 800, 900]

    static func lines(_ r: RoomResult) -> [Line] {
        var counts: [String: Int] = [:]
        return r.openings.enumerated().map { i, o in
            let kind = o.kind == "window" ? "window" : o.kind == "door" ? "door" : "opening"
            counts[kind, default: 0] += 1
            let n = counts[kind] ?? 1
            let w = Int((o.width * 1000).rounded()), h = Int((o.height * 1000).rounded())
            let b = Int(((o.bottom ?? 0) * 1000).rounded())
            let (order, note) = advice(kind: kind, w: w, h: h)
            let title = (kind == "window" ? "Окно" : kind == "door" ? "Дверь" : "Проём") + " \(n)"
            return Line(id: i, title: title, kind: kind, wall: o.wall, width: w, height: h, bottom: b, order: order, note: note)
        }
    }

    /// Вниз до 10 мм
    private static func down10(_ v: Int) -> Int { v / 10 * 10 }

    static func advice(kind: String, w: Int, h: Int) -> (String, String) {
        switch kind {
        case "window":
            // монтажный шов по 20 мм с боков и сверху, снизу ещё 30 мм под подставочный профиль
            let ow = down10(w - 40), oh = down10(h - 50)
            return ("Окно \(ow) × \(oh) мм",
                    "Проём без четверти: −40 мм по ширине (шов 20 мм с каждой стороны) и −50 мм по высоте (шов и подставочный профиль). Если в проёме есть четверть — размер считает замерщик.")
        case "door":
            // полотно + коробка и зазоры ≈ 70–100 мм по ширине, 60–100 мм по высоте
            guard let leaf = doorLeaves.last(where: { $0 + 70 <= w }) else {
                return ("Нестандарт", "Проём уже 670 мм — стандартное полотно 600 не встанет, нужна дверь под заказ или расширение проёма.")
            }
            let leafH = h >= 2060 ? 2000 : h >= 1960 ? 1900 : 0
            if leafH == 0 {
                return ("Полотно \(leaf) мм, высота под заказ", "Проём ниже 1960 мм — стандартные 1900/2000 не встанут. Поднять проём или заказать нестандарт.")
            }
            let spare = w - (leaf + 100)
            let extra = spare > 30 ? " Проём шире нужного на \(spare) мм — зазор запенят и закроют наличником." : ""
            return ("Полотно \(leaf) × \(leafH) мм",
                    "Под полотно \(leaf) мм нужен проём \(leaf + 70)–\(leaf + 100) мм с коробкой и зазорами.\(extra) Доборы — по толщине стены.")
        default:
            return ("Арка или портал \(w) × \(h) мм", "Проём без двери: портал или арку заказывают по размеру проёма и толщине стены.")
        }
    }

    /// Текстом — отправить в мессенджер оконщику или замерщику
    static func text(_ r: RoomResult) -> String {
        var s = "Окна и двери — \(r.room)\nРазмеры из скана лидаром iPhone, точность ±1–2 см. Перед заказом — замер рулеткой.\n"
        for l in lines(r) {
            s += "\n\(l.title)" + (l.wall.map { ", стена \($0 + 1)" } ?? "")
            s += "\nПроём: \(l.width) × \(l.height) мм"
            if l.kind == "window" { s += ", низ от пола \(l.bottom) мм" }
            s += "\nЗаказ (ориентир): \(l.order)\n"
        }
        return s
    }
}

struct OpeningsView: View {
    let result: RoomResult
    @State private var share: ShareFile?
    @State private var copied = false
    @State private var note: String?

    var body: some View {
        let lines = OrderSizes.lines(result)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if lines.isEmpty {
                    Text("Сканер не нашёл в этой комнате окон и дверей. Доснимите их — медленно проведите телефоном по проёму.")
                        .foregroundStyle(.secondary)
                }
                ForEach(lines) { card($0) }
                if !lines.isEmpty {
                    Button { form() } label: {
                        Label("Бланк для замерщика (PDF)", systemImage: "doc.richtext")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Palette.ink)
                    }
                    Button {
                        UIPasteboard.general.string = OrderSizes.text(result)
                        copied = true
                    } label: {
                        Label(copied ? "Скопировано" : "Скопировать размеры текстом", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Palette.ink)
                    }
                    if let note { Text(note).font(.footnote).foregroundStyle(.red) }
                    Text("Размеры сняты лидаром, точность ±1–2 см. Это ориентир, чтобы прикинуть цену и выбрать окна и двери. Заказывать — после замера рулеткой: ширину в трёх местах (верх, середина, низ), высоту в трёх местах, берут меньшее.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Окна и двери")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
    }

    private func card(_ l: OrderSizes.Line) -> some View {
        HStack(alignment: .top, spacing: 14) {
            sketch(l).frame(width: 74, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(l.title).font(.headline)
                    if let w = l.wall { Text("стена \(w + 1)").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Проём \(l.width) × \(l.height) мм").font(.subheadline.monospacedDigit())
                if l.kind == "window" {
                    Text("Низ от пола \(l.bottom) мм").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(l.order).font(.subheadline.bold()).foregroundStyle(Palette.draft)
                Text(l.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    /// Проём в масштабе на стене высотой 2,7 м
    private func sketch(_ l: OrderSizes.Line) -> some View {
        Canvas { ctx, size in
            let k = size.height / 2700
            let w = min(CGFloat(l.width) * k, size.width - 6), h = CGFloat(l.height) * k
            let rect = CGRect(x: (size.width - w) / 2, y: size.height - CGFloat(l.bottom) * k - h, width: w, height: h)
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color(.tertiarySystemFill)))
            ctx.fill(Path(rect), with: .color(l.kind == "window" ? Color.cyan.opacity(0.35) : Color.brown.opacity(0.35)))
            ctx.stroke(Path(rect), with: .color(Palette.ink), lineWidth: 1.5)
        }
    }

    private func form() {
        if let url = PlanPDF.openingsForm(result) {
            share = ShareFile(url: url)
        } else {
            note = "Не получилось собрать PDF."
        }
    }
}
