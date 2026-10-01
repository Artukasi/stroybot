import SceneKit
import UIKit
import simd

/// Строитель предметов из простых форм. Начало — центр низа предмета, перёд смотрит в +z.
struct Kit {
    let node: SCNNode

    init(_ node: SCNNode = SCNNode()) { self.node = node }

    /// Брусок со скруглёнными рёбрами. y — низ детали от пола.
    @discardableResult
    func box(_ w: Float, _ h: Float, _ d: Float, _ m: SCNMaterial,
             x: Float = 0, y: Float, z: Float = 0, r: Float = 0) -> SCNNode {
        let w = max(w, 0.004), h = max(h, 0.004), d = max(d, 0.004)
        let chamfer = max(0, min(r, min(w, h, d) / 2 - 0.001))
        let geo = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: CGFloat(chamfer))
        geo.materials = [m]
        let n = SCNNode(geometry: geo)
        n.position = SCNVector3(x, y + h / 2, z)
        node.addChildNode(n)
        return n
    }

    /// Вертикальный цилиндр. y — низ.
    @discardableResult
    func cyl(_ radius: Float, _ h: Float, _ m: SCNMaterial, x: Float = 0, y: Float, z: Float = 0) -> SCNNode {
        let geo = SCNCylinder(radius: CGFloat(max(radius, 0.002)), height: CGFloat(max(h, 0.002)))
        geo.radialSegmentCount = 32
        geo.materials = [m]
        let n = SCNNode(geometry: geo)
        n.position = SCNVector3(x, y + h / 2, z)
        node.addChildNode(n)
        return n
    }

    /// Шар. y — центр.
    @discardableResult
    func ball(_ r: Float, _ m: SCNMaterial, x: Float = 0, y: Float, z: Float = 0) -> SCNNode {
        let geo = SCNSphere(radius: CGFloat(max(r, 0.002)))
        geo.segmentCount = 24
        geo.materials = [m]
        let n = SCNNode(geometry: geo)
        n.position = SCNVector3(x, y, z)
        node.addChildNode(n)
        return n
    }

    /// Кольцо в горизонтальной плоскости. y — центр.
    @discardableResult
    func ring(_ radius: Float, _ pipe: Float, _ m: SCNMaterial, x: Float = 0, y: Float, z: Float = 0) -> SCNNode {
        let geo = SCNTorus(ringRadius: CGFloat(max(radius, 0.005)), pipeRadius: CGFloat(max(pipe, 0.001)))
        geo.ringSegmentCount = 48
        geo.pipeSegmentCount = 12
        geo.materials = [m]
        let n = SCNNode(geometry: geo)
        n.position = SCNVector3(x, y, z)
        node.addChildNode(n)
        return n
    }

    /// Стержень от точки a до точки b
    @discardableResult
    func rod(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r: Float, _ m: SCNMaterial) -> SCNNode {
        let v = b - a
        let len = simd_length(v)
        let geo = SCNCylinder(radius: CGFloat(max(r, 0.001)), height: CGFloat(max(len, 0.001)))
        geo.radialSegmentCount = 16
        geo.materials = [m]
        let n = SCNNode(geometry: geo)
        n.simdPosition = (a + b) / 2
        if len > 0.0001 {
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: v / len)
        }
        node.addChildNode(n)
        return n
    }

    /// Дочерний строитель со сдвигом
    func sub(x: Float = 0, y: Float = 0, z: Float = 0) -> Kit {
        let k = Kit()
        k.node.position = SCNVector3(x, y, z)
        node.addChildNode(k.node)
        return k
    }
}

extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }
}

/// Материалы одного предмета
struct FurnitureMats {
    /// Обивка или корпус — цвет, выбранный пользователем
    let main: SCNMaterial
    let wood: SCNMaterial
    /// Ножки, ручки, металл
    let legs: SCNMaterial
    /// Подушки, плед
    let accent: SCNMaterial
    /// Мягкое сиденье у стульев
    let soft: SCNMaterial
    let bedding: SCNMaterial
    let duvet: SCNMaterial
    let dark: SCNMaterial

    init(kind: String, variant: String, color: String, palette: Palette3D) {
        if LookOptions.isSoft(kind, variant) {
            main = palette.leather || variant == "chesterfield" ? Mat.leather(color) : Mat.fabric(color)
        } else {
            switch kind {
            case "table", "storage", "chair", "stairs": main = Mat.wood(color)
            case "sink", "toilet", "bathtub", "fireplace": main = Mat.ceramic(color)
            default:
                let c = UIColor(hex: color)
                main = Mat.flat(c, rough: 0.25, metal: c.luma > 0.3 && c.luma < 0.85 ? 0.7 : 0.05)
            }
        }
        wood = Mat.wood(palette.wood)
        legs = Mat.metal(palette.metal, rough: 0.35)
        accent = Mat.fabric(palette.accent)
        soft = Mat.fabric(palette.fabric)
        bedding = Mat.fabric(palette.bedding.hexString)
        duvet = Mat.fabric(mix(palette.bedding, UIColor(hex: palette.fabric), 0.12).hexString)
        dark = Mat.flat(rgb(0.07, 0.07, 0.07), rough: 0.8)
    }
}

enum Furniture3D {
    /// Предмет по виду и варианту, точно в размер (метры)
    static func build(kind: String, variant: String, width w: Float, depth d: Float, height h: Float,
                      color: String, palette: Palette3D, againstWall: Bool) -> SCNNode {
        let k = Kit()
        let w = max(w, 0.1), d = max(d, 0.05), h = max(h, 0.05)
        let m = FurnitureMats(kind: kind, variant: variant, color: color, palette: palette)
        switch kind {
        case "sofa": sofa(k, w, d, h, m, variant)
        case "bed": bed(k, w, d, h, m, variant)
        case "chair": chair(k, w, d, h, m, variant)
        case "table": table(k, w, d, h, m, variant)
        case "storage": storage(k, w, d, h, m, variant, palette)
        case "television": tv(k, w, d, h)
        case "refrigerator": fridge(k, w, d, h, m)
        case "stove", "oven": stove(k, w, d, h, m, oven: kind == "oven")
        case "dishwasher": dishwasher(k, w, d, h, m)
        case "washerDryer": washer(k, w, d, h, m)
        case "sink": sink(k, w, d, h, m, mirror: againstWall)
        case "toilet": toilet(k, w, d, h, m)
        case "bathtub": bathtub(k, w, d, h, m)
        case "fireplace": fireplace(k, w, d, h, m)
        case "stairs": stairs(k, w, d, h, m)
        default: k.box(w, h, d, m.main, y: 0, r: 0.03)
        }
        return k.node
    }

    private static func legs(_ k: Kit, _ spanX: Float, _ spanZ: Float, _ h: Float, _ r: Float, _ m: SCNMaterial, z: Float = 0) {
        for sx in [Float(-1), 1] {
            for sz in [Float(-1), 1] {
                k.cyl(r, h, m, x: sx * spanX / 2, y: 0, z: z + sz * spanZ / 2)
            }
        }
    }

    // MARK: Диваны и кресла

    private static func sofa(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats, _ variant: String) {
        switch variant {
        case "corner" where d > 1.2:
            // угловой: основная часть у стены и оттоманка справа
            let mainD = min(max(d * 0.55, 0.85), 1.0)
            let chaiseW = min(0.95, w * 0.42)
            let len = d - mainD
            sofaBody(k.sub(z: -d / 2 + mainD / 2), w, mainD, h, m, left: true, right: false, back: true, pillows: true)
            sofaBody(k.sub(x: w / 2 - chaiseW / 2, z: -d / 2 + mainD + len / 2), chaiseW, len, h, m,
                     left: false, right: true, back: false, pillows: false)
        case "chesterfield":
            chesterfield(k, w, d, h, m)
        case "modular":
            sofaBody(k, w, d, min(h, 0.78), m, left: false, right: false, back: true, pillows: true, low: true)
        default:
            sofaBody(k, w, d, h, m, left: true, right: true, back: true, pillows: w > 1.3)
        }
    }

    private static func sofaBody(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats,
                                 left: Bool, right: Bool, back: Bool, pillows: Bool, low: Bool = false) {
        let legH: Float = low ? 0.04 : 0.1
        let seatTop = min(max(h * 0.5, 0.36), 0.45)
        let arm = min(max(w * 0.08, 0.1), 0.2)
        let backD: Float = back ? min(max(d * 0.22, 0.14), 0.26) : 0
        let cushionH: Float = low ? 0.18 : 0.14
        let baseTop = seatTop - cushionH
        if low {
            k.box(w - 0.06, legH, d - 0.06, m.dark, y: 0)
        } else {
            legs(k, w - 0.14, d - 0.14, legH, 0.018, m.legs)
        }
        k.box(w, baseTop - legH, d, m.main, y: legH, r: 0.02)
        let backTop = max(h, seatTop + 0.28)
        let x0 = left ? -w / 2 + arm : -w / 2
        let x1 = right ? w / 2 - arm : w / 2
        let inner = x1 - x0
        if back {
            k.box(inner, backTop - baseTop, backD, m.main, x: (x0 + x1) / 2, y: baseTop, z: -d / 2 + backD / 2, r: 0.03)
        }
        let armTop = min(backTop - 0.06, seatTop + 0.2)
        let armR = min(arm / 2 - 0.002, 0.07)
        if left { k.box(arm, armTop - legH, d, m.main, x: -w / 2 + arm / 2, y: legH, r: armR) }
        if right { k.box(arm, armTop - legH, d, m.main, x: w / 2 - arm / 2, y: legH, r: armR) }
        let n = max(1, min(4, Int((inner / 0.7).rounded())))
        let cw = inner / Float(n)
        let seatD = d - backD - 0.02
        for i in 0..<n {
            let x = x0 + cw * (Float(i) + 0.5)
            k.box(cw - 0.012, cushionH, seatD, m.main, x: x, y: baseTop, z: d / 2 - seatD / 2 - 0.01, r: 0.05)
            if back {
                let bh = max(0.2, backTop - seatTop - 0.02)
                let c = k.box(cw - 0.015, bh, 0.16, m.main, x: x, y: seatTop - 0.01, z: -d / 2 + backD + 0.07, r: 0.06)
                c.eulerAngles.x = -0.12
            }
        }
        if pillows && back && inner > 1.0 {
            for s in [Float(-1), 1] {
                let p = k.box(0.42, 0.4, 0.13, m.accent, x: (x0 + x1) / 2 + s * (inner / 2 - 0.3), y: seatTop - 0.02,
                              z: -d / 2 + backD + 0.2, r: 0.06)
                p.eulerAngles = SCNVector3(-0.25, 0, s * 0.08)
            }
        }
    }

    private static func chesterfield(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats) {
        let legH: Float = 0.08
        let seatTop = min(max(h * 0.58, 0.4), 0.46)
        let top = max(h, 0.7)
        let arm = min(max(w * 0.09, 0.14), 0.22)
        let backD = min(max(d * 0.24, 0.18), 0.28)
        for sx in [Float(-1), 1] {
            for sz in [Float(-1), 1] {
                k.ball(0.04, m.wood, x: sx * (w / 2 - 0.08), y: 0.04, z: sz * (d / 2 - 0.08))
            }
        }
        k.box(w, seatTop - 0.12 - legH, d, m.main, y: legH, r: 0.03)
        k.box(w, top - legH, backD, m.main, y: legH, z: -d / 2 + backD / 2, r: 0.05)
        for s in [Float(-1), 1] {
            let x = s * (w / 2 - arm / 2)
            k.box(arm, top - 0.06 - legH, d, m.main, x: x, y: legH, r: 0.05)
            // валик сверху подлокотника
            k.rod(SIMD3(x, top - 0.05, -d / 2 + 0.05), SIMD3(x, top - 0.05, d / 2 - 0.02), arm * 0.62, m.main)
        }
        let inner = w - 2 * arm
        let n = inner > 1.5 ? 3 : 2
        let cw = inner / Float(n)
        let seatD = d - backD - 0.02
        for i in 0..<n {
            k.box(cw - 0.01, 0.12, seatD, m.main, x: -inner / 2 + cw * (Float(i) + 0.5), y: seatTop - 0.12,
                  z: d / 2 - seatD / 2 - 0.01, r: 0.04)
        }
        // каретная стяжка пуговицами
        var y = seatTop + 0.08
        var row = 0
        while y < top - 0.08 {
            var x = -inner / 2 + 0.09 + (row % 2 == 0 ? 0 : 0.09)
            while x < inner / 2 - 0.05 {
                k.ball(0.012, m.dark, x: x, y: y, z: -d / 2 + backD + 0.002)
                x += 0.18
            }
            y += 0.1
            row += 1
        }
    }

    // MARK: Кровать

    private static func bed(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats, _ variant: String) {
        let headD: Float = variant == "upholstered" ? 0.1 : 0.06
        let bodyD = max(d - headD, 0.5)
        let zc = headD / 2
        let frameTop: Float = variant == "platform" ? 0.26 : 0.34
        switch variant {
        case "platform":
            k.box(w - 0.16, 0.08, bodyD - 0.16, m.dark, y: 0, z: zc)
            k.box(w + 0.04, frameTop - 0.08, bodyD + 0.02, m.wood, y: 0.08, z: zc, r: 0.01)
        case "classic":
            k.box(w, 0.2, bodyD, m.wood, y: frameTop - 0.2, z: zc, r: 0.008)
            for s in [Float(-1), 1] {
                k.box(0.07, frameTop, 0.07, m.wood, x: s * (w / 2 - 0.035), y: 0, z: zc + bodyD / 2 - 0.035)
            }
        default:
            legs(k, w - 0.16, bodyD - 0.16, 0.08, 0.02, m.legs, z: zc)
            k.box(w, frameTop - 0.08, bodyD, m.main, y: 0.08, z: zc, r: 0.03)
        }
        let mattressH: Float = 0.22
        let mBottom = frameTop - 0.06
        k.box(w - 0.06, mattressH, bodyD - 0.08, m.bedding, y: mBottom, z: zc, r: 0.06)
        let top = mBottom + mattressH
        // одеяло свисает по бокам, плед в ногах
        let footGap: Float = variant == "classic" ? 0.1 : 0.03
        let duvetD = bodyD * 0.7
        k.box(w + 0.02, 0.27, duvetD, m.duvet, y: top - 0.22, z: d / 2 - duvetD / 2 - footGap, r: 0.06)
        k.box(w + 0.04, 0.035, 0.45, m.accent, y: top + 0.035, z: d / 2 - footGap - 0.3, r: 0.015)
        let count = w > 1.25 ? 2 : 1
        let pw = min(0.68, (w - 0.12) / Float(count) - 0.03)
        for i in 0..<count {
            let x: Float = count == 1 ? 0 : (i == 0 ? -w / 4 : w / 4)
            let p = k.box(pw, 0.15, 0.42, m.bedding, x: x, y: top - 0.02, z: -d / 2 + headD + 0.26, r: 0.07)
            p.eulerAngles.x = -0.35
            let q = k.box(pw * 0.7, 0.34, 0.12, m.accent, x: x, y: top, z: -d / 2 + headD + 0.5, r: 0.05)
            q.eulerAngles.x = -0.3
        }
        // изголовье
        let headTop = max(h, top + (variant == "platform" ? 0.3 : 0.55))
        switch variant {
        case "upholstered":
            let span = w + 0.08
            let n = max(4, Int(span / 0.2))
            let cw = span / Float(n)
            for i in 0..<n {
                k.box(cw - 0.006, headTop - 0.02, headD, m.main, x: -span / 2 + cw * (Float(i) + 0.5), y: 0.02,
                      z: -d / 2 + headD / 2, r: min(cw / 2 - 0.004, 0.045))
            }
        case "classic":
            for s in [Float(-1), 1] {
                let x = s * (w / 2 - 0.02)
                k.cyl(0.04, headTop + 0.05, m.wood, x: x, y: 0, z: -d / 2 + headD / 2)
                k.ball(0.055, m.wood, x: x, y: headTop + 0.1, z: -d / 2 + headD / 2)
                k.cyl(0.035, frameTop + 0.3, m.wood, x: x, y: 0, z: d / 2 - 0.04)
                k.ball(0.045, m.wood, x: x, y: frameTop + 0.34, z: d / 2 - 0.04)
            }
            k.box(w - 0.06, headTop - frameTop, 0.04, m.wood, y: frameTop, z: -d / 2 + headD / 2, r: 0.01)
            k.box(w - 0.3, max(0.1, headTop - frameTop - 0.2), 0.02, m.main, y: frameTop + 0.1, z: -d / 2 + headD / 2 + 0.025, r: 0.01)
            k.box(w - 0.06, 0.3, 0.04, m.wood, y: frameTop - 0.05, z: d / 2 - 0.04, r: 0.01)
        default:
            k.box(w + 0.04, headTop - 0.08, 0.05, m.main, y: 0.08, z: -d / 2 + 0.025, r: 0.02)
        }
    }

    // MARK: Стулья и столы

    private static func chair(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats, _ variant: String) {
        switch variant {
        case "armchair":
            sofaBody(k, w, d, h, m, left: true, right: true, back: true, pillows: false)
        case "stool":
            let r = min(w, d) / 2
            k.cyl(r, 0.04, m.main, y: h - 0.04)
            for i in 0..<4 {
                let a = Float(i) * .pi / 2 + .pi / 4
                k.rod(SIMD3(cos(a) * r * 0.55, h - 0.04, sin(a) * r * 0.55), SIMD3(cos(a) * r * 0.95, 0, sin(a) * r * 0.95), 0.014, m.main)
            }
            k.ring(r * 0.75, 0.007, m.legs, y: h * 0.33)
        default:
            let seatY = min(max(h * 0.52, 0.42), 0.48)
            for sx in [Float(-1), 1] {
                for sz in [Float(-1), 1] {
                    k.rod(SIMD3(sx * (w / 2 - 0.035), seatY - 0.04, sz * (d / 2 - 0.035)),
                          SIMD3(sx * (w / 2 - 0.025), 0, sz * (d / 2 - 0.025)), 0.016, m.main)
                }
            }
            k.box(w, 0.04, d, m.main, y: seatY - 0.04, r: 0.012)
            k.box(w - 0.04, 0.035, d - 0.06, m.soft, y: seatY, z: 0.01, r: 0.015)
            // спинка: стойки и перекладины, чуть назад
            let back = k.sub(z: -d / 2 + 0.03)
            back.node.eulerAngles.x = -0.1
            for s in [Float(-1), 1] {
                back.box(0.03, h - seatY + 0.02, 0.03, m.main, x: s * (w / 2 - 0.03), y: seatY - 0.04, r: 0.008)
            }
            back.box(w - 0.02, 0.13, 0.025, m.main, y: h - 0.15, r: 0.01)
            back.box(w - 0.08, 0.025, 0.02, m.main, y: seatY + 0.14)
        }
    }

    private static func table(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats, _ variant: String) {
        switch variant {
        case "dining_round":
            let r = min(w, d) / 2
            k.cyl(r, 0.035, m.main, y: h - 0.035)
            k.cyl(0.05, h - 0.075, m.main, y: 0.04)
            k.cyl(min(r * 0.55, 0.3), 0.04, m.main, y: 0)
            vase(k, x: 0, y: h, z: 0)
        case "coffee":
            k.box(w, 0.04, d, m.main, y: h - 0.04, r: 0.01)
            k.box(w - 0.08, 0.02, d - 0.08, m.main, y: 0.1)
            legs(k, w - 0.08, d - 0.08, h - 0.04, 0.014, m.legs)
            books(k, x: -w / 4, y: h, z: 0, flat: true, seed: 3)
            k.cyl(0.1, 0.012, Mat.flat(rgb(0.85, 0.83, 0.80), rough: 0.3), x: w / 4, y: h)
        case "desk":
            k.box(w, 0.03, d, m.main, y: h - 0.03, r: 0.006)
            k.box(0.03, h - 0.03, d - 0.04, m.main, x: -w / 2 + 0.03, y: 0)
            let dw = min(0.42, w * 0.35)
            k.box(dw, h - 0.03, d - 0.04, m.main, x: w / 2 - dw / 2, y: 0)
            for i in 0..<3 {
                let fh = (h - 0.06) / 3
                k.box(dw - 0.02, fh - 0.01, 0.015, m.main, x: w / 2 - dw / 2, y: 0.02 + Float(i) * fh, z: d / 2 - 0.012)
                k.box(0.12, 0.012, 0.02, m.legs, x: w / 2 - dw / 2, y: 0.02 + Float(i) * fh + fh * 0.7, z: d / 2 + 0.006)
            }
            k.box(0.34, 0.015, 0.24, Mat.flat(rgb(0.72, 0.73, 0.75), rough: 0.25, metal: 1), x: -w * 0.1, y: h, z: 0)
            books(k, x: -w / 2 + 0.12, y: h, z: -d / 4, flat: false, seed: 9)
        default:
            k.box(w, 0.04, d, m.main, y: h - 0.04, r: 0.006)
            k.box(w - 0.12, 0.08, d - 0.12, m.main, y: h - 0.12)
            for sx in [Float(-1), 1] {
                for sz in [Float(-1), 1] {
                    k.box(0.055, h - 0.04, 0.055, m.main, x: sx * (w / 2 - 0.07), y: 0, z: sz * (d / 2 - 0.07), r: 0.006)
                }
            }
            vase(k, x: 0, y: h, z: 0)
        }
    }

    /// Ваза с веткой зелени
    private static func vase(_ k: Kit, x: Float, y: Float, z: Float) {
        k.cyl(0.055, 0.2, Mat.ceramic("#e9e4da"), x: x, y: y, z: z)
        let leaf = Mat.flat(rgb(0.24, 0.40, 0.22), rough: 0.7)
        for i in 0..<6 {
            let a = Float(i) * 1.05
            k.ball(0.045, leaf, x: x + cos(a) * 0.07, y: y + 0.28 + Float(i % 3) * 0.05, z: z + sin(a) * 0.07)
        }
    }

    /// Стопка или ряд книг
    private static func books(_ k: Kit, x: Float, y: Float, z: Float, flat: Bool, seed: UInt64, width: Float = 0.3) {
        var rnd = SeededRandom(state: seed)
        let colors = ["#7a2e35", "#2f3a4a", "#c9b48a", "#4f6250", "#e9e4da", "#5b5f66", "#a45a3f"]
        if flat {
            var yy = y
            for _ in 0..<3 {
                let c = colors[Int.random(in: 0..<colors.count, using: &rnd)]
                let bw = Float.random(in: 0.2...0.28, using: &rnd), bh = Float.random(in: 0.025...0.045, using: &rnd)
                let b = k.box(bw, bh, 0.17, Mat.flat(UIColor(hex: c), rough: 0.6), x: x, y: yy, z: z)
                b.eulerAngles.y = Float.random(in: -0.2...0.2, using: &rnd)
                yy += bh
            }
            return
        }
        var xx = x - width / 2
        while xx < x + width / 2 {
            let c = colors[Int.random(in: 0..<colors.count, using: &rnd)]
            let bw = Float.random(in: 0.02...0.045, using: &rnd), bh = Float.random(in: 0.18...0.27, using: &rnd)
            k.box(bw, bh, Float.random(in: 0.14...0.2, using: &rnd), Mat.flat(UIColor(hex: c), rough: 0.6), x: xx + bw / 2, y: y, z: z)
            xx += bw + 0.002
        }
    }

    /// Растение в горшке
    private static func plant(_ k: Kit, x: Float, y: Float, z: Float, size: Float) {
        k.cyl(size * 0.35, size * 0.45, Mat.ceramic("#d9d6cf"), x: x, y: y, z: z)
        let leaf = Mat.flat(rgb(0.22, 0.38, 0.20), rough: 0.7)
        for i in 0..<7 {
            let a = Float(i) * 0.9
            let r = size * 0.3
            k.ball(size * 0.28, leaf, x: x + cos(a) * r, y: y + size * (0.6 + Float(i % 3) * 0.18), z: z + sin(a) * r)
        }
    }

    // MARK: Шкафы

    private static func storage(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats, _ variant: String, _ palette: Palette3D) {
        switch variant {
        case "wardrobe":
            k.box(w - 0.04, 0.08, d - 0.04, m.dark, y: 0)
            k.box(w, h - 0.08, d - 0.02, m.main, y: 0.08, z: -0.01)
            let n = max(2, Int((w / 0.5).rounded()))
            let dw = w / Float(n)
            for i in 0..<n {
                let x = -w / 2 + dw * (Float(i) + 0.5)
                k.box(dw - 0.004, h - 0.1, 0.018, m.main, x: x, y: 0.09, z: d / 2 - 0.009)
                // ручки у стыка створок
                let side: Float = i % 2 == 0 ? 1 : -1
                k.box(0.012, 0.28, 0.02, m.legs, x: x + side * (dw / 2 - 0.04), y: h * 0.48, z: d / 2 + 0.01)
            }
            if palette.trim.luma > 0.9 && m.main !== m.wood {
                k.box(w + 0.04, 0.05, d + 0.02, m.main, y: h - 0.05)
            }
        case "shelving":
            for s in [Float(-1), 1] { k.box(0.025, h, d, m.main, x: s * (w / 2 - 0.0125), y: 0) }
            let count = max(3, Int(h / 0.38))
            let step = (h - 0.025) / Float(count)
            for i in 0...count {
                k.box(w - 0.05, 0.025, d, m.main, y: Float(i) * step)
            }
            for i in 0..<count {
                let y = Float(i) * step + 0.025
                switch i % 3 {
                case 0: books(k, x: -w / 6, y: y, z: 0, flat: false, seed: UInt64(20 + i), width: min(0.45, w * 0.5))
                case 1: plant(k, x: w / 4, y: y, z: 0, size: min(0.22, step * 0.6))
                default:
                    k.box(min(0.3, w * 0.3), min(0.18, step * 0.6), d * 0.8, Mat.fabric("#cfc6b6"), x: -w / 4, y: y, r: 0.01)
                    books(k, x: w / 5, y: y, z: 0, flat: true, seed: UInt64(40 + i))
                }
            }
        case "tv_stand":
            legs(k, w - 0.08, d - 0.08, 0.12, 0.014, m.legs)
            k.box(w, h - 0.12, d, m.main, y: 0.12, r: 0.004)
            let n = max(2, Int(w / 0.45))
            let fw = w / Float(n)
            for i in 0..<n {
                k.box(fw - 0.006, h - 0.14, 0.012, m.main, x: -w / 2 + fw * (Float(i) + 0.5), y: 0.13, z: d / 2 + 0.006)
            }
            plant(k, x: w / 2 - 0.15, y: h, z: 0, size: 0.2)
        default:
            // комод
            legs(k, w - 0.08, d - 0.08, 0.1, 0.014, m.legs)
            k.box(w, h - 0.1, d, m.main, y: 0.1, r: 0.004)
            let cols = w > 1.0 ? 2 : 1
            let rows = 3
            let fw = w / Float(cols), fh = (h - 0.12) / Float(rows)
            for c in 0..<cols {
                for r in 0..<rows {
                    let x = -w / 2 + fw * (Float(c) + 0.5)
                    let y = 0.11 + Float(r) * fh
                    k.box(fw - 0.008, fh - 0.008, 0.015, m.main, x: x, y: y, z: d / 2 + 0.007)
                    k.box(min(0.16, fw * 0.3), 0.012, 0.018, m.legs, x: x, y: y + fh * 0.62, z: d / 2 + 0.02)
                }
            }
            // лампа на комоде
            k.cyl(0.07, 0.03, m.legs, x: -w / 2 + 0.2, y: h)
            k.cyl(0.012, 0.3, m.legs, x: -w / 2 + 0.2, y: h + 0.03)
            k.cyl(0.13, 0.18, Mat.glow(rgb(1.0, 0.86, 0.66), 0.9), x: -w / 2 + 0.2, y: h + 0.3)
            vase(k, x: w / 2 - 0.2, y: h, z: 0)
        }
    }

    // MARK: Техника

    private static func tv(_ k: Kit, _ w: Float, _ d: Float, _ h: Float) {
        let depth = min(max(d, 0.03), 0.06)
        k.box(w, h, depth, Mat.flat(rgb(0.1, 0.1, 0.11), rough: 0.4), y: 0, r: 0.004)
        k.box(w - 0.014, h - 0.014, 0.002, Mat.screen, y: 0.007, z: depth / 2 + 0.001)
    }

    private static func fridge(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats) {
        k.box(w, h, d - 0.04, m.main, y: 0, z: -0.02, r: 0.02)
        let split = h * 0.62
        let handle = Mat.metal(rgb(0.78, 0.78, 0.8), rough: 0.2)
        k.box(w - 0.006, h - split - 0.006, 0.04, m.main, y: split + 0.003, z: d / 2 - 0.02, r: 0.015)
        k.box(w - 0.006, split - 0.02, 0.04, m.main, y: 0.01, z: d / 2 - 0.02, r: 0.015)
        k.box(0.018, 0.35, 0.03, handle, x: -w / 2 + 0.06, y: split + 0.06, z: d / 2 + 0.015, r: 0.006)
        k.box(0.018, 0.35, 0.03, handle, x: -w / 2 + 0.06, y: split - 0.45, z: d / 2 + 0.015, r: 0.006)
    }

    private static func stove(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats, oven: Bool) {
        let black = Mat.flat(rgb(0.03, 0.03, 0.035), rough: 0.05)
        k.box(w, h - (oven ? 0 : 0.02), d, m.main, y: 0, r: 0.01)
        if !oven {
            k.box(w, 0.02, d, black, y: h - 0.02)
            let burner = Mat.flat(rgb(0.3, 0.3, 0.31), rough: 0.3)
            for sx in [Float(-1), 1] {
                for sz in [Float(-1), 1] {
                    k.ring(sz > 0 ? 0.07 : 0.09, 0.004, burner, x: sx * w / 4, y: h + 0.001, z: sz * d / 4)
                }
            }
            for i in 0..<4 {
                let x = -w * 0.3 + Float(i) * w * 0.2
                k.rod(SIMD3(x, h - 0.08, d / 2), SIMD3(x, h - 0.08, d / 2 + 0.025), 0.016, Mat.metal(rgb(0.7, 0.7, 0.72)))
            }
        }
        let doorH = min(h * 0.5, 0.5)
        k.box(w - 0.06, doorH, 0.02, black, y: oven ? (h - doorH) / 2 : 0.1, z: d / 2 + 0.005, r: 0.006)
        let hy = (oven ? (h - doorH) / 2 : 0.1) + doorH - 0.04
        k.rod(SIMD3(-w / 2 + 0.08, hy, d / 2 + 0.04), SIMD3(w / 2 - 0.08, hy, d / 2 + 0.04), 0.01, Mat.metal(rgb(0.8, 0.8, 0.82), rough: 0.2))
    }

    private static func dishwasher(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats) {
        k.box(w, h, d, m.main, y: 0, r: 0.01)
        k.box(w - 0.02, 0.08, 0.01, Mat.flat(rgb(0.1, 0.1, 0.1), rough: 0.2), y: h - 0.1, z: d / 2 + 0.005)
        k.rod(SIMD3(-w / 2 + 0.1, h - 0.14, d / 2 + 0.03), SIMD3(w / 2 - 0.1, h - 0.14, d / 2 + 0.03), 0.009, Mat.metal(rgb(0.8, 0.8, 0.82)))
    }

    private static func washer(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats) {
        k.box(w, h, d, m.main, y: 0, r: 0.02)
        let r = min(w, h) * 0.3
        let cy = h * 0.48
        let door = k.ring(r, 0.03, Mat.chrome, y: cy, z: d / 2 + 0.01)
        door.eulerAngles.x = .pi / 2
        k.rod(SIMD3(0, cy, d / 2 - 0.01), SIMD3(0, cy, d / 2 + 0.015), r - 0.01, Mat.glass)
        k.box(w - 0.04, 0.1, 0.01, Mat.flat(rgb(0.88, 0.88, 0.9), rough: 0.3), y: h - 0.13, z: d / 2 + 0.004)
        k.rod(SIMD3(w / 3, h - 0.08, d / 2), SIMD3(w / 3, h - 0.08, d / 2 + 0.025), 0.025, Mat.metal(rgb(0.75, 0.75, 0.77)))
    }

    // MARK: Сантехника и камин

    private static func sink(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats, mirror: Bool) {
        let top = max(h, 0.4)
        if h > 0.55 {
            k.box(w, h - 0.03, d - 0.02, m.wood, y: 0, z: -0.01)
            let n = w > 0.7 ? 2 : 1
            let fw = w / Float(n)
            for i in 0..<n {
                let x = -w / 2 + fw * (Float(i) + 0.5)
                k.box(fw - 0.006, h - 0.1, 0.015, m.wood, x: x, y: 0.06, z: d / 2 - 0.01)
                k.box(0.012, 0.14, 0.02, m.legs, x: x + (i == 0 ? fw / 2 - 0.05 : -fw / 2 + 0.05), y: h - 0.25, z: d / 2 + 0.005)
            }
            k.box(w + 0.01, 0.03, d + 0.01, Mat.flat(rgb(0.93, 0.93, 0.91), rough: 0.12), y: h - 0.03)
        } else {
            k.box(w, h, d, m.main, y: 0, r: 0.04)
        }
        // чаша
        let bowl = k.cyl(min(w, d) * 0.32, 0.12, m.main, y: top)
        bowl.scale.z = 0.75
        let inner = k.cyl(min(w, d) * 0.27, 0.004, Mat.flat(rgb(0.86, 0.87, 0.88), rough: 0.05), y: top + 0.117)
        inner.scale.z = 0.75
        // смеситель
        let tapZ = -d / 2 + 0.06
        k.cyl(0.018, 0.22, Mat.chrome, y: top, z: tapZ)
        k.rod(SIMD3(0, top + 0.21, tapZ), SIMD3(0, top + 0.19, tapZ + 0.13), 0.011, Mat.chrome)
        if mirror {
            k.box(min(w, 0.9), 0.8, 0.02, Mat.mirror, y: top + 0.35, z: -d / 2 + 0.01)
        }
    }

    private static func toilet(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats) {
        let r = min(w * 0.48, 0.2)
        let zc = d * 0.08
        let base = k.cyl(r * 0.7, 0.3, m.main, y: 0, z: zc)
        base.scale.z = 1.25
        let bowl = k.cyl(r, 0.1, m.main, y: 0.28, z: zc)
        bowl.scale.z = 1.3
        let seat = k.ring(r * 0.82, 0.026, m.main, y: 0.4, z: zc)
        seat.scale.z = 1.3
        let lid = k.cyl(r * 0.95, 0.018, m.main, y: 0.42, z: zc)
        lid.scale.z = 1.25
        let tankH = max(0.2, h - 0.4)
        k.box(min(w, 0.4), tankH, 0.17, m.main, y: 0.4, z: -d / 2 + 0.085, r: 0.03)
        k.cyl(0.02, 0.01, Mat.chrome, y: 0.4 + tankH, z: -d / 2 + 0.085)
    }

    private static func bathtub(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats) {
        let rim: Float = 0.07
        k.box(w, h, rim, m.main, y: 0, z: -d / 2 + rim / 2, r: 0.02)
        k.box(w, h, rim, m.main, y: 0, z: d / 2 - rim / 2, r: 0.02)
        k.box(rim, h, d - 2 * rim, m.main, x: -w / 2 + rim / 2, y: 0)
        k.box(rim, h, d - 2 * rim, m.main, x: w / 2 - rim / 2, y: 0)
        k.box(w - 2 * rim, 0.12, d - 2 * rim, m.main, y: 0)
        k.rod(SIMD3(-w / 2 + 0.25, h, -d / 2 + 0.03), SIMD3(-w / 2 + 0.25, h + 0.12, -d / 2 + 0.03), 0.015, Mat.chrome)
        k.rod(SIMD3(-w / 2 + 0.25, h + 0.12, -d / 2 + 0.03), SIMD3(-w / 2 + 0.25, h + 0.1, -d / 2 + 0.15), 0.011, Mat.chrome)
    }

    private static func fireplace(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats) {
        let side = w * 0.2
        for s in [Float(-1), 1] { k.box(side, h - 0.08, d, m.main, x: s * (w / 2 - side / 2), y: 0) }
        k.box(w, h * 0.22, d, m.main, y: h * 0.7)
        k.box(w + 0.12, 0.06, d + 0.08, m.main, y: h - 0.08, z: 0.02, r: 0.01)
        let box = w - 2 * side
        k.box(box, h * 0.7, 0.04, Mat.flat(rgb(0.05, 0.05, 0.05), rough: 0.9), y: 0, z: -d / 2 + 0.05)
        k.box(box, 0.02, d - 0.04, Mat.flat(rgb(0.1, 0.1, 0.1), rough: 0.9), y: 0)
        let log = Mat.flat(rgb(0.3, 0.2, 0.13), rough: 0.9)
        k.rod(SIMD3(-box * 0.3, 0.06, 0), SIMD3(box * 0.3, 0.06, 0.05), 0.04, log)
        k.rod(SIMD3(-box * 0.25, 0.1, 0.06), SIMD3(box * 0.2, 0.13, -0.04), 0.035, log)
        let fire = Mat.glow(rgb(1.0, 0.55, 0.18), 3)
        for i in 0..<5 {
            let b = k.ball(0.05, fire, x: -box * 0.2 + Float(i) * box * 0.1, y: 0.16 + Float(i % 2) * 0.04, z: 0.02)
            b.scale = SCNVector3(0.8, 1.6, 0.8)
        }
    }

    private static func stairs(_ k: Kit, _ w: Float, _ d: Float, _ h: Float, _ m: FurnitureMats) {
        let n = max(3, Int((h / 0.17).rounded()))
        let rise = h / Float(n), run = d / Float(n)
        for i in 0..<n {
            k.box(w, rise * Float(i + 1), run, m.main, y: 0, z: d / 2 - run * (Float(i) + 0.5))
        }
    }
}

// MARK: - Светильники на потолке

enum Lamps {
    static func omni(_ intensity: CGFloat, _ temperature: CGFloat, reach: Float) -> SCNLight {
        let l = SCNLight()
        l.type = .omni
        l.intensity = intensity
        l.temperature = temperature
        l.attenuationStartDistance = 0.3
        l.attenuationEndDistance = CGFloat(max(reach, 4))
        l.attenuationFalloffExponent = 1.3
        return l
    }

    static func spot(_ intensity: CGFloat, _ temperature: CGFloat, angle: CGFloat) -> SCNLight {
        let l = SCNLight()
        l.type = .spot
        l.intensity = intensity
        l.temperature = temperature
        l.spotInnerAngle = angle * 0.35
        l.spotOuterAngle = angle
        l.attenuationStartDistance = 0.3
        l.attenuationEndDistance = 7
        l.attenuationFalloffExponent = 1.3
        return l
    }

    /// Светильник выбранного вида. Координаты — мировые (пол на y = 0), свет — не больше 4 источников.
    static func build(_ kind: String, center c: SIMD2<Float>, ceiling top: Float, lo: SIMD2<Float>, hi: SIMD2<Float>,
                      table: (SIMD2<Float>, Float, Float, Float)?, palette: Palette3D,
                      inside: (SIMD2<Float>) -> Bool) -> SCNNode {
        let k = Kit()
        let reach = simd_length(hi - lo) + 1
        let brass = Mat.metal(palette.metal, rough: 0.3)
        let black = Mat.flat(rgb(0.06, 0.06, 0.06), rough: 0.5, metal: 0.3)
        let warm = rgb(1.0, 0.86, 0.66)
        func light(_ l: SCNLight, _ p: SIMD3<Float>, down: Bool) {
            let n = SCNNode()
            n.light = l
            n.simdPosition = p
            if down { n.eulerAngles.x = -.pi / 2 }
            k.node.addChildNode(n)
        }
        switch kind {
        case "chandelier_classic":
            let y0 = top - 0.65
            k.cyl(0.07, 0.03, brass, x: c.x, y: top - 0.03, z: c.y)
            k.rod(SIMD3(c.x, top, c.y), SIMD3(c.x, y0 + 0.1, c.y), 0.008, brass)
            k.ball(0.06, brass, x: c.x, y: y0 + 0.05, z: c.y)
            for i in 0..<6 {
                let a = Float(i) * .pi / 3
                let mid = SIMD3(c.x + cos(a) * 0.3, y0, c.y + sin(a) * 0.3)
                k.rod(SIMD3(c.x, y0 + 0.03, c.y), mid, 0.009, brass)
                k.cyl(0.03, 0.02, brass, x: mid.x, y: mid.y, z: mid.z)
                k.cyl(0.012, 0.08, Mat.flat(rgb(0.97, 0.96, 0.93), rough: 0.4), x: mid.x, y: mid.y + 0.02, z: mid.z)
                k.ball(0.016, Mat.glow(warm, 4), x: mid.x, y: mid.y + 0.115, z: mid.z)
                k.ball(0.012, Mat.glass, x: c.x + cos(a + 0.5) * 0.2, y: y0 - 0.06, z: c.y + sin(a + 0.5) * 0.2)
            }
            light(omni(1100, 2700, reach: reach), SIMD3(c.x, y0 + 0.1, c.y), down: false)
        case "chandelier_modern":
            k.cyl(0.1, 0.03, black, x: c.x, y: top - 0.03, z: c.y)
            let globe = Mat.glow(rgb(1.0, 0.95, 0.86), 1.8)
            for i in 0..<7 {
                let a = Float(i) * 2 * .pi / 6
                let r: Float = i == 6 ? 0 : 0.2
                let p = SIMD2(c.x + cos(a) * r, c.y + sin(a) * r)
                let y = top - 0.45 - Float(i % 3) * 0.12
                k.rod(SIMD3(p.x, top, p.y), SIMD3(p.x, y + 0.09, p.y), 0.003, black)
                k.ball(0.085, globe, x: p.x, y: y, z: p.y)
            }
            light(omni(1100, 3000, reach: reach), SIMD3(c.x, top - 0.5, c.y), down: false)
        case "pendant":
            var spots: [SIMD2<Float>] = [c]
            var shadeY = top - 0.75
            if let t = table {
                // над обеденным столом: вдоль длинной стороны
                let dir = SIMD2(cos(t.3), sin(t.3))
                let long = t.1
                let count = long > 1.5 ? 3 : (long > 1.1 ? 2 : 1)
                spots = (0..<count).map { i in
                    let off = count == 1 ? 0 : (Float(i) / Float(count - 1) - 0.5) * long * 0.6
                    return t.0 + dir * off
                }
                shadeY = max(t.2 + 0.7, top - 1.1)
            }
            for p in spots {
                k.rod(SIMD3(p.x, top, p.y), SIMD3(p.x, shadeY + 0.2, p.y), 0.004, black)
                let cone = SCNCone(topRadius: 0.03, bottomRadius: 0.17, height: 0.2)
                cone.radialSegmentCount = 36
                cone.materials = [Mat.flat(UIColor(hex: palette.accent), rough: 0.45, metal: 0.2)]
                let n = SCNNode(geometry: cone)
                n.position = SCNVector3(p.x, shadeY + 0.1, p.y)
                k.node.addChildNode(n)
                k.cyl(0.155, 0.004, Mat.glow(warm, 2.2), x: p.x, y: shadeY + 0.01, z: p.y)
                light(spot(650, 2800, angle: 115), SIMD3(p.x, shadeY, p.y), down: true)
            }
        case "spots":
            let span = hi - lo
            let nx = max(2, Int(span.x / 1.2)), nz = max(2, Int(span.y / 1.2))
            var points: [SIMD2<Float>] = []
            for i in 0..<nx {
                for j in 0..<nz {
                    let p = SIMD2(lo.x + span.x * (Float(i) + 0.5) / Float(nx), lo.y + span.y * (Float(j) + 0.5) / Float(nz))
                    let ok = [SIMD2<Float>(0, 0), SIMD2(0.45, 0), SIMD2(-0.45, 0), SIMD2(0, 0.45), SIMD2(0, -0.45)]
                        .allSatisfy { inside(p + $0) }
                    if ok { points.append(p) }
                }
            }
            if points.isEmpty { points = [c] }
            let trim = Mat.flat(rgb(0.95, 0.95, 0.95), rough: 0.3)
            for p in points {
                k.cyl(0.045, 0.006, trim, x: p.x, y: top - 0.006, z: p.y)
                k.cyl(0.032, 0.002, Mat.glow(warm, 4), x: p.x, y: top - 0.008, z: p.y)
            }
            let step = max(1, points.count / 4)
            for p in stride(from: 0, to: points.count, by: step).prefix(4).map({ points[$0] }) {
                light(spot(480, 3000, angle: 100), SIMD3(p.x, top - 0.03, p.y), down: true)
            }
        case "track":
            let span = hi - lo
            let alongX = span.x >= span.y
            let length = (alongX ? span.x : span.y) * 0.7
            let rails: [Float] = (alongX ? span.y : span.x) > 3.2 ? [-0.25, 0.25] : [0]
            var lights = 0
            for off in rails {
                let o = (alongX ? span.y : span.x) * off
                let p = alongX ? SIMD2(c.x, c.y + o) : SIMD2(c.x + o, c.y)
                let railLen = alongX ? SIMD3(length, 0.035, 0.035) : SIMD3(0.035, 0.035, length)
                k.box(railLen.x, railLen.y, railLen.z, black, x: p.x, y: top - 0.035, z: p.y)
                for i in 0..<4 {
                    let t = (Float(i) / 3 - 0.5) * length * 0.85
                    let mount = alongX ? SIMD3(p.x + t, top - 0.035, p.y) : SIMD3(p.x, top - 0.035, p.y + t)
                    // голова светит к ближней стене
                    let side: Float = (alongX ? p.y - c.y : p.x - c.x) >= 0 ? 1 : -1
                    let dir = simd_normalize(alongX ? SIMD3(0, -1, side * 0.8) : SIMD3(side * 0.8, -1, 0))
                    let end = mount + dir * 0.14
                    k.rod(mount, end, 0.034, black)
                    k.ball(0.022, Mat.glow(warm, 3), x: end.x, y: end.y, z: end.z)
                    if lights < 4 {
                        let n = SCNNode()
                        n.light = spot(520, 3000, angle: 70)
                        n.simdPosition = end
                        k.node.addChildNode(n)
                        n.simdLook(at: end + dir)
                        lights += 1
                    }
                }
            }
        case "ring":
            let r: Float = simd_length(hi - lo) > 6 ? 0.45 : 0.35
            let y = top - 0.45
            k.cyl(0.06, 0.02, brass, x: c.x, y: top - 0.02, z: c.y)
            for i in 0..<3 {
                let a = Float(i) * 2 * .pi / 3
                k.rod(SIMD3(c.x, top, c.y), SIMD3(c.x + cos(a) * r, y, c.y + sin(a) * r), 0.002, brass)
            }
            k.ring(r, 0.016, brass, x: c.x, y: y + 0.004, z: c.y)
            k.ring(r, 0.012, Mat.glow(rgb(1.0, 0.95, 0.88), 2.5), x: c.x, y: y - 0.008, z: c.y)
            light(omni(1200, 3800, reach: reach), SIMD3(c.x, y - 0.1, c.y), down: false)
        default:
            break
        }
        return k.node
    }
}
