import SceneKit
import UIKit
import simd

// Материалы ремонта: текстуры рисуются кодом (дерево, плитка со швами, обои, ткань),
// к ним — карты рельефа и шероховатости, чтобы свет ложился как на настоящие поверхности.

/// Предсказуемый генератор случайных чисел: текстура одинаковая при каждом открытии
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 33
        return x
    }
}

func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
}

/// k < 1 — темнее, k > 1 — светлее
func shade(_ c: UIColor, _ k: CGFloat) -> UIColor {
    mix(c, k < 1 ? .black : .white, min(1, abs(1 - k)))
}

/// Карты материала. `meters` — сколько метров в стороне картинки.
struct TexSet {
    let diffuse: UIImage
    let normal: UIImage?
    let rough: UIImage?
    let meters: CGFloat

    /// Сколько памяти занимают картинки
    var bytes: Int { [diffuse, normal, rough].reduce(0) { $0 + imageBytes($1) } }
}

/// Байты картинки в памяти (без копии на видеокарте)
func imageBytes(_ image: UIImage?) -> Int {
    guard let cg = image?.cgImage else { return 0 }
    return cg.bytesPerRow * cg.height
}

/// Кэш с пределом по памяти: лишнее выбрасывает то, что дольше всего не брали.
/// Пока человек перебирает отделку, текстуры не копятся; при нехватке памяти — очищается весь.
final class MemoryCache<Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var used: UInt64
    }

    private var items: [String: Entry] = [:]
    private var total = 0
    private var clock: UInt64 = 0
    private let limit: Int
    private let lock = NSLock()
    private var warning: NSObjectProtocol?

    /// limit — байты
    init(limit: Int) {
        self.limit = limit
        warning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                         object: nil, queue: nil) { [weak self] _ in self?.removeAll() }
    }

    func get(_ key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard var e = items[key] else { return nil }
        clock += 1
        e.used = clock
        items[key] = e
        return e.value
    }

    func set(_ key: String, _ value: Value, cost: Int) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        total -= items[key]?.cost ?? 0
        items[key] = Entry(value: value, cost: cost, used: clock)
        total += cost
        while total > limit && items.count > 1 {
            guard let oldest = items.min(by: { $0.value.used < $1.value.used }) else { break }
            total -= oldest.value.cost
            items[oldest.key] = nil
        }
    }

    func removeAll() {
        lock.lock()
        items = [:]
        total = 0
        lock.unlock()
    }
}

/// Проход рисования: цвет, высота рельефа (серый) или шероховатость (серый)
enum Pass { case color, height, rough }

enum Tex {
    /// Нужное одной комнате — около 30 МБ, держим примерно два ремонта
    private static let cache = MemoryCache<TexSet>(limit: 64 << 20)

    static func cached(_ key: String, _ make: () -> TexSet) -> TexSet {
        if let t = cache.get(key) { return t }
        let t = make()
        cache.set(key, t, cost: t.bytes)
        return t
    }

    /// Экран 3D закрыли — текстуры больше не нужны
    static func purge() { cache.removeAll() }

    // MARK: Холст

    /// Картинка size×size, начало координат — левый верхний угол
    static func draw(_ size: Int, gray: Bool, _ body: (CGContext) -> Void) -> CGImage? {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        return ctx.makeImage()
    }

    /// Серые пиксели картинки, первая строка — верх
    static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return buf
    }

    /// Карта нормалей из карты высот (плитка бесшовная — края берутся с другой стороны)
    static func normalMap(_ h: [UInt8], _ size: Int, strength: Float) -> UIImage? {
        guard h.count == size * size else { return nil }
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            let row = y * size
            let up = ((y - 1 + size) % size) * size
            let down = ((y + 1) % size) * size
            for x in 0..<size {
                let l = (x - 1 + size) % size, r = (x + 1) % size
                let dx = (Float(h[row + l]) - Float(h[row + r])) / 255 * strength
                let dy = (Float(h[down + x]) - Float(h[up + x])) / 255 * strength
                let inv = 1 / (dx * dx + dy * dy + 1).squareRoot()
                let i = (row + x) * 4
                px[i] = UInt8(max(0, min(255, (dx * inv * 0.5 + 0.5) * 255)))
                px[i + 1] = UInt8(max(0, min(255, (dy * inv * 0.5 + 0.5) * 255)))
                px[i + 2] = UInt8(max(0, min(255, (inv * 0.5 + 0.5) * 255)))
            }
        }
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Рисует три прохода одной и той же случайной картинкой: цвет, рельеф, шероховатость
    static func make(size: Int, meters: CGFloat, seed: UInt64, normal: Float, roughMap: Bool,
                     _ paint: (CGContext, Pass, inout SeededRandom) -> Void) -> TexSet {
        var rnd = SeededRandom(state: seed)
        let color = draw(size, gray: false) { paint($0, .color, &rnd) }
        var normalImage: UIImage?
        if normal > 0 {
            rnd = SeededRandom(state: seed)
            if let height = draw(size, gray: true, { paint($0, .height, &rnd) }) {
                normalImage = normalMap(pixels(height), size, strength: normal)
            }
        }
        var roughImage: UIImage?
        if roughMap {
            rnd = SeededRandom(state: seed)
            roughImage = draw(size, gray: true) { paint($0, .rough, &rnd) }.map { UIImage(cgImage: $0) }
        }
        let diffuse = color.map { UIImage(cgImage: $0) } ?? UIImage()
        return TexSet(diffuse: diffuse, normal: normalImage, rough: roughImage, meters: meters)
    }

    /// Цвет заливки для нужного прохода
    static func fill(_ g: CGContext, _ pass: Pass, color: UIColor, height: CGFloat, rough: CGFloat, alpha: CGFloat = 1) {
        switch pass {
        case .color: g.setFillColor(color.withAlphaComponent(alpha).cgColor)
        case .height: g.setFillColor(gray: height, alpha: alpha)
        case .rough: g.setFillColor(gray: rough, alpha: alpha)
        }
    }

    static func stroke(_ g: CGContext, _ pass: Pass, color: UIColor, height: CGFloat, rough: CGFloat, alpha: CGFloat = 1) {
        switch pass {
        case .color: g.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        case .height: g.setStrokeColor(gray: height, alpha: alpha)
        case .rough: g.setStrokeColor(gray: rough, alpha: alpha)
        }
    }

    // MARK: Стены

    /// Краска: едва заметная неровность валика
    static func paint(_ hex: String) -> TexSet {
        cached("paint" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 512, meters: 1.5, seed: 11, normal: 1.2, roughMap: false) { g, pass, rnd in
                let side: CGFloat = 512
                fill(g, pass, color: base, height: 0.5, rough: 0.85)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0..<140 {
                    let r = CGFloat.random(in: 20...90, using: &rnd)
                    let x = CGFloat.random(in: 0...side, using: &rnd), y = CGFloat.random(in: 0...side, using: &rnd)
                    let light = Bool.random(using: &rnd)
                    fill(g, pass, color: shade(base, light ? 1.04 : 0.96), height: light ? 0.56 : 0.44, rough: 0.85, alpha: 0.18)
                    g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
                for _ in 0..<6000 {
                    let x = CGFloat.random(in: 0...side, using: &rnd), y = CGFloat.random(in: 0...side, using: &rnd)
                    let v = CGFloat.random(in: 0.3...0.7, using: &rnd)
                    fill(g, pass, color: shade(base, 0.98 + v * 0.04), height: v, rough: 0.85, alpha: 0.5)
                    g.fillEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6))
                }
            }
        }
    }

    /// Обои: рулон 53 см, рисунок чуть выпуклый и глянцевее фона
    static func wallpaper(_ hex: String, pattern: String) -> TexSet {
        cached("wp" + hex + pattern) {
            let base = UIColor(hex: hex)
            let ink = base.luma > 0.5 ? shade(base, 0.82) : shade(base, 1.25)
            let gloss: CGFloat = pattern == "damask" || pattern == "geometric" ? 0.45 : 0.7
            return make(size: 512, meters: 0.53, seed: 21, normal: 2.5, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 512
                fill(g, pass, color: base, height: 0.45, rough: 0.8)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                // волокна бумаги
                for _ in 0..<2500 {
                    let x = CGFloat.random(in: 0...side, using: &rnd), y = CGFloat.random(in: 0...side, using: &rnd)
                    let len = CGFloat.random(in: 2...7, using: &rnd)
                    fill(g, pass, color: shade(base, CGFloat.random(in: 0.95...1.05, using: &rnd)), height: 0.5, rough: 0.8, alpha: 0.35)
                    g.fill(CGRect(x: x, y: y, width: len, height: 1))
                }
                fill(g, pass, color: ink, height: 0.7, rough: gloss)
                stroke(g, pass, color: ink, height: 0.7, rough: gloss)
                switch pattern {
                case "stripes":
                    for i in 0..<8 {
                        let x = CGFloat(i) * 64
                        g.fill(CGRect(x: x, y: 0, width: 26, height: side))
                        g.fill(CGRect(x: x + 38, y: 0, width: 3, height: side))
                    }
                case "geometric":
                    g.setLineWidth(3)
                    for i in -1...4 {
                        for j in -1...4 {
                            let cx = CGFloat(i) * 128 + 64, cy = CGFloat(j) * 128 + 64
                            g.move(to: CGPoint(x: cx, y: cy - 64))
                            g.addLine(to: CGPoint(x: cx + 64, y: cy))
                            g.addLine(to: CGPoint(x: cx, y: cy + 64))
                            g.addLine(to: CGPoint(x: cx - 64, y: cy))
                            g.closePath()
                            g.strokePath()
                            g.fillEllipse(in: CGRect(x: cx - 7, y: cy - 7, width: 14, height: 14))
                        }
                    }
                case "floral":
                    for i in -1...3 {
                        for j in -1...3 {
                            let cx = CGFloat(i) * 170 + (j % 2 == 0 ? 0 : 85) + 60
                            let cy = CGFloat(j) * 170 + 60
                            flower(g, cx, cy, 34)
                            g.saveGState()
                            g.translateBy(x: cx + 40, y: cy + 50)
                            g.rotate(by: 0.7)
                            g.fillEllipse(in: CGRect(x: -8, y: -22, width: 16, height: 44))
                            g.restoreGState()
                        }
                    }
                case "damask":
                    for i in -1...2 {
                        for j in -1...2 {
                            let cx = CGFloat(i) * 256 + (j % 2 == 0 ? 128 : 0)
                            let cy = CGFloat(j) * 256 + 128
                            damask(g, cx, cy)
                        }
                    }
                case "linen":
                    for i in 0..<256 {
                        let y = CGFloat(i) * 2
                        let a = CGFloat.random(in: 0.05...0.25, using: &rnd)
                        fill(g, pass, color: ink, height: 0.6, rough: 0.8, alpha: a)
                        g.fill(CGRect(x: 0, y: y, width: side, height: 1))
                        let b = CGFloat.random(in: 0.05...0.2, using: &rnd)
                        fill(g, pass, color: ink, height: 0.6, rough: 0.8, alpha: b)
                        g.fill(CGRect(x: y, y: 0, width: 1, height: side))
                    }
                default:
                    break
                }
            }
        }
    }

    private static func flower(_ g: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        for k in 0..<6 {
            g.saveGState()
            g.translateBy(x: cx, y: cy)
            g.rotate(by: CGFloat(k) * .pi / 3)
            g.fillEllipse(in: CGRect(x: -r * 0.28, y: -r, width: r * 0.56, height: r))
            g.restoreGState()
        }
        g.fillEllipse(in: CGRect(x: cx - r * 0.22, y: cy - r * 0.22, width: r * 0.44, height: r * 0.44))
    }

    private static func damask(_ g: CGContext, _ cx: CGFloat, _ cy: CGFloat) {
        g.fillEllipse(in: CGRect(x: cx - 18, y: cy - 70, width: 36, height: 140))
        for s in [CGFloat(-1), 1] {
            g.saveGState()
            g.translateBy(x: cx + s * 36, y: cy - 10)
            g.rotate(by: s * 0.5)
            g.fillEllipse(in: CGRect(x: -14, y: -50, width: 28, height: 100))
            g.restoreGState()
            g.setLineWidth(5)
            g.addArc(center: CGPoint(x: cx + s * 60, y: cy + 50), radius: 26, startAngle: 0, endAngle: .pi * 1.5, clockwise: s < 0)
            g.strokePath()
            g.fillEllipse(in: CGRect(x: cx + s * 70 - 8, y: cy - 88, width: 16, height: 16))
        }
        g.fillEllipse(in: CGRect(x: cx - 30, y: cy + 74, width: 60, height: 18))
        g.fillEllipse(in: CGRect(x: cx - 30, y: cy - 92, width: 60, height: 18))
    }

    /// Декоративная штукатурка: мягкие разводы и неравномерный блеск
    static func plaster(_ hex: String) -> TexSet {
        cached("plaster" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 512, meters: 1.2, seed: 31, normal: 2.2, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 512
                fill(g, pass, color: base, height: 0.5, rough: 0.7)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0..<320 {
                    let r = CGFloat.random(in: 18...110, using: &rnd)
                    let x = CGFloat.random(in: -40...(side + 40), using: &rnd)
                    let y = CGFloat.random(in: -40...(side + 40), using: &rnd)
                    let k = CGFloat.random(in: 0.9...1.08, using: &rnd)
                    fill(g, pass, color: shade(base, k), height: 0.5 + (k - 1) * 3, rough: CGFloat.random(in: 0.45...0.85, using: &rnd), alpha: 0.12)
                    g.saveGState()
                    g.translateBy(x: x, y: y)
                    g.rotate(by: CGFloat.random(in: 0...3, using: &rnd))
                    g.fillEllipse(in: CGRect(x: -r, y: -r * 0.45, width: r * 2, height: r * 0.9))
                    g.restoreGState()
                }
            }
        }
    }

    /// Реечные панели: рейка 4 см, паз 1 см
    static func panels(_ hex: String) -> TexSet {
        cached("panels" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 512, meters: 0.64, seed: 41, normal: 5, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 512
                let period = side / 16
                fill(g, pass, color: shade(base, 0.35), height: 0.05, rough: 0.9)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for i in 0..<16 {
                    let x = CGFloat(i) * period
                    let tone = shade(base, CGFloat.random(in: 0.92...1.06, using: &rnd))
                    fill(g, pass, color: tone, height: 0.8, rough: 0.55)
                    g.fill(CGRect(x: x + 1, y: 0, width: period * 0.78, height: side))
                    // волокна по рейке
                    for _ in 0..<6 {
                        let gx = x + CGFloat.random(in: 3...(period * 0.74), using: &rnd)
                        stroke(g, pass, color: shade(tone, 0.85), height: 0.75, rough: 0.6, alpha: 0.35)
                        g.setLineWidth(CGFloat.random(in: 0.6...1.6, using: &rnd))
                        g.move(to: CGPoint(x: gx, y: 0))
                        g.addLine(to: CGPoint(x: gx + CGFloat.random(in: -2...2, using: &rnd), y: side))
                        g.strokePath()
                    }
                }
            }
        }
    }

    /// Плитка «кабанчик» 20×10 см с затиркой
    static func wallTile(_ hex: String) -> TexSet {
        cached("wtile" + hex) {
            let base = UIColor(hex: hex)
            let grout = mix(base, rgb(0.62, 0.62, 0.6), 0.55)
            return make(size: 512, meters: 0.6, seed: 51, normal: 6, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 512
                let tw = side / 3, th = side / 6, seam: CGFloat = 3
                fill(g, pass, color: grout, height: 0.15, rough: 0.9)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for row in 0..<6 {
                    let off: CGFloat = row % 2 == 0 ? 0 : -tw / 2
                    for col in 0...3 {
                        let rect = CGRect(x: off + CGFloat(col) * tw + seam / 2, y: CGFloat(row) * th + seam / 2,
                                          width: tw - seam, height: th - seam)
                        fill(g, pass, color: shade(base, CGFloat.random(in: 0.96...1.03, using: &rnd)), height: 0.75, rough: 0.12)
                        g.fill(rect)
                        // скруглённый край глазури
                        fill(g, pass, color: .white, height: 0.85, rough: 0.08, alpha: pass == .color ? 0.08 : 1)
                        g.fill(rect.insetBy(dx: 4, dy: 4))
                    }
                }
            }
        }
    }

    /// Кирпич: картинка 1 × 1 м
    static func brick(_ hex: String) -> TexSet {
        cached("brick" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 512, meters: 1.0, seed: 99, normal: 5, roughMap: false) { g, pass, rnd in
                let side: CGFloat = 512
                let rows = 12
                let rowH = side / CGFloat(rows)
                let brickW = side / 4
                let mortar: CGFloat = 6
                fill(g, pass, color: rgb(0.76, 0.73, 0.68), height: 0.15, rough: 0.95)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for row in 0..<rows {
                    let y = CGFloat(row) * rowH
                    let offset: CGFloat = row % 2 == 0 ? 0 : -brickW / 2
                    for col in 0...4 {
                        let x = offset + CGFloat(col) * brickW
                        let k = CGFloat.random(in: 0.78...1.12, using: &rnd)
                        fill(g, pass, color: shade(base, k), height: 0.7, rough: 0.85)
                        let rect = CGRect(x: x + mortar / 2, y: y + mortar / 2, width: brickW - mortar, height: rowH - mortar)
                        g.fill(rect)
                        for _ in 0..<10 {
                            let px = rect.minX + CGFloat.random(in: 0...rect.width, using: &rnd)
                            let py = rect.minY + CGFloat.random(in: 0...rect.height, using: &rnd)
                            let s = CGFloat.random(in: 2...9, using: &rnd)
                            fill(g, pass, color: .black, height: 0.55, rough: 0.9, alpha: pass == .color ? 0.1 : 0.8)
                            g.fillEllipse(in: CGRect(x: px, y: py, width: s, height: s))
                        }
                    }
                }
            }
        }
    }

    // MARK: Пол

    /// Ламинат: доски 20 см, длина 1–1,4 м, фаска между досками
    static func laminate(_ hex: String) -> TexSet {
        cached("lam" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 1024, meters: 2.4, seed: 61, normal: 3, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 1024
                let rows = 12
                let rowH = side / CGFloat(rows)
                for row in 0..<rows {
                    let y = CGFloat(row) * rowH
                    var x = -CGFloat.random(in: 0...400, using: &rnd)
                    while x < side {
                        let len = CGFloat.random(in: 427...597, using: &rnd)
                        let tone = shade(base, CGFloat.random(in: 0.86...1.1, using: &rnd))
                        plank(g, pass, CGRect(x: x, y: y, width: len, height: rowH), tone, &rnd)
                        x += len
                    }
                    // строка переходит через край картинки
                    fill(g, pass, color: .black, height: 0.1, rough: 0.8, alpha: pass == .color ? 0.35 : 1)
                    g.fill(CGRect(x: 0, y: y, width: side, height: 2))
                }
            }
        }
    }

    /// Паркет ёлочкой: планка 8 × 32 см
    static func parquet(_ hex: String) -> TexSet {
        cached("parq" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 1024, meters: 2.72, seed: 71, normal: 3, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 1024
                let ns = 24, nc = 6
                let step = side / CGFloat(ns)          // шаг по вертикали
                let colW = side / CGFloat(nc * 2)      // шаг колонок
                let w = step / CGFloat(2).squareRoot()
                let l = colW * CGFloat(2).squareRoot()
                fill(g, pass, color: shade(base, 0.6), height: 0.1, rough: 0.8)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for c in -1...(nc * 2 + 1) {
                    for k in -2...(ns + 2) {
                        let cx = CGFloat(c) * colW
                        let cy = CGFloat(k) * step + (c % 2 == 0 ? 0 : step / 2)
                        g.saveGState()
                        g.translateBy(x: cx, y: cy)
                        g.rotate(by: c % 2 == 0 ? CGFloat.pi / 4 : -CGFloat.pi / 4)
                        let tone = shade(base, CGFloat.random(in: 0.86...1.1, using: &rnd))
                        plank(g, pass, CGRect(x: -l / 2, y: -w / 2, width: l, height: w), tone, &rnd)
                        g.restoreGState()
                    }
                }
            }
        }
    }

    /// Одна доска: тон, волокна, тёмная фаска
    private static func plank(_ g: CGContext, _ pass: Pass, _ rect: CGRect, _ tone: UIColor, _ rnd: inout SeededRandom) {
        let rough = CGFloat.random(in: 0.38...0.52, using: &rnd)
        fill(g, pass, color: tone, height: 0.7, rough: rough)
        g.fill(rect)
        let lines = max(4, Int(rect.height / 6))
        for _ in 0..<lines {
            let gy = rect.minY + CGFloat.random(in: 2...(max(3, rect.height - 2)), using: &rnd)
            stroke(g, pass, color: shade(tone, 0.72), height: 0.62, rough: rough + 0.05,
                   alpha: CGFloat.random(in: 0.06...0.16, using: &rnd))
            g.setLineWidth(CGFloat.random(in: 0.7...2.2, using: &rnd))
            g.move(to: CGPoint(x: rect.minX + 3, y: gy))
            let mid = gy + CGFloat.random(in: -3...3, using: &rnd)
            g.addQuadCurve(to: CGPoint(x: rect.maxX - 3, y: gy + CGFloat.random(in: -1.5...1.5, using: &rnd)),
                           control: CGPoint(x: rect.midX, y: mid))
            g.strokePath()
        }
        if Int.random(in: 0..<5, using: &rnd) == 0 {
            // сучок
            let kx = rect.minX + CGFloat.random(in: 10...max(11, rect.width - 10), using: &rnd)
            fill(g, pass, color: shade(tone, 0.6), height: 0.6, rough: rough, alpha: 0.35)
            g.fillEllipse(in: CGRect(x: kx, y: rect.midY - 3, width: 12, height: 6))
        }
        stroke(g, pass, color: .black, height: 0.1, rough: 0.8, alpha: pass == .color ? 0.35 : 1)
        g.setLineWidth(2)
        g.stroke(rect)
    }

    /// Керамогранит 60×60 см
    static func floorTile(_ hex: String) -> TexSet {
        cached("ftile" + hex) {
            let base = UIColor(hex: hex)
            let grout = mix(base, rgb(0.5, 0.5, 0.48), 0.45)
            return make(size: 1024, meters: 1.2, seed: 81, normal: 4, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 1024
                let t = side / 2, seam: CGFloat = 4
                fill(g, pass, color: grout, height: 0.2, rough: 0.9)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for i in 0..<2 {
                    for j in 0..<2 {
                        let rect = CGRect(x: CGFloat(i) * t + seam / 2, y: CGFloat(j) * t + seam / 2, width: t - seam, height: t - seam)
                        let tone = shade(base, CGFloat.random(in: 0.97...1.03, using: &rnd))
                        fill(g, pass, color: tone, height: 0.8, rough: 0.22)
                        g.fill(rect)
                        g.saveGState()
                        g.clip(to: rect)
                        for _ in 0..<40 {
                            let r = CGFloat.random(in: 20...90, using: &rnd)
                            let x = rect.minX + CGFloat.random(in: 0...rect.width, using: &rnd)
                            let y = rect.minY + CGFloat.random(in: 0...rect.height, using: &rnd)
                            fill(g, pass, color: shade(tone, CGFloat.random(in: 0.95...1.05, using: &rnd)), height: 0.8, rough: 0.25, alpha: 0.12)
                            g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                        }
                        g.restoreGState()
                    }
                }
            }
        }
    }

    /// Под мрамор: плиты 60 см с прожилками, полированные
    static func stone(_ hex: String) -> TexSet {
        cached("stone" + hex) {
            let base = UIColor(hex: hex)
            let vein = base.luma > 0.5 ? shade(base, 0.62) : shade(base, 1.6)
            return make(size: 1024, meters: 1.2, seed: 91, normal: 1.2, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 1024
                let t = side / 2
                fill(g, pass, color: shade(base, 0.8), height: 0.3, rough: 0.5)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for i in 0..<2 {
                    for j in 0..<2 {
                        let rect = CGRect(x: CGFloat(i) * t + 1, y: CGFloat(j) * t + 1, width: t - 2, height: t - 2)
                        fill(g, pass, color: base, height: 0.8, rough: 0.1)
                        g.fill(rect)
                        g.saveGState()
                        g.clip(to: rect)
                        for _ in 0..<60 {
                            let r = CGFloat.random(in: 30...140, using: &rnd)
                            let x = rect.minX + CGFloat.random(in: 0...rect.width, using: &rnd)
                            let y = rect.minY + CGFloat.random(in: 0...rect.height, using: &rnd)
                            fill(g, pass, color: shade(base, CGFloat.random(in: 0.94...1.05, using: &rnd)), height: 0.8, rough: 0.12, alpha: 0.1)
                            g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                        }
                        for _ in 0..<9 {
                            stroke(g, pass, color: vein, height: 0.75, rough: 0.18, alpha: CGFloat.random(in: 0.15...0.4, using: &rnd))
                            g.setLineWidth(CGFloat.random(in: 0.8...3.5, using: &rnd))
                            var p = CGPoint(x: rect.minX + CGFloat.random(in: 0...rect.width, using: &rnd), y: rect.minY)
                            g.move(to: p)
                            for _ in 0..<5 {
                                let q = CGPoint(x: p.x + CGFloat.random(in: -90...90, using: &rnd), y: p.y + rect.height / 5)
                                g.addQuadCurve(to: q, control: CGPoint(x: (p.x + q.x) / 2 + CGFloat.random(in: -50...50, using: &rnd),
                                                                        y: (p.y + q.y) / 2))
                                p = q
                            }
                            g.strokePath()
                        }
                        g.restoreGState()
                    }
                }
            }
        }
    }

    /// Ковролин: густой ворс
    static func carpet(_ hex: String) -> TexSet {
        cached("carpet" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 512, meters: 0.5, seed: 101, normal: 2, roughMap: false) { g, pass, rnd in
                let side: CGFloat = 512
                fill(g, pass, color: base, height: 0.5, rough: 1)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0..<22000 {
                    let x = CGFloat.random(in: 0...side, using: &rnd), y = CGFloat.random(in: 0...side, using: &rnd)
                    let v = CGFloat.random(in: 0.2...0.8, using: &rnd)
                    fill(g, pass, color: shade(base, 0.85 + v * 0.3), height: v, rough: 1, alpha: 0.6)
                    g.fillEllipse(in: CGRect(x: x, y: y, width: 2.2, height: 2.2))
                }
            }
        }
    }

    /// Микроцемент / бетон
    static func concrete(_ hex: String) -> TexSet {
        cached("concrete" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 512, meters: 2, seed: 7, normal: 1.5, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 512
                fill(g, pass, color: base, height: 0.5, rough: 0.7)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0..<260 {
                    let r = CGFloat.random(in: 10...60, using: &rnd)
                    let x = CGFloat.random(in: 0...side, using: &rnd), y = CGFloat.random(in: 0...side, using: &rnd)
                    let light = Bool.random(using: &rnd)
                    fill(g, pass, color: light ? .white : .black, height: light ? 0.6 : 0.4,
                         rough: CGFloat.random(in: 0.5...0.85, using: &rnd), alpha: CGFloat.random(in: 0.03...0.08, using: &rnd))
                    g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
                for _ in 0..<5000 {
                    let x = CGFloat.random(in: 0...side, using: &rnd), y = CGFloat.random(in: 0...side, using: &rnd)
                    let light = Bool.random(using: &rnd)
                    fill(g, pass, color: light ? .white : .black, height: light ? 0.62 : 0.38, rough: 0.75,
                         alpha: CGFloat.random(in: 0.05...0.18, using: &rnd))
                    g.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
                }
            }
        }
    }

    // MARK: Мебель

    /// Дерево для мебели: волокна вдоль
    static func wood(_ hex: String) -> TexSet {
        cached("wood" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 512, meters: 1, seed: 111, normal: 1, roughMap: false) { g, pass, rnd in
                let side: CGFloat = 512
                fill(g, pass, color: base, height: 0.5, rough: 0.5)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0..<14 {
                    let y = CGFloat.random(in: 0...side, using: &rnd)
                    let h = CGFloat.random(in: 10...50, using: &rnd)
                    fill(g, pass, color: shade(base, CGFloat.random(in: 0.9...1.08, using: &rnd)), height: 0.5, rough: 0.5, alpha: 0.4)
                    g.fill(CGRect(x: 0, y: y, width: side, height: h))
                }
                for _ in 0..<90 {
                    let y = CGFloat.random(in: 0...side, using: &rnd)
                    stroke(g, pass, color: shade(base, 0.7), height: 0.42, rough: 0.55, alpha: CGFloat.random(in: 0.05...0.18, using: &rnd))
                    g.setLineWidth(CGFloat.random(in: 0.6...2, using: &rnd))
                    g.move(to: CGPoint(x: 0, y: y))
                    g.addCurve(to: CGPoint(x: side, y: y + CGFloat.random(in: -4...4, using: &rnd)),
                               control1: CGPoint(x: side / 3, y: y + CGFloat.random(in: -8...8, using: &rnd)),
                               control2: CGPoint(x: side * 2 / 3, y: y + CGFloat.random(in: -8...8, using: &rnd)))
                    g.strokePath()
                }
            }
        }
    }

    /// Ткань: переплетение нитей и узелки
    static func fabric(_ hex: String) -> TexSet {
        cached("fabric" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 256, meters: 0.2, seed: 121, normal: 2.5, roughMap: false) { g, pass, rnd in
                let side: CGFloat = 256
                fill(g, pass, color: shade(base, 0.92), height: 0.3, rough: 0.95)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for i in 0..<64 {
                    let p = CGFloat(i) * 4
                    fill(g, pass, color: shade(base, CGFloat.random(in: 0.97...1.06, using: &rnd)), height: 0.7, rough: 0.95, alpha: 0.8)
                    g.fill(CGRect(x: 0, y: p, width: side, height: 2))
                    fill(g, pass, color: shade(base, CGFloat.random(in: 0.94...1.03, using: &rnd)), height: 0.6, rough: 0.95, alpha: 0.55)
                    g.fill(CGRect(x: p + 2, y: 0, width: 2, height: side))
                }
                for _ in 0..<120 {
                    let x = CGFloat.random(in: 0...side, using: &rnd), y = CGFloat.random(in: 0...side, using: &rnd)
                    fill(g, pass, color: shade(base, 1.08), height: 0.9, rough: 0.95, alpha: 0.5)
                    g.fillEllipse(in: CGRect(x: x, y: y, width: CGFloat.random(in: 3...9, using: &rnd), height: 2))
                }
            }
        }
    }

    /// Кожа: мелкая зернистость и неровный блеск
    static func leather(_ hex: String) -> TexSet {
        cached("leather" + hex) {
            let base = UIColor(hex: hex)
            return make(size: 256, meters: 0.3, seed: 131, normal: 2, roughMap: true) { g, pass, rnd in
                let side: CGFloat = 256
                fill(g, pass, color: base, height: 0.5, rough: 0.45)
                g.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0..<1800 {
                    let x = CGFloat.random(in: 0...side, using: &rnd), y = CGFloat.random(in: 0...side, using: &rnd)
                    let s = CGFloat.random(in: 2...6, using: &rnd)
                    let k = CGFloat.random(in: 0.88...1.1, using: &rnd)
                    fill(g, pass, color: shade(base, k), height: 0.5 + (k - 1) * 2, rough: 0.35 + (1.1 - k), alpha: 0.5)
                    g.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s * 0.8))
                }
            }
        }
    }

    // MARK: Свет и вид из окна

    /// Свет окружения (карта-панорама): светлый потолок, окна, тёплый пол
    static func environment() -> UIImage {
        let size = CGSize(width: 1024, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            let colors = [rgb(0.96, 0.97, 0.99).cgColor, rgb(0.90, 0.89, 0.87).cgColor,
                          rgb(0.78, 0.74, 0.69).cgColor, rgb(0.45, 0.39, 0.33).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                         locations: [0, 0.45, 0.55, 1]) {
                g.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            // два окна — дают живые блики на глянце
            g.setFillColor(UIColor.white.cgColor)
            g.fill(CGRect(x: 180, y: 170, width: 120, height: 130))
            g.fill(CGRect(x: 640, y: 175, width: 90, height: 120))
            g.setFillColor(rgb(1.0, 0.92, 0.8).withAlphaComponent(0.6).cgColor)
            g.fillEllipse(in: CGRect(x: 470, y: 30, width: 70, height: 50))
        }
    }

    /// Вид за окном: небо, облака, деревья и дома вдали
    static func outdoor() -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var rnd = SeededRandom(state: 5)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            let sky = [rgb(0.52, 0.70, 0.92).cgColor, rgb(0.80, 0.88, 0.96).cgColor, rgb(0.93, 0.95, 0.97).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sky as CFArray, locations: [0, 0.55, 1]) {
                g.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            for _ in 0..<14 {
                let x = CGFloat.random(in: -40...size.width, using: &rnd), y = CGFloat.random(in: 20...200, using: &rnd)
                g.setFillColor(UIColor.white.withAlphaComponent(0.35).cgColor)
                g.fillEllipse(in: CGRect(x: x, y: y, width: CGFloat.random(in: 60...160, using: &rnd), height: CGFloat.random(in: 18...40, using: &rnd)))
            }
            // дома вдали
            var x: CGFloat = -10
            while x < size.width {
                let w = CGFloat.random(in: 40...90, using: &rnd), h = CGFloat.random(in: 60...190, using: &rnd)
                g.setFillColor(rgb(0.78, 0.80, 0.84).cgColor)
                g.fill(CGRect(x: x, y: 380 - h, width: w, height: h + 40))
                g.setFillColor(rgb(0.88, 0.90, 0.93).cgColor)
                var wy = 380 - h + 10
                while wy < 370 {
                    var wx = x + 6
                    while wx < x + w - 8 { g.fill(CGRect(x: wx, y: wy, width: 6, height: 8)); wx += 12 }
                    wy += 16
                }
                x += w + CGFloat.random(in: 4...20, using: &rnd)
            }
            // деревья
            for _ in 0..<26 {
                let cx = CGFloat.random(in: -20...(size.width + 20), using: &rnd), cy = CGFloat.random(in: 360...460, using: &rnd)
                let r = CGFloat.random(in: 30...70, using: &rnd)
                g.setFillColor(mix(rgb(0.36, 0.52, 0.30), rgb(0.55, 0.66, 0.40), CGFloat.random(in: 0...1, using: &rnd)).cgColor)
                g.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 1.8))
            }
            g.setFillColor(rgb(0.45, 0.55, 0.36).cgColor)
            g.fill(CGRect(x: 0, y: 460, width: size.width, height: 52))
        }
    }
}

// MARK: - Материалы

enum Mat {
    /// Материал держит свои текстуры: предел по их памяти, простые цвета почти ничего не весят
    private static let cache = MemoryCache<SCNMaterial>(limit: 64 << 20)

    private static func cached(_ key: String, _ make: () -> SCNMaterial) -> SCNMaterial {
        if let m = cache.get(key) { return m }
        let m = make()
        let maps = [m.diffuse, m.normal, m.roughness, m.emission].reduce(0) { $0 + imageBytes($1.contents as? UIImage) }
        cache.set(key, m, cost: maps + 1024)
        return m
    }

    static func purge() { cache.removeAll() }

    /// PBR-материал из набора карт. uvMeters: у геометрии текстурные координаты в метрах.
    static func textured(_ t: TexSet, rough: CGFloat, metal: CGFloat = 0, uvMeters: Bool, repeats: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = t.diffuse
        if let n = t.normal { m.normal.contents = n }
        if let map = t.rough {
            m.roughness.contents = map
        } else {
            m.roughness.contents = NSNumber(value: Double(rough))
        }
        m.metalness.contents = NSNumber(value: Double(metal))
        let k = uvMeters ? Float(1 / t.meters) : Float(repeats)
        for p in [m.diffuse, m.normal, m.roughness] {
            p.wrapS = .repeat
            p.wrapT = .repeat
            p.mipFilter = .linear
            p.maxAnisotropy = 8
            p.contentsTransform = SCNMatrix4MakeScale(k, k, 1)
        }
        return m
    }

    static func flat(_ color: UIColor, rough: CGFloat, metal: CGFloat = 0) -> SCNMaterial {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = String(format: "flat%.3f%.3f%.3f-%.2f-%.2f", r, g, b, rough, metal)
        return cached(key) {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.roughness.contents = NSNumber(value: Double(rough))
            m.metalness.contents = NSNumber(value: Double(metal))
            return m
        }
    }

    /// Стена: отделка по ключам из Look
    static func wall(_ finish: String, _ hex: String, _ pattern: String) -> SCNMaterial {
        cached("wall" + finish + hex + pattern) {
            switch finish {
            case "wallpaper": return textured(Tex.wallpaper(hex, pattern: pattern), rough: 0.7, uvMeters: true)
            case "plaster": return textured(Tex.plaster(hex), rough: 0.6, uvMeters: true)
            case "panels": return textured(Tex.panels(hex), rough: 0.55, uvMeters: true)
            case "tile": return textured(Tex.wallTile(hex), rough: 0.15, uvMeters: true)
            case "brick": return textured(Tex.brick(hex), rough: 0.9, uvMeters: true)
            default: return textured(Tex.paint(hex), rough: 0.88, uvMeters: true)
            }
        }
    }

    static func floor(_ finish: String, _ hex: String) -> SCNMaterial {
        cached("floor" + finish + hex) {
            switch finish {
            case "parquet": return textured(Tex.parquet(hex), rough: 0.45, uvMeters: true)
            case "tile": return textured(Tex.floorTile(hex), rough: 0.25, uvMeters: true)
            case "stone": return textured(Tex.stone(hex), rough: 0.12, uvMeters: true)
            case "carpet": return textured(Tex.carpet(hex), rough: 1, uvMeters: true)
            case "concrete": return textured(Tex.concrete(hex), rough: 0.7, uvMeters: true)
            default: return textured(Tex.laminate(hex), rough: 0.45, uvMeters: true)
            }
        }
    }

    static func fabric(_ hex: String) -> SCNMaterial {
        cached("fabric" + hex) { textured(Tex.fabric(hex), rough: 0.95, uvMeters: false, repeats: 5) }
    }

    static func leather(_ hex: String) -> SCNMaterial {
        cached("leather" + hex) { textured(Tex.leather(hex), rough: 0.45, uvMeters: false, repeats: 3) }
    }

    /// Дерево; белое и чёрное — матовый лак без волокон
    static func wood(_ hex: String) -> SCNMaterial {
        let color = UIColor(hex: hex)
        if color.luma > 0.82 || color.luma < 0.1 { return flat(color, rough: 0.35) }
        return cached("wood" + hex) { textured(Tex.wood(hex), rough: 0.5, uvMeters: false, repeats: 1) }
    }

    static func metal(_ color: UIColor, rough: CGFloat = 0.3) -> SCNMaterial { flat(color, rough: rough, metal: 1) }
    static var chrome: SCNMaterial { flat(rgb(0.92, 0.92, 0.93), rough: 0.08, metal: 1) }
    static var ceramic: SCNMaterial { flat(rgb(0.97, 0.97, 0.96), rough: 0.06) }

    static func ceramic(_ hex: String) -> SCNMaterial { flat(UIColor(hex: hex), rough: 0.06) }

    static var glass: SCNMaterial {
        cached("glass") {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = rgb(0.86, 0.92, 0.95)
            m.roughness.contents = NSNumber(value: 0.03)
            m.metalness.contents = NSNumber(value: 0.0)
            m.transparency = 0.16
            m.blendMode = .alpha
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            return m
        }
    }

    /// Тюль: полупрозрачная белая ткань
    static var sheer: SCNMaterial {
        cached("sheer") {
            let m = textured(Tex.fabric("#f7f6f2"), rough: 0.95, uvMeters: false, repeats: 8)
            m.transparency = 0.55
            m.blendMode = .alpha
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            return m
        }
    }

    static var mirror: SCNMaterial { flat(rgb(0.95, 0.96, 0.97), rough: 0.02, metal: 1) }
    static var screen: SCNMaterial { flat(rgb(0.02, 0.02, 0.025), rough: 0.05) }

    /// Светится сам (лампы, огонь). intensity > 1 — «пересвет», как на фото.
    static func glow(_ color: UIColor, _ intensity: CGFloat = 2.5) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor.black
        m.emission.contents = color
        m.emission.intensity = intensity
        m.roughness.contents = NSNumber(value: 0.5)
        return m
    }

    /// Вид за окном: яркий, как настоящее окно на фото интерьера
    static var outdoor: SCNMaterial {
        cached("outdoor") {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.black
            m.emission.contents = Tex.outdoor()
            m.emission.intensity = 1.6
            return m
        }
    }

    /// Ничего не рисует (открытая сторона коробки)
    static var invisible: SCNMaterial {
        cached("invisible") {
            let m = SCNMaterial()
            m.colorBufferWriteMask = []
            m.writesToDepthBuffer = false
            return m
        }
    }

    /// Подсветка выбранного предмета
    static var selection: SCNMaterial {
        cached("selection") {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor(red: 0.96, green: 0.77, blue: 0.09, alpha: 1)
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            return m
        }
    }

    /// Заранее рисует текстуры ремонта (в фоне, чтобы экран не подвисал)
    static func prewarm(_ look: Look) {
        let pal = look.palette
        switch look.wall.finish {
        case "wallpaper": _ = Tex.wallpaper(look.wall.color, pattern: look.wall.pattern)
        case "plaster": _ = Tex.plaster(look.wall.color)
        case "panels": _ = Tex.panels(look.wall.color)
        case "tile": _ = Tex.wallTile(look.wall.color)
        case "brick": _ = Tex.brick(look.wall.color)
        default: _ = Tex.paint(look.wall.color)
        }
        switch look.floor.finish {
        case "parquet": _ = Tex.parquet(look.floor.color)
        case "tile": _ = Tex.floorTile(look.floor.color)
        case "stone": _ = Tex.stone(look.floor.color)
        case "carpet": _ = Tex.carpet(look.floor.color)
        case "concrete": _ = Tex.concrete(look.floor.color)
        default: _ = Tex.laminate(look.floor.color)
        }
        _ = Tex.fabric(pal.fabric)
        _ = Tex.fabric(pal.accent)
        _ = Tex.wood(pal.wood)
        _ = Tex.paint(look.ceiling.color)
    }
}
