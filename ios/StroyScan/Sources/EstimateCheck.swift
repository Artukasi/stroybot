import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Проверка сметы бригады

/// Смета бригады против скана: объёмы — по настоящим размерам комнаты, цены — по смете приложения (ваши цены)
enum EstimateCheck {
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let title: String
        let unit: String?
        let qty: Double?
        let price: Double?
        let sum: Double
    }

    struct Verdict: Identifiable {
        var id: UUID { line.id }
        let line: Line
        /// Строка сметы приложения, с которой сравнили
        let ours: Estimate.Row?
        let ourPrice: Double
        /// Объём больше, чем по скану: 0,25 = на 25%
        let qtyOver: Double?
        let priceOver: Double?
        /// Сколько можно сэкономить по этой строке, ₽
        let overpay: Double

        var flagged: Bool { (qtyOver ?? 0) > 0.15 || (priceOver ?? 0) > 0.3 }
    }

    // MARK: Разбор строк

    private static let units: [(String, String)] = [
        (#"(?:м2|м²|кв\.?\s*м\.?|м\.?\s*кв\.?)"#, "м²"),
        (#"(?:м\.?\s*п\.?|пог\.?\s*м\.?|п\.\s*м\.?|мп)"#, "м"),
        (#"(?:шт\.?|точ[а-я]*|ед\.?)"#, "шт"),
        (#"(?:меш[а-я]*)"#, "меш."),
        (#"(?:м\.?)"#, "м"),
    ]

    private static func regex(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    private static func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    /// Единица измерения из строки и строка без неё (иначе «м2» даёт лишнюю двойку)
    private static func cutUnit(_ line: String) -> (String, String?) {
        var s = line.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
        for (p, u) in units {
            guard let re = regex(#"(?<![а-яa-z])"# + p + #"(?![а-яa-z0-9])"#) else { continue }
            let ns = s as NSString
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                s = ns.replacingCharacters(in: m.range, with: " ")
                return (s, u)
            }
        }
        return (s, nil)
    }

    static func parse(_ raw: String) -> Line? {
        let (s, unit) = cutUnit(raw)
        guard let first = s.firstIndex(where: \.isNumber) else { return nil }
        let title = String(s[..<first]).trimmingCharacters(in: CharacterSet(charactersIn: " \t-—–:.,;×x*=№"))
        guard title.count >= 3, title.contains(where: \.isLetter) else { return nil }
        let rest = String(s[first...])
        let ns = rest as NSString
        let toks = (regex(#"\d+(?:[.,]\d+)?"#)?.matches(in: rest, range: NSRange(location: 0, length: ns.length)) ?? [])
            .map { ns.substring(with: $0.range) }
        guard !toks.isEmpty else { return nil }
        // «45 400 18 000»: какие пробелы — разряды тысяч, а какие разделяют числа? Ищем тройку кол-во × цена = сумма
        var best: (merges: Int, q: Double, p: Double, s: Double)?
        let gaps = min(toks.count - 1, 6)
        for mask in 0..<(1 << max(gaps, 0)) {
            var nums: [String] = []
            var cur = toks[0]
            for (i, t) in toks.dropFirst().enumerated() {
                if i < gaps, mask & (1 << i) != 0, t.count == 3, t.allSatisfy(\.isNumber), cur.allSatisfy(\.isNumber) {
                    cur += t
                } else {
                    nums.append(cur)
                    cur = t
                }
            }
            nums.append(cur)
            let v = nums.map(number)
            guard v.count >= 3 else { continue }
            for i in 0...(v.count - 3) where v[i + 2] > 0 && abs(v[i] * v[i + 1] - v[i + 2]) <= 0.03 * v[i + 2] + 1 {
                let merges = mask.nonzeroBitCount
                if best == nil || merges < best!.merges { best = (merges, v[i], v[i + 1], v[i + 2]) }
            }
        }
        if let b = best {
            return Line(text: raw, title: title, unit: unit, qty: b.q, price: b.p, sum: b.s)
        }
        if unit != nil, toks.count == 2 {
            let q = number(toks[0]), p = number(toks[1])
            return Line(text: raw, title: title, unit: unit, qty: q, price: p, sum: q * p)
        }
        var merged: [String] = []
        for t in toks {
            if let last = merged.last, t.count == 3, t.allSatisfy(\.isNumber), last.allSatisfy(\.isNumber) {
                merged[merged.count - 1] = last + t
            } else {
                merged.append(t)
            }
        }
        let v = merged.map(number)
        if v.count == 1 { return Line(text: raw, title: title, unit: unit, qty: nil, price: nil, sum: v[0]) }
        let q = v[0], total = v[v.count - 1]
        return Line(text: raw, title: title, unit: unit, qty: q, price: q > 0 && unit != nil ? total / q : nil, sum: total)
    }

    static func lines(_ text: String) -> [Line] {
        text.components(separatedBy: .newlines).prefix(400).compactMap { l in
            let low = l.lowercased()
            // итоги не сравниваем
            if low.contains("итого") || low.contains("всего") || low.contains("ндс") { return nil }
            return parse(l)
        }
    }

    // MARK: Сравнение

    private static let synonyms = [("покраск", "окраск"), ("шпатл", "шпакл"), ("кафел", "плитк"), ("керамогранит", "плитк"),
                                   ("плиточн", "плитк"), ("электроточ", "розет"), ("подрозетник", "розетк подрозет"), ("светильник", "свет"), ("потолк", "потол")]
    private static let stop: Set<String> = ["для", "под", "или", "сами", "слой", "слоя", "это", "при", "все", "уп", "шт"]
    private static let generic: Set<String> = ["монт", "уста", "устр", "укла", "рабо", "мате", "сам", "выво", "прок"]

    static func stems(_ s: String) -> Set<String> {
        var t = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        for (a, b) in synonyms { t = t.replacingOccurrences(of: a, with: b) }
        let words = t.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 && !stop.contains($0) }
        return Set(words.map { String($0.prefix(4)) })
    }

    static func match(_ line: Line, in rows: [Estimate.Row]) -> Estimate.Row? {
        let mine = stems(line.title)
        var best: (Int, Estimate.Row)?
        for r in rows {
            if let u = line.unit, u != r.unit {
                // единицы разные — это другая работа (или материал в мешках)
                continue
            }
            let common = mine.intersection(stems(r.title))
            let strong = common.subtracting(generic).count
            guard strong > 0 else { continue }
            // работы бригады чаще, чем материалы
            let material = r.section == .materials || r.id == "e.mech"
            let score = strong * 4 + (common.count - strong) * 2 + (material ? 0 : 1)
            if best == nil || score > best!.0 { best = (score, r) }
        }
        return best?.1
    }

    static func check(_ lines: [Line], rows: [Estimate.Row]) -> [Verdict] {
        lines.map { l in
            guard let r = match(l, in: rows) else {
                return Verdict(line: l, ours: nil, ourPrice: 0, qtyOver: nil, priceOver: nil, overpay: 0)
            }
            let ourPrice = Estimate.price(r)
            let qtyOver = l.qty.flatMap { q in r.qty > 0.05 && l.unit != nil ? q / r.qty - 1 : nil }
            let priceOver = l.price.flatMap { p in ourPrice > 0 ? p / ourPrice - 1 : nil }
            var fair = l.sum
            if let q = l.qty, let p = l.price {
                let fq = (qtyOver ?? 0) > 0.15 ? r.qty * 1.1 : q
                let fp = (priceOver ?? 0) > 0.3 ? ourPrice * 1.15 : p
                fair = fq * fp
            }
            return Verdict(line: l, ours: r, ourPrice: ourPrice, qtyOver: qtyOver, priceOver: priceOver, overpay: max(0, l.sum - fair))
        }
    }

    /// Текст «вопросы бригаде» — отправить в мессенджер
    static func questions(_ v: [Verdict], room: String) -> String {
        var s = "Вопросы по смете — \(room)\n"
        for x in v where x.flagged {
            guard let r = x.ours else { continue }
            s += "\n• \(x.line.title): "
            var parts: [String] = []
            if let q = x.line.qty, (x.qtyOver ?? 0) > 0.15 {
                parts.append("в смете \(fmt(q)) \(x.line.unit ?? ""), по замеру \(fmt((r.qty * 10).rounded() / 10)) \(r.unit)")
            }
            if let p = x.line.price, (x.priceOver ?? 0) > 0.3 {
                parts.append("цена \(Estimate.money(p)) за \(x.line.unit ?? "ед."), обычно около \(Estimate.money(x.ourPrice))")
            }
            s += parts.joined(separator: "; ")
        }
        return s
    }

    // MARK: Распознавание фото

    /// Текст с фото сметы: слова в одну строку, если они на одной высоте (таблица)
    static func recognize(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        let orient = orientation(image.imageOrientation)
        return await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.recognitionLanguages = ["ru-RU", "en-US"]
                req.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: cg, orientation: orient).perform([req])
                let items = (req.results ?? []).compactMap { o -> (CGRect, String)? in
                    guard let t = o.topCandidates(1).first?.string else { return nil }
                    return (o.boundingBox, t)
                }
                c.resume(returning: EstimateCheck.rows(items))
            }
        }
    }

    /// Ячейки таблицы → строки: сверху вниз, в строке слева направо
    static func rows(_ items: [(CGRect, String)]) -> String {
        let sorted = items.sorted { $0.0.midY > $1.0.midY }
        var lines: [[(CGRect, String)]] = []
        for it in sorted {
            if let last = lines.last?.first, abs(last.0.midY - it.0.midY) < max(last.0.height, it.0.height) * 0.6 {
                lines[lines.count - 1].append(it)
            } else {
                lines.append([it])
            }
        }
        return lines.map { $0.sorted { $0.0.minX < $1.0.minX }.map(\.1).joined(separator: " ") }.joined(separator: "\n")
    }

    private static func orientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

struct EstimateCheckView: View {
    let result: RoomResult
    @State private var text = ""
    @State private var verdicts: [EstimateCheck.Verdict]?
    @State private var reading = false
    @State private var camera = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var copied = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Button { camera = true } label: { Label("Сфотографировать смету", systemImage: "camera") }
                PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                    Label("Фото или скриншоты (до 6 страниц)", systemImage: "photo.on.rectangle")
                }
                Button { importing = true } label: { Label("Файл PDF или текст", systemImage: "doc") }
                if reading { HStack { ProgressView(); Text("Читаю смету…") } }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("Смета бригады")
            } footer: {
                Text("Сравню объёмы с размерами из скана, а цены — со сметой приложения (там можно поставить свои цены).")
            }
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 140)
                    .font(.system(.footnote, design: .monospaced))
                Button { verdicts = EstimateCheck.check(EstimateCheck.lines(text), rows: Estimate.rows(for: result)) } label: {
                    Label("Проверить", systemImage: "checkmark.seal").font(.headline)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Текст сметы — можно поправить или вставить сюда")
            } footer: {
                Text("Строка: работа, объём, единица, цена, сумма. Например: «Шпаклёвка стен 45 м² 400 18 000».")
            }
            if let v = verdicts { results(v) }
        }
        .navigationTitle("Проверить смету")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $camera) {
            PhotoCameraView { data in if let img = UIImage(data: data) { Task { await read([img]) } } }
        }
        .onChange(of: picked) { items in
            guard !items.isEmpty else { return }
            Task {
                var images: [UIImage] = []
                for it in items {
                    if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) { images.append(img) }
                }
                picked = []
                await read(images)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, .commaSeparatedText, .image]) { res in
            guard case .success(let url) = res else { return }
            Task { await readFile(url) }
        }
    }

    @ViewBuilder private func results(_ v: [EstimateCheck.Verdict]) -> some View {
        let flagged = v.filter(\.flagged)
        let overpay = v.reduce(0) { $0 + $1.overpay }
        let total = v.reduce(0) { $0 + $1.line.sum }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(flagged.isEmpty ? "Явных завышений не нашёл" : "Похоже на завышение: \(flagged.count) из \(v.count) строк")
                    .font(.headline).foregroundStyle(flagged.isEmpty ? Color.green : Color.orange)
                Text("Сумма по смете: \(Estimate.money(total))").font(.subheadline)
                if overpay > 0 {
                    Text("Можно сэкономить около \(Estimate.money(overpay))").font(.title3.bold()).foregroundStyle(.red)
                }
            }
            if !flagged.isEmpty {
                Button {
                    UIPasteboard.general.string = EstimateCheck.questions(v, room: result.room)
                    copied = true
                } label: {
                    Label(copied ? "Скопировано" : "Скопировать вопросы бригаде", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        } header: {
            Text("Итог")
        }
        Section {
            ForEach(v) { row($0) }
        } header: {
            Text("По строкам")
        } footer: {
            Text("Объём сравниваю с размерами скана (с запасом 15%), цену — со сметой приложения (завышение — дороже на 30% и больше). Строки, которых нет в смете приложения (демонтаж, вывоз мусора и т.п.), проверьте сами. Это подсказка для разговора с бригадой, а не приговор: у бригады могут быть причины — сложные стены, срочность.")
        }
    }

    private func row(_ x: EstimateCheck.Verdict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(x.line.title).font(.subheadline.bold())
                Spacer()
                Text(Estimate.money(x.line.sum)).font(.subheadline.monospacedDigit())
            }
            if let q = x.line.qty {
                Text("\(fmt(q)) \(x.line.unit ?? "") \(x.line.price.map { "× \(Estimate.money($0))" } ?? "")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let r = x.ours {
                if let over = x.qtyOver, over > 0.15 {
                    badge("Объём больше на \(Int((over * 100).rounded()))%: по скану \(fmt((r.qty * 10).rounded() / 10)) \(r.unit)", .orange)
                } else if let over = x.qtyOver, over < -0.2 {
                    badge("Объём меньше, чем по скану (\(fmt((r.qty * 10).rounded() / 10)) \(r.unit)) — всё ли учли?", .blue)
                }
                if let over = x.priceOver, over > 0.3 {
                    badge("Цена выше на \(Int((over * 100).rounded()))%: обычно \(Estimate.money(x.ourPrice))", .red)
                }
                if !x.flagged && !((x.qtyOver ?? 0) < -0.2) {
                    badge("В норме — сверил с «\(r.title)»", .green)
                }
            } else {
                badge("Нет в смете приложения — проверьте сами", .gray)
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption.bold()).foregroundStyle(c)
    }

    private func read(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        reading = true
        problem = nil
        defer { reading = false }
        var parts: [String] = []
        for img in images { parts.append(await EstimateCheck.recognize(img)) }
        let all = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if all.isEmpty {
            problem = "Не смог прочитать текст. Снимите смету ровно, при хорошем свете, чтобы строки были чёткими."
            return
        }
        text = all
        verdicts = EstimateCheck.check(EstimateCheck.lines(all), rows: Estimate.rows(for: result))
    }

    private func readFile(_ url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url) {
            if let s = doc.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = s
                verdicts = EstimateCheck.check(EstimateCheck.lines(s), rows: Estimate.rows(for: result))
            } else {
                // скан на бумаге — распознаём страницы как фото
                var images: [UIImage] = []
                for i in 0..<min(doc.pageCount, 6) {
                    if let page = doc.page(at: i) { images.append(page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)) }
                }
                await read(images)
            }
        } else if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            await read([img])
        } else if let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) {
            text = s.replacingOccurrences(of: ";", with: " ").replacingOccurrences(of: "\t", with: " ")
            verdicts = EstimateCheck.check(EstimateCheck.lines(text), rows: Estimate.rows(for: result))
        } else {
            problem = "Не получилось открыть файл."
        }
    }
}
