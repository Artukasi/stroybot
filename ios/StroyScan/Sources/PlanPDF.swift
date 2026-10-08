import UIKit
import simd

/// План в PDF: чертёж с размерами, окна и двери, мебель, все цифры и таблица стен.
/// Квартира — первая страница с общим планом и итогами, дальше по странице на комнату.
enum PlanPDF {
    static let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
    static let margin: CGFloat = 40

    static let ink = UIColor(red: 0.08, green: 0.13, blue: 0.18, alpha: 1)
    static let signal = UIColor(red: 0.96, green: 0.77, blue: 0.09, alpha: 1)
    static let draft = UIColor(red: 0.24, green: 0.44, blue: 0.68, alpha: 1)
    static let grey = UIColor(white: 0.45, alpha: 1)

    /// Одна комната
    static func room(_ r: RoomResult, photos: @escaping (UUID) -> UIImage? = { _ in nil }) -> URL? {
        render(name: r.room) { ctx in
            roomPage(r, ctx)
            if !r.engineering.isEmpty { engineeringPage(r, ctx) }
            if !r.defects.isEmpty { defectsPages(r, photos: photos, ctx) }
        }
    }

    /// Квартира: итоги и общий план, потом комнаты. outlines — контуры в общих координатах (или nil)
    static func flat(name: String, rooms: [RoomResult], outlines: [[[Double]]]?, photos: @escaping (UUID) -> UIImage? = { _ in nil }) -> URL? {
        render(name: name) { ctx in
            flatPage(name: name, rooms: rooms, outlines: outlines, ctx)
            for r in rooms {
                roomPage(r, ctx)
                if !r.engineering.isEmpty { engineeringPage(r, ctx) }
                if !r.defects.isEmpty { defectsPages(r, photos: photos, ctx) }
            }
        }
    }

    private static func render(name: String, _ draw: (UIGraphicsPDFRendererContext) -> Void) -> URL? {
        let meta: [String: Any] = [kCGPDFContextCreator as String: "СтройСкан", kCGPDFContextTitle as String: "План — \(name)"]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = meta
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("План — \(safe).pdf")
        do {
            try renderer.writePDF(to: url) { ctx in draw(ctx) }
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Страница комнаты

    private static func roomPage(_ r: RoomResult, _ ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y = header(title: r.room, subtitle: "План помещения")
        let planBox = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 330)
        roundedBox(planBox)
        drawRoom(r, in: planBox.insetBy(dx: 34, dy: 30), labels: true)
        y = planBox.maxY + 18

        // цифры
        let rows: [(String, String)] = [
            ("Пол", "\(fmt(r.floorArea)) м²"),
            ("Стены без окон и дверей", "\(fmt(r.wallArea)) м²"),
            ("Периметр", "\(fmt(r.perimeter)) м"),
            ("Высота потолка", "\(fmt(r.height)) м"),
            ("Длина × ширина", "\(fmt(r.length)) × \(fmt(r.width)) м"),
            ("Окна / двери", "\(r.windows) / \(r.doors) шт"),
            ("Плинтус", "\(fmt(r.skirting)) м"),
            ("Откосы окон", "\(fmt(r.slopes)) м"),
        ]
        let colW = (page.width - 2 * margin - 16) / 2
        for (i, row) in rows.enumerated() {
            let x = margin + CGFloat(i % 2) * (colW + 16)
            let ry = y + CGFloat(i / 2) * 24
            text(row.0, at: CGPoint(x: x, y: ry), size: 10, color: grey)
            text(row.1, at: CGPoint(x: x, y: ry), size: 11, bold: true, width: colW, align: .right)
            line(from: CGPoint(x: x, y: ry + 18), to: CGPoint(x: x + colW, y: ry + 18), color: UIColor(white: 0.88, alpha: 1), width: 0.5)
        }
        y += 24 * 4 + 14

        // стены
        text("Стены", at: CGPoint(x: margin, y: y), size: 12, bold: true)
        y += 18
        let heads = ["№", "Длина, м", "Высота, м", "Окна и двери, м²", "Чистая площадь, м²"]
        let widths: [CGFloat] = [40, 100, 100, 130, 145]
        y = tableRow(heads, widths, y: y, bold: true)
        for (i, w) in r.walls.enumerated() {
            if y > page.height - 120 { break }
            let net = max(0, w.length * w.height - w.openingsArea)
            let mark = r.quality.weakWalls.contains(i) ? " ⚠︎" : ""
            y = tableRow(["\(i + 1)\(mark)", fmt(w.length), fmt(w.height), fmt(w.openingsArea), fmt((net * 100).rounded() / 100)], widths, y: y)
        }

        // мебель
        if !r.items.isEmpty && y < page.height - 110 {
            y += 12
            text("Мебель и техника (ширина × глубина × высота, см)", at: CGPoint(x: margin, y: y), size: 12, bold: true)
            y += 18
            let list = r.items.map { i -> String in
                let cm = { (v: Double) in Int((v * 100).rounded()) }
                return "\(i.title) \(cm(i.width))×\(cm(i.depth))×\(cm(i.height))"
            }.joined(separator: " · ")
            text(list, at: CGPoint(x: margin, y: y), size: 9.5, color: grey, width: page.width - 2 * margin)
        }
        footer()
    }

    // MARK: - Электрика и сантехника

    private static func engineeringPage(_ r: RoomResult, _ ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y = header(title: r.room, subtitle: "Электрика и сантехника")
        let planBox = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 300)
        roundedBox(planBox)
        drawRoom(r, in: planBox.insetBy(dx: 34, dy: 30), labels: true, furniture: false, starts: true)
        y = planBox.maxY + 16

        // итоги
        let rows = r.engineering.summary(ceiling: r.height, wallLines: r.wallLines)
        let colW = (page.width - 2 * margin - 16) / 2
        for (i, row) in rows.enumerated() {
            let x = margin + CGFloat(i % 2) * (colW + 16)
            let ry = y + CGFloat(i / 2) * 20
            text(row.title, at: CGPoint(x: x, y: ry), size: 9.5, color: grey, width: colW - 60)
            text(row.value, at: CGPoint(x: x, y: ry), size: 10, bold: true, width: colW, align: .right)
        }
        y += CGFloat((rows.count + 1) / 2) * 20 + 12

        // где стоит каждая точка
        text("Где ставить: отступ — от угла, где у стены жёлтый треугольник ▶ на плане", at: CGPoint(x: margin, y: y), size: 11, bold: true)
        y += 18
        let widths: [CGFloat] = [36, 185, 70, 110, 114]
        y = tableRow(["Знак", "Что", "Стена", "От угла, см", "От пола, см"], widths, y: y, bold: true)
        let pts = r.engineering.points.sorted { ($0.wall ?? 999, $0.offset) < ($1.wall ?? 999, $1.offset) }
        let cm = { (v: Double) in "\(Int((v * 100).rounded()))" }
        for p in pts {
            if y > page.height - 70 {
                text("…и ещё \(pts.count - (pts.firstIndex(where: { $0.id == p.id }) ?? 0)) — смотрите план в приложении",
                     at: CGPoint(x: margin, y: y), size: 9, color: grey)
                break
            }
            guard let k = EngKind.find(p.kind) else { continue }
            let wall = p.wall.map { "№\($0 + 1)" } ?? "потолок"
            y = tableRow([k.short, k.title, wall, p.wall == nil ? "—" : cm(p.offset), p.wall == nil ? "—" : cm(p.height)], widths, y: y)
        }
        footer()
    }

    // MARK: - Документ для клиента

    /// План, смета по своим ценам, фото, дефекты и подпись клиента — одним PDF
    static func clientDoc(_ r: RoomResult, client: String, address: String, withPlan: Bool, withEstimate: Bool,
                          withPhoto: Bool, withDefects: Bool, signature: UIImage?, photos: @escaping (UUID) -> UIImage?) -> URL? {
        let rows = Estimate.rows(for: r).filter { Estimate.isOn($0) }
        let total = rows.reduce(0) { $0 + Estimate.cost($1, Estimate.price($1)) }
        return render(name: "Смета \(r.room)" + (client.isEmpty ? "" : " — \(client)")) { ctx in
            ctx.beginPage()
            var y = header(title: "Смета и план", subtitle: r.room)
            let info = [("Заказчик", client), ("Адрес", address), ("Дата", Date().formatted(date: .long, time: .omitted)),
                        ("Помещение", "\(r.room): пол \(fmt(r.floorArea)) м², стены \(fmt(r.wallArea)) м², высота \(fmt(r.height)) м")]
            for (t, v) in info where !v.isEmpty {
                text(t, at: CGPoint(x: margin, y: y), size: 10, color: grey)
                text(v, at: CGPoint(x: margin + 110, y: y), size: 11, bold: true, width: page.width - 2 * margin - 110)
                y += 22
            }
            if withEstimate {
                y += 8
                let band = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 54)
                let p = UIBezierPath(roundedRect: band, cornerRadius: 12)
                ink.setFill()
                p.fill()
                text("ИТОГО ПО СМЕТЕ", at: CGPoint(x: band.minX + 16, y: band.minY + 10), size: 9, bold: true, color: signal)
                text(Estimate.money(total), at: CGPoint(x: band.minX + 16, y: band.minY + 22), size: 20, bold: true, color: .white)
                y = band.maxY + 18
                y = estimateTable(rows, from: y, ctx: ctx, room: r.room)
            }
            if withPhoto, let data = r.photo, let img = UIImage(data: data) {
                if y > page.height - 300 { footer(); ctx.beginPage(); y = header(title: r.room, subtitle: "Фото помещения") }
                let box = CGRect(x: margin, y: y + 6, width: page.width - 2 * margin, height: min(260, page.height - 140 - y))
                let g = UIGraphicsGetCurrentContext()
                g?.saveGState()
                UIBezierPath(roundedRect: box, cornerRadius: 12).addClip()
                let k = max(box.width / img.size.width, box.height / img.size.height)
                let sz = CGSize(width: img.size.width * k, height: img.size.height * k)
                img.draw(in: CGRect(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2, width: sz.width, height: sz.height))
                g?.restoreGState()
                y = box.maxY + 14
            }
            if y > page.height - 200 { footer(); ctx.beginPage(); y = header(title: r.room, subtitle: "Подписи") }
            signatures(at: max(y + 10, page.height - 190), signature: signature, client: client)
            footer()
            if withPlan {
                roomPage(r, ctx)
                if !r.engineering.isEmpty { engineeringPage(r, ctx) }
            }
            if withDefects && !r.defects.isEmpty { defectsPages(r, photos: photos, ctx) }
        }
    }

    private static func estimateTable(_ rows: [Estimate.Row], from start: CGFloat, ctx: UIGraphicsPDFRendererContext, room: String) -> CGFloat {
        var y = start
        let widths: [CGFloat] = [245, 80, 90, 100]
        for section in Estimate.Section.allCases {
            let list = rows.filter { $0.section == section }
            guard !list.isEmpty else { continue }
            if y > page.height - 120 { footer(); ctx.beginPage(); y = header(title: room, subtitle: "Смета (продолжение)") }
            text(section.rawValue, at: CGPoint(x: margin, y: y), size: 12, bold: true)
            y += 18
            y = tableRow(["Наименование", "Кол-во", "Цена", "Сумма"], widths, y: y, bold: true)
            var sum = 0.0
            for row in list {
                if y > page.height - 70 { footer(); ctx.beginPage(); y = header(title: room, subtitle: "Смета (продолжение)") }
                let price = Estimate.price(row), cost = Estimate.cost(row, price)
                sum += cost
                y = tableRow([row.title, "\(Estimate.qty(row.qty, row.unit)) \(row.unit)", Estimate.money(price), Estimate.money(cost)], widths, y: y)
            }
            y = tableRow(["Итого: \(section.rawValue.lowercased())", "", "", Estimate.money(sum)], widths, y: y, bold: true)
            y += 10
        }
        return y
    }

    private static func signatures(at y: CGFloat, signature: UIImage?, client: String) {
        let w = (page.width - 2 * margin - 30) / 2
        let brand = Brand.current
        for (i, who) in ["Исполнитель", "Заказчик"].enumerated() {
            let x = margin + CGFloat(i) * (w + 30)
            text(who, at: CGPoint(x: x, y: y), size: 10, bold: true)
            if i == 1, let signature {
                let h: CGFloat = 70
                let sw = min(w, h * signature.size.width / max(signature.size.height, 1))
                signature.draw(in: CGRect(x: x, y: y + 18, width: sw, height: h))
            }
            line(from: CGPoint(x: x, y: y + 92), to: CGPoint(x: x + w, y: y + 92), color: ink, width: 0.8)
            let name = i == 0 ? [brand.name, brand.phone].filter { !$0.isEmpty }.joined(separator: ", ") : client
            text(name.isEmpty ? "подпись, ФИО" : name, at: CGPoint(x: x, y: y + 96), size: 8.5, color: grey, width: w)
        }
        text("С объёмами и ценами согласен. Объёмы посчитаны по скану лидаром; перед закупкой материалов ключевые размеры проверяются рулеткой.",
             at: CGPoint(x: margin, y: y + 124), size: 8, color: grey, width: page.width - 2 * margin)
    }

    // MARK: - Дефекты

    /// План с номерами, дальше карточки: фото, что, где, заметка, исправлено ли
    private static func defectsPages(_ r: RoomResult, photos: (UUID) -> UIImage?, _ ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        let open = r.defects.filter { !$0.fixed }.count
        var y = header(title: r.room, subtitle: "Дефекты · \(r.defects.count) шт, не исправлено \(open)")
        let planBox = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 250)
        roundedBox(planBox)
        let inner = planBox.insetBy(dx: 34, dy: 26)
        drawRoom(r, in: inner, labels: false, furniture: false)
        // те же расчёты рамки, что в drawRoom
        let all = r.plan + r.wallLines.flatMap { [SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)] }
        if let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(),
           maxX > minX, maxY > minY {
            let k = min(inner.width / CGFloat(maxX - minX), inner.height / CGFloat(maxY - minY))
            let ox = inner.minX + (inner.width - CGFloat(maxX - minX) * k) / 2
            let oy = inner.minY + (inner.height - CGFloat(maxY - minY) * k) / 2
            for (i, d) in r.defects.enumerated() {
                let c = CGPoint(x: ox + CGFloat(d.x - minX) * k, y: oy + CGFloat(d.y - minY) * k)
                let dot = UIBezierPath(ovalIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
                (d.fixed ? UIColor.systemGreen : UIColor.systemRed).setFill()
                dot.fill()
                text("\(i + 1)", at: CGPoint(x: c.x - 8, y: c.y - 5.5), size: 8, bold: true, color: .white, width: 16, align: .center)
            }
        }
        y = planBox.maxY + 16

        let cardH: CGFloat = 118
        for (i, d) in r.defects.enumerated() {
            if y + cardH > page.height - 50 {
                footer()
                ctx.beginPage()
                y = header(title: r.room, subtitle: "Дефекты (продолжение)")
            }
            let card = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: cardH - 10)
            roundedBox(card)
            var tx = card.minX + 12
            if d.hasPhoto, let img = photos(d.id) {
                let ph = CGRect(x: card.minX + 8, y: card.minY + 8, width: 128, height: card.height - 16)
                let ctxg = UIGraphicsGetCurrentContext()
                ctxg?.saveGState()
                UIBezierPath(roundedRect: ph, cornerRadius: 8).addClip()
                // заполнить рамку, сохранив пропорции
                let s = max(ph.width / img.size.width, ph.height / img.size.height)
                let size = CGSize(width: img.size.width * s, height: img.size.height * s)
                img.draw(in: CGRect(x: ph.midX - size.width / 2, y: ph.midY - size.height / 2, width: size.width, height: size.height))
                ctxg?.restoreGState()
                tx = ph.maxX + 12
            }
            let badge = UIBezierPath(ovalIn: CGRect(x: tx, y: card.minY + 10, width: 20, height: 20))
            (d.fixed ? UIColor.systemGreen : UIColor.systemRed).setFill()
            badge.fill()
            text("\(i + 1)", at: CGPoint(x: tx, y: card.minY + 13.5), size: 9, bold: true, color: .white, width: 20, align: .center)
            text(d.title + (d.fixed ? " — исправлено" : ""), at: CGPoint(x: tx + 28, y: card.minY + 11), size: 12, bold: true,
                 color: d.fixed ? .systemGreen : ink, width: card.maxX - tx - 40)
            let place = d.wall.map { "Стена \($0 + 1), высота \(Int((d.height * 100).rounded())) см от пола" }
                ?? (d.height < 0.1 ? "Пол" : "Потолок")
            let date = d.created.formatted(date: .abbreviated, time: .omitted)
            text("\(place) · отмечено \(date)", at: CGPoint(x: tx, y: card.minY + 36), size: 9, color: grey, width: card.maxX - tx - 12)
            if !d.note.isEmpty {
                text(d.note, at: CGPoint(x: tx, y: card.minY + 52), size: 10, color: UIColor(white: 0.15, alpha: 1),
                     width: card.maxX - tx - 12)
            }
            y += cardH
        }
        footer()
    }

    // MARK: - Страница квартиры

    private static func flatPage(name: String, rooms: [RoomResult], outlines: [[[Double]]]?, _ ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y = header(title: name, subtitle: "План квартиры · \(rooms.count) \(plural(rooms.count, "комната", "комнаты", "комнат"))")
        let box = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 380)
        roundedBox(box)
        drawFlat(rooms: rooms, outlines: outlines, in: box.insetBy(dx: 26, dy: 26))
        y = box.maxY + 20

        let heads = ["Помещение", "Пол, м²", "Стены, м²", "Периметр, м", "Высота, м"]
        let widths: [CGFloat] = [175, 85, 85, 85, 85]
        y = tableRow(heads, widths, y: y, bold: true)
        for r in rooms {
            if y > page.height - 110 { break }
            y = tableRow([r.room, fmt(r.floorArea), fmt(r.wallArea), fmt(r.perimeter), fmt(r.height)], widths, y: y)
        }
        let floor = rooms.reduce(0) { $0 + $1.floorArea }, walls = rooms.reduce(0) { $0 + $1.wallArea }
        let skirting = rooms.reduce(0) { $0 + $1.skirting }
        y = tableRow(["Итого", fmt((floor * 100).rounded() / 100), fmt((walls * 100).rounded() / 100),
                      "плинтус \(fmt((skirting * 10).rounded() / 10))", ""], widths, y: y, bold: true)
        footer()
    }

    /// Общий план: комнаты по общим координатам, либо (сняты по отдельности) в ряд
    private static func drawFlat(rooms: [RoomResult], outlines: [[[Double]]]?, in box: CGRect) {
        let shapes = FlatLayout.shapes(rooms: rooms, outlines: outlines)
        let all = shapes.flatMap(\.points)
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(), maxX > minX, maxY > minY else { return }
        let k = min(box.width / CGFloat(maxX - minX), box.height / CGFloat(maxY - minY))
        let ox = box.minX + (box.width - CGFloat(maxX - minX) * k) / 2
        let oy = box.minY + (box.height - CGFloat(maxY - minY) * k) / 2
        let map = { (p: SIMD2<Double>) in CGPoint(x: ox + CGFloat(p.x - minX) * k, y: oy + CGFloat(p.y - minY) * k) }
        let colors = FlatLayout.colors
        for (i, s) in shapes.enumerated() where s.points.count > 2 {
            let path = UIBezierPath()
            path.move(to: map(s.points[0]))
            for p in s.points.dropFirst() { path.addLine(to: map(p)) }
            path.close()
            colors[i % colors.count].withAlphaComponent(0.18).setFill()
            path.fill()
            ink.setStroke()
            path.lineWidth = 2.5
            path.lineJoinStyle = .round
            path.stroke()
            let c = map(FlatLayout.centroid(s.points))
            let title = "\(rooms[i].room)\n\(fmt(rooms[i].floorArea)) м²"
            text(title, at: CGPoint(x: c.x - 60, y: c.y - 14), size: 9.5, bold: true, width: 120, align: .center)
        }
        scaleBar(k: k, at: CGPoint(x: box.minX, y: box.maxY + 8))
    }

    // MARK: - Чертёж комнаты

    static func drawRoom(_ r: RoomResult, in box: CGRect, labels: Bool, furniture: Bool = true, starts: Bool = false) {
        let lines = r.wallLines
        let all = r.plan + lines.flatMap { [SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)] }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(), maxX > minX, maxY > minY else { return }
        let k = min(box.width / CGFloat(maxX - minX), box.height / CGFloat(maxY - minY))
        let ox = box.minX + (box.width - CGFloat(maxX - minX) * k) / 2
        let oy = box.minY + (box.height - CGFloat(maxY - minY) * k) / 2
        let map = { (p: SIMD2<Double>) in CGPoint(x: ox + CGFloat(p.x - minX) * k, y: oy + CGFloat(p.y - minY) * k) }

        // пол
        if r.plan.count > 2 {
            let floor = UIBezierPath()
            floor.move(to: map(r.plan[0]))
            for p in r.plan.dropFirst() { floor.addLine(to: map(p)) }
            floor.close()
            draft.withAlphaComponent(0.08).setFill()
            floor.fill()
        }
        // мебель
        for it in r.items where furniture {
            let w = CGFloat(it.width) * k, d = CGFloat(it.depth) * k
            let c = map(SIMD2(it.x, it.y))
            let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(it.angle))
            let bez = UIBezierPath(roundedRect: CGRect(x: -w / 2, y: -d / 2, width: w, height: d), cornerRadius: min(2, w / 2, d / 2))
            bez.apply(t)
            UIColor(furnitureColor(it.kind)).withAlphaComponent(0.25).setFill()
            bez.fill()
            UIColor(furnitureColor(it.kind)).setStroke()
            bez.lineWidth = 0.8
            bez.stroke()
            if w > 34 && d > 14 {
                text(it.title, at: CGPoint(x: c.x - w / 2, y: c.y - 6), size: 6.5, color: grey, width: w, align: .center)
            }
        }
        // стены
        let center = map(SIMD2((minX + maxX) / 2, (minY + maxY) / 2))
        for (i, l) in lines.enumerated() {
            let a = map(SIMD2(l.x, l.y)), b = map(SIMD2(l.z, l.w))
            line(from: a, to: b, color: ink, width: 4)
            guard labels else { continue }
            let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let len = hypot(l.z - l.x, l.w - l.y)
            // длина — снаружи, номер — внутри
            let dx = m.x - center.x, dy = m.y - center.y
            let d = max(hypot(dx, dy), 1)
            let out = CGPoint(x: m.x + dx / d * 16, y: m.y + dy / d * 16)
            text(fmt((len * 100).rounded() / 100), at: CGPoint(x: out.x - 30, y: out.y - 6), size: 8.5, bold: true, width: 60, align: .center)
            let inn = CGPoint(x: m.x - dx / d * 13, y: m.y - dy / d * 13)
            let circle = UIBezierPath(ovalIn: CGRect(x: inn.x - 7, y: inn.y - 7, width: 14, height: 14))
            (r.quality.weakWalls.contains(i) ? UIColor.orange : UIColor(white: 0.7, alpha: 1)).setFill()
            circle.fill()
            text("\(i + 1)", at: CGPoint(x: inn.x - 7, y: inn.y - 5.5), size: 7.5, bold: true, color: .white, width: 14, align: .center)
        }
        // окна и двери поверх стен
        for o in r.openings {
            guard let wi = o.wall, wi < lines.count, let off = o.offset else { continue }
            let l = lines[wi]
            let a = SIMD2(l.x, l.y), b = SIMD2(l.z, l.w)
            let len = simd_distance(a, b)
            guard len > 0 else { continue }
            let u = (b - a) / len
            let p1 = map(a + u * max(0, off - o.width / 2)), p2 = map(a + u * min(len, off + o.width / 2))
            line(from: p1, to: p2, color: .white, width: 5)
            if o.kind == "window" {
                line(from: p1, to: p2, color: draft, width: 1.2)
                let n = CGPoint(x: -(p2.y - p1.y), y: p2.x - p1.x)
                let nl = max(hypot(n.x, n.y), 1)
                let s = CGPoint(x: n.x / nl * 2.2, y: n.y / nl * 2.2)
                line(from: CGPoint(x: p1.x + s.x, y: p1.y + s.y), to: CGPoint(x: p2.x + s.x, y: p2.y + s.y), color: draft, width: 1.2)
                line(from: CGPoint(x: p1.x - s.x, y: p1.y - s.y), to: CGPoint(x: p2.x - s.x, y: p2.y - s.y), color: draft, width: 1.2)
            } else {
                line(from: p1, to: p2, color: signal, width: 2)
            }
        }
        // начало каждой стены — от него отсчитываются отступы точек
        if starts {
            for (i, l) in lines.enumerated() where r.engineering.points.contains(where: { $0.wall == i }) {
                let a = map(SIMD2(l.x, l.y)), b = map(SIMD2(l.z, l.w))
                let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                let u = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
                var n = CGPoint(x: -u.y, y: u.x)
                if (center.x - a.x) * n.x + (center.y - a.y) * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
                let base = CGPoint(x: a.x + u.x * 4 + n.x * 8, y: a.y + u.y * 4 + n.y * 8)
                let tri = UIBezierPath()
                tri.move(to: CGPoint(x: base.x + u.x * 9, y: base.y + u.y * 9))
                tri.addLine(to: CGPoint(x: base.x + n.x * 4, y: base.y + n.y * 4))
                tri.addLine(to: CGPoint(x: base.x - n.x * 4, y: base.y - n.y * 4))
                tri.close()
                signal.setFill()
                tri.fill()
                ink.setStroke()
                tri.lineWidth = 0.6
                tri.stroke()
            }
        }
        // трубы и точки электрики и сантехники
        for p in r.engineering.pipes {
            guard let first = p.points.first, let kind = PipeKind.find(p.kind) else { continue }
            let path = UIBezierPath()
            path.move(to: map(SIMD2(first.x, first.y)))
            for q in p.points.dropFirst() { path.addLine(to: map(SIMD2(q.x, q.y))) }
            path.lineWidth = 2.2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            kind.color.setStroke()
            path.stroke()
        }
        for p in r.engineering.wires {
            guard let first = p.points.first, let kind = WireKind.find(p.kind) else { continue }
            let path = UIBezierPath()
            path.move(to: map(SIMD2(first.x, first.y)))
            for q in p.points.dropFirst() { path.addLine(to: map(SIMD2(q.x, q.y))) }
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.setLineDash([4, 2], count: 2, phase: 0)
            kind.color.setStroke()
            path.stroke()
        }
        for p in r.engineering.points {
            guard let kind = EngKind.find(p.kind) else { continue }
            let c = map(SIMD2(p.x, p.y))
            let dot = UIBezierPath(ovalIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
            kind.color.setFill()
            dot.fill()
            UIColor.white.setStroke()
            dot.lineWidth = 1
            dot.stroke()
            text(kind.short, at: CGPoint(x: c.x - 6, y: c.y - 3.6), size: 5.5, bold: true, color: .white, width: 12, align: .center)
        }
        if labels { scaleBar(k: k, at: CGPoint(x: box.minX - 20, y: box.maxY + 12)) }
    }

    // MARK: - Бланк замера окон и дверей

    static func openingsForm(_ r: RoomResult) -> URL? {
        let lines = OrderSizes.lines(r)
        let meta: [String: Any] = [kCGPDFContextCreator as String: "СтройСкан", kCGPDFContextTitle as String: "Замер — \(r.room)"]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = meta
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        let safe = r.room.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Замер окон и дверей — \(safe).pdf")
        let widths: [CGFloat] = [62, 36, 92, 52, 120, 78, 75]
        func head() -> CGFloat {
            var y = header(title: "Замер окон и дверей", subtitle: r.room)
            text("Адрес: ______________________________________________   Дата замера: ____________",
                 at: CGPoint(x: margin, y: y), size: 10)
            y += 26
            return tableRow(["Что", "Стена", "Проём по скану, мм", "Низ, мм", "Заказ (ориентир)", "Рулеткой Ш×В", "Стена, мм"],
                            widths, y: y, bold: true)
        }
        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                var y = head()
                for l in lines {
                    if y > page.height - 190 {
                        footer()
                        ctx.beginPage()
                        y = head()
                    }
                    y = tableRow([l.title, l.wall.map { "\($0 + 1)" } ?? "—", "\(l.width) × \(l.height)",
                                  l.kind == "window" ? "\(l.bottom)" : "0", l.order, "____ × ____", "______"], widths, y: y)
                    text(l.note, at: CGPoint(x: margin + 8, y: y + 8), size: 7.5, color: grey, width: page.width - 2 * margin - 16)
                    y += 40
                }
                y += 10
                let tips = """
                Как мерить: ширину проёма — в трёх местах (верх, середина, низ), высоту — слева, посередине и справа; в бланк — меньшее. \
                Толщину стены — у каждого проёма (нужна для подоконника, откосов и доборов). \
                Размеры «по скану» сняты лидаром iPhone, точность ±1–2 см; заказ — только по замеру рулеткой.
                """
                text(tips, at: CGPoint(x: margin, y: y), size: 9, color: ink, width: page.width - 2 * margin)
                y += 64
                text("Замерщик: ____________________   Подпись: ____________     Заказчик: ____________________   Подпись: ____________",
                     at: CGPoint(x: margin, y: min(y, page.height - 70)), size: 9)
                footer()
            }
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Мелочи

    @discardableResult
    private static func header(title: String, subtitle: String) -> CGFloat {
        let band = CGRect(x: 0, y: 0, width: page.width, height: 74)
        ink.setFill()
        UIBezierPath(rect: band).fill()
        signal.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 74, width: page.width, height: 4)).fill()
        text(subtitle.uppercased(), at: CGPoint(x: margin, y: 18), size: 9, bold: true, color: signal)
        text(title, at: CGPoint(x: margin, y: 32), size: 22, bold: true, color: .white, width: page.width / 2 - margin)
        let date = Date().formatted(date: .long, time: .omitted)
        let brand = Brand.current
        if brand.isEmpty {
            text("СтройСкан\n\(date)", at: CGPoint(x: page.width - margin - 160, y: 26), size: 9, color: UIColor(white: 1, alpha: 0.7),
                 width: 160, align: .right)
        } else {
            // логотип и контакты бригады справа
            var right = page.width - margin
            if let logo = Brand.logo {
                let h: CGFloat = 46
                let w = min(90, h * logo.size.width / max(logo.size.height, 1))
                let r = CGRect(x: right - w, y: 14, width: w, height: h)
                UIBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), cornerRadius: 6).addClip()
                UIColor.white.setFill()
                UIBezierPath(rect: r.insetBy(dx: -3, dy: -3)).fill()
                logo.draw(in: r)
                UIGraphicsGetCurrentContext()?.resetClip()
                right = r.minX - 10
            }
            let lines = [brand.name, brand.phone, brand.note, date].filter { !$0.isEmpty }
            text(lines.joined(separator: "\n"), at: CGPoint(x: right - 190, y: 14), size: 8.5, color: UIColor(white: 1, alpha: 0.85),
                 width: 190, align: .right)
        }
        return 96
    }

    private static func footer() {
        text("Размеры сняты лидаром iPhone (RoomPlan), стены выровнены по углам. Перед заказом материалов проверьте ключевые размеры рулеткой.",
             at: CGPoint(x: margin, y: page.height - 34), size: 7.5, color: grey, width: page.width - 2 * margin)
    }

    private static func roundedBox(_ r: CGRect) {
        let p = UIBezierPath(roundedRect: r, cornerRadius: 14)
        UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1).setFill()
        p.fill()
    }

    private static func scaleBar(k: CGFloat, at p: CGPoint) {
        guard k > 0 else { return }
        let x = max(p.x, margin)
        line(from: CGPoint(x: x, y: p.y), to: CGPoint(x: x + k, y: p.y), color: ink, width: 2)
        line(from: CGPoint(x: x, y: p.y - 3), to: CGPoint(x: x, y: p.y + 3), color: ink, width: 1)
        line(from: CGPoint(x: x + k, y: p.y - 3), to: CGPoint(x: x + k, y: p.y + 3), color: ink, width: 1)
        text("1 м", at: CGPoint(x: x + k + 5, y: p.y - 6), size: 8, color: grey)
    }

    private static func tableRow(_ cells: [String], _ widths: [CGFloat], y: CGFloat, bold: Bool = false) -> CGFloat {
        var x = margin
        for (c, w) in zip(cells, widths) {
            text(c, at: CGPoint(x: x, y: y), size: 9.5, bold: bold, color: bold ? ink : UIColor(white: 0.2, alpha: 1), width: w - 6)
            x += w
        }
        line(from: CGPoint(x: margin, y: y + 16), to: CGPoint(x: page.width - margin, y: y + 16), color: UIColor(white: 0.88, alpha: 1), width: 0.5)
        return y + 20
    }

    private static func line(from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat) {
        let p = UIBezierPath()
        p.move(to: a)
        p.addLine(to: b)
        p.lineWidth = width
        p.lineCapStyle = .round
        color.setStroke()
        p.stroke()
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, bold: Bool = false, color: UIColor = ink,
                             width: CGFloat? = nil, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        if let width {
            str.draw(with: CGRect(x: p.x, y: p.y, width: width, height: 400), options: [.usesLineFragmentOrigin], context: nil)
        } else {
            str.draw(at: p)
        }
    }
}

/// Раскладка комнат квартиры на общем плане
enum FlatLayout {
    struct Shape {
        var points: [SIMD2<Double>]
    }

    static let colors: [UIColor] = [
        UIColor(red: 0.24, green: 0.44, blue: 0.68, alpha: 1),
        UIColor(red: 0.96, green: 0.62, blue: 0.09, alpha: 1),
        UIColor(red: 0.30, green: 0.65, blue: 0.45, alpha: 1),
        UIColor(red: 0.70, green: 0.35, blue: 0.55, alpha: 1),
        UIColor(red: 0.45, green: 0.75, blue: 0.80, alpha: 1),
    ]

    /// Общие координаты (сняты за один раз) — поворачиваем, чтобы самая длинная стена шла по горизонтали.
    /// Без них — планы комнат в ряд с отступом
    static func shapes(rooms: [RoomResult], outlines: [[[Double]]]?) -> [Shape] {
        if let outlines, outlines.count == rooms.count, outlines.allSatisfy({ $0.count > 2 }) {
            let polys = outlines.map { $0.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil } }
            var best = 0.0, angle = 0.0
            for poly in polys {
                for (a, b) in zip(poly, poly.dropFirst() + [poly[0]]) {
                    let l = simd_distance(a, b)
                    if l > best { best = l; angle = atan2(b.y - a.y, b.x - a.x) }
                }
            }
            let c = cos(-angle), s = sin(-angle)
            return polys.map { Shape(points: $0.map { SIMD2($0.x * c - $0.y * s, $0.x * s + $0.y * c) }) }
        }
        var out: [Shape] = []
        var x = 0.0, y = 0.0, rowH = 0.0
        let rowW = max(8.0, sqrt(rooms.reduce(0) { $0 + $1.length * $1.width }) * 1.6)
        for r in rooms {
            let w = r.plan.map(\.x).max() ?? r.length, h = r.plan.map(\.y).max() ?? r.width
            if x > 0 && x + w > rowW { x = 0; y += rowH + 0.8; rowH = 0 }
            let pts = r.plan.count > 2 ? r.plan : [SIMD2(0, 0), SIMD2(r.length, 0), SIMD2(r.length, r.width), SIMD2(0, r.width)]
            out.append(Shape(points: pts.map { $0 + SIMD2(x, y) }))
            x += w + 0.8
            rowH = max(rowH, h)
        }
        return out
    }

    static func centroid(_ p: [SIMD2<Double>]) -> SIMD2<Double> {
        guard !p.isEmpty else { return .zero }
        return p.reduce(SIMD2<Double>.zero, +) / Double(p.count)
    }
}
