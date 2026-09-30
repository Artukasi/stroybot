import SceneKit
import SwiftUI
import UIKit
import simd

// MARK: - Стили

/// Стиль готового ремонта в 3D
enum RenoStyle: String, CaseIterable, Identifiable {
    case scandi, loft, minimal, classic, japandi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scandi: return "Скандинавский"
        case .loft: return "Лофт"
        case .minimal: return "Минимализм"
        case .classic: return "Классика"
        case .japandi: return "Японди"
        }
    }

    var look: StyleLook {
        switch self {
        case .scandi:
            return StyleLook(wall: rgb(0.95, 0.94, 0.91), brick: false,
                             floor: .planks(rgb(0.88, 0.77, 0.62), rgb(0.78, 0.64, 0.47)),
                             soft: rgb(0.80, 0.80, 0.78), wood: rgb(0.85, 0.73, 0.56),
                             accent: rgb(0.86, 0.66, 0.26), appliance: rgb(0.94, 0.94, 0.94),
                             trim: rgb(0.98, 0.98, 0.97))
        case .loft:
            return StyleLook(wall: rgb(0.62, 0.30, 0.22), brick: true,
                             floor: .concrete,
                             soft: rgb(0.45, 0.26, 0.15), wood: rgb(0.30, 0.22, 0.16),
                             accent: rgb(0.12, 0.12, 0.13), appliance: rgb(0.30, 0.31, 0.33),
                             trim: rgb(0.10, 0.10, 0.11))
        case .minimal:
            return StyleLook(wall: rgb(0.97, 0.97, 0.97), brick: false,
                             floor: .planks(rgb(0.90, 0.84, 0.74), rgb(0.84, 0.77, 0.66)),
                             soft: rgb(0.88, 0.88, 0.87), wood: rgb(0.93, 0.93, 0.92),
                             accent: rgb(0.15, 0.15, 0.16), appliance: rgb(0.86, 0.86, 0.87),
                             trim: rgb(0.99, 0.99, 0.99))
        case .classic:
            return StyleLook(wall: rgb(0.90, 0.84, 0.74), brick: false,
                             floor: .planks(rgb(0.58, 0.38, 0.23), rgb(0.44, 0.27, 0.16)),
                             soft: rgb(0.88, 0.82, 0.70), wood: rgb(0.40, 0.25, 0.15),
                             accent: rgb(0.78, 0.62, 0.30), appliance: rgb(0.92, 0.90, 0.86),
                             trim: rgb(0.98, 0.97, 0.94))
        case .japandi:
            return StyleLook(wall: rgb(0.88, 0.85, 0.79), brick: false,
                             floor: .planks(rgb(0.74, 0.60, 0.44), rgb(0.62, 0.48, 0.34)),
                             soft: rgb(0.78, 0.74, 0.66), wood: rgb(0.55, 0.42, 0.30),
                             accent: rgb(0.52, 0.58, 0.48), appliance: rgb(0.35, 0.34, 0.32),
                             trim: rgb(0.35, 0.28, 0.22))
        }
    }
}

enum FloorKind {
    /// Доска: два крайних оттенка, между ними — случайный
    case planks(UIColor, UIColor)
    case concrete
}

struct StyleLook {
    let wall: UIColor
    let brick: Bool
    let floor: FloorKind
    /// Мягкая мебель
    let soft: UIColor
    /// Столы, шкафы, двери
    let wood: UIColor
    /// Подушки и мелочи
    let accent: UIColor
    /// Техника
    let appliance: UIColor
    /// Рамы окон, плинтус
    let trim: UIColor
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
    UIColor(red: r, green: g, blue: b, alpha: 1)
}

private func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    let r = r1 + (r2 - r1) * t
    let g = g1 + (g2 - g1) * t
    let bl = b1 + (b2 - b1) * t
    return UIColor(red: r, green: g, blue: bl, alpha: 1)
}

private func shade(_ c: UIColor, _ k: CGFloat) -> UIColor {
    mix(c, k < 1 ? .black : .white, abs(1 - k))
}

/// Предсказуемый генератор случайных чисел: текстура одинаковая при каждом открытии
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 33
        return x
    }
}

// MARK: - Текстуры, нарисованные кодом

enum Textures {
    /// Паркетная доска. Картинка = 2 × 2 м.
    static func planks(_ light: UIColor, _ dark: UIColor) -> UIImage {
        let side: CGFloat = 1024
        let rows = 10
        let rowH = side / CGFloat(rows)
        var rnd = SeededRandom(state: 42)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            let g = ctx.cgContext
            for row in 0..<rows {
                let y = CGFloat(row) * rowH
                var x = -CGFloat.random(in: 0...400, using: &rnd)
                while x < side {
                    let len = CGFloat.random(in: 260...620, using: &rnd)
                    let tone = mix(light, dark, CGFloat.random(in: 0...1, using: &rnd))
                    g.setFillColor(tone.cgColor)
                    g.fill(CGRect(x: x, y: y, width: len, height: rowH))
                    // волокна дерева
                    for _ in 0..<7 {
                        let gy = y + CGFloat.random(in: 3...(rowH - 3), using: &rnd)
                        let alpha = CGFloat.random(in: 0.04...0.12, using: &rnd)
                        g.setStrokeColor(UIColor.black.withAlphaComponent(alpha).cgColor)
                        g.setLineWidth(CGFloat.random(in: 0.8...2.2, using: &rnd))
                        g.move(to: CGPoint(x: x + 4, y: gy))
                        let mid = gy + CGFloat.random(in: -3...3, using: &rnd)
                        g.addQuadCurve(to: CGPoint(x: x + len - 4, y: gy), control: CGPoint(x: x + len / 2, y: mid))
                        g.strokePath()
                    }
                    // шов между досками
                    g.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
                    g.fill(CGRect(x: x + len - 1.5, y: y, width: 1.5, height: rowH))
                    x += len
                }
                g.setFillColor(UIColor.black.withAlphaComponent(0.3).cgColor)
                g.fill(CGRect(x: 0, y: y, width: side, height: 1.5))
            }
        }
    }

    /// Бетон / микроцемент. Картинка = 2 × 2 м.
    static func concrete() -> UIImage {
        let side: CGFloat = 512
        var rnd = SeededRandom(state: 7)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            let g = ctx.cgContext
            g.setFillColor(rgb(0.60, 0.60, 0.58).cgColor)
            g.fill(CGRect(x: 0, y: 0, width: side, height: side))
            for _ in 0..<260 {
                let r = CGFloat.random(in: 10...60, using: &rnd)
                let x = CGFloat.random(in: 0...side, using: &rnd)
                let y = CGFloat.random(in: 0...side, using: &rnd)
                let light = Bool.random(using: &rnd)
                let color: UIColor = light ? .white : .black
                g.setFillColor(color.withAlphaComponent(CGFloat.random(in: 0.02...0.06, using: &rnd)).cgColor)
                g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            for _ in 0..<5000 {
                let x = CGFloat.random(in: 0...side, using: &rnd)
                let y = CGFloat.random(in: 0...side, using: &rnd)
                let color: UIColor = Bool.random(using: &rnd) ? .white : .black
                g.setFillColor(color.withAlphaComponent(CGFloat.random(in: 0.05...0.18, using: &rnd)).cgColor)
                g.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
            }
        }
    }

    /// Кирпичная кладка. Картинка = 1 × 1 м.
    static func brick(_ base: UIColor) -> UIImage {
        let side: CGFloat = 512
        let rows = 12
        let rowH = side / CGFloat(rows)
        let brickW = side / 4
        let mortar: CGFloat = 5
        var rnd = SeededRandom(state: 99)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            let g = ctx.cgContext
            g.setFillColor(rgb(0.78, 0.75, 0.70).cgColor)
            g.fill(CGRect(x: 0, y: 0, width: side, height: side))
            for row in 0..<rows {
                let y = CGFloat(row) * rowH
                let offset: CGFloat = row % 2 == 0 ? 0 : -brickW / 2
                for col in 0...4 {
                    let x = offset + CGFloat(col) * brickW
                    let k = CGFloat.random(in: 0.78...1.12, using: &rnd)
                    g.setFillColor(shade(base, k).cgColor)
                    let rect = CGRect(x: x + mortar / 2, y: y + mortar / 2, width: brickW - mortar, height: rowH - mortar)
                    g.fill(rect)
                    // пятна на кирпиче
                    for _ in 0..<6 {
                        let px = rect.minX + CGFloat.random(in: 0...rect.width, using: &rnd)
                        let py = rect.minY + CGFloat.random(in: 0...rect.height, using: &rnd)
                        let s = CGFloat.random(in: 2...8, using: &rnd)
                        g.setFillColor(UIColor.black.withAlphaComponent(0.08).cgColor)
                        g.fillEllipse(in: CGRect(x: px, y: py, width: s, height: s))
                    }
                }
            }
        }
    }

    /// Мягкий свет окружения: светлое небо сверху, тёплый пол снизу
    static func environment() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [rgb(0.95, 0.97, 1.0).cgColor, rgb(0.85, 0.85, 0.83).cgColor, rgb(0.55, 0.50, 0.45).cgColor]
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.5, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }
}

// MARK: - Сцена

final class BuiltScene {
    let id = UUID()
    let scene: SCNScene
    let camera: SCNNode
    init(scene: SCNScene, camera: SCNNode) {
        self.scene = scene
        self.camera = camera
    }
}

enum RenovationScene {
    static func material(_ color: UIColor, rough: CGFloat, metal: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = NSNumber(value: Double(rough))
        m.metalness.contents = NSNumber(value: Double(metal))
        return m
    }

    static func textured(_ image: UIImage, repeatX: Float, repeatY: Float, rough: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(max(repeatX, 0.1), max(repeatY, 0.1), 1)
        m.roughness.contents = NSNumber(value: Double(rough))
        m.metalness.contents = NSNumber(value: 0.0)
        return m
    }

    static func box(_ w: Float, _ h: Float, _ d: Float, _ m: SCNMaterial,
                    at p: SCNVector3 = SCNVector3Zero, chamfer: Float = 0) -> SCNNode {
        let smallest = min(w, min(h, d))
        let r = CGFloat(max(0, min(chamfer, smallest / 2 - 0.001)))
        let geo = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: r)
        geo.materials = [m]
        let node = SCNNode(geometry: geo)
        node.position = p
        return node
    }

    /// Строит сцену готового ремонта. Камера смотрит на комнату сверху по диагонали.
    static func build(_ world: RoomResult.World, style: RenoStyle, animate: Bool) -> BuiltScene {
        let look = style.look
        let scene = SCNScene()
        let root = scene.rootNode
        scene.background.contents = rgb(0.90, 0.93, 0.95)
        scene.lightingEnvironment.contents = Textures.environment()
        scene.lightingEnvironment.intensity = 1.0

        // уровень пола — низ стен
        var floorY: Float = 0
        let bottoms = world.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }
        if let lowest = bottoms.min() { floorY = lowest }

        // габариты комнаты
        var pts = world.floor
        if pts.count < 3 {
            pts = world.walls.map { SIMD2($0.transform.columns.3.x, $0.transform.columns.3.z) }
        }
        let xs = pts.map(\.x), zs = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minZ = zs.min() ?? 0, maxZ = zs.max() ?? 0
        let cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2
        let size = max(maxX - minX, maxZ - minZ, 2)

        root.addChildNode(floorNode(world.floor, look: look, floorY: floorY, size: size))
        for wall in world.walls { root.addChildNode(wallNode(wall, look: look)) }
        for o in world.openings { root.addChildNode(openingNode(o, look: look)) }
        for o in world.objects { root.addChildNode(furnitureNode(o, look: look)) }
        addLights(to: root, center: SCNVector3(cx, floorY, cz), size: size)

        // камера на «штативе», который медленно поворачивается вокруг комнаты
        let pivot = SCNNode()
        pivot.position = SCNVector3(cx, floorY, cz)
        root.addChildNode(pivot)
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = 0.05
        camera.zFar = 200
        camera.wantsHDR = true
        camera.screenSpaceAmbientOcclusionIntensity = 0.7
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let dist = size * 0.95 + 1
        cameraNode.position = SCNVector3(dist * 0.7, dist * 1.05, dist * 0.7)
        pivot.addChildNode(cameraNode)
        cameraNode.look(at: SCNVector3(cx, floorY + 0.4, cz))
        if animate {
            let orbit = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 0.6, z: 0, duration: 9)
            orbit.timingMode = .easeInEaseOut
            pivot.runAction(orbit)
        }
        return BuiltScene(scene: scene, camera: cameraNode)
    }

    private static func floorNode(_ polygon: [SIMD2<Float>], look: StyleLook, floorY: Float, size: Float) -> SCNNode {
        let path = UIBezierPath()
        for (i, p) in polygon.enumerated() {
            // после поворота на -90° по X: y пути → -z мира
            let pt = CGPoint(x: CGFloat(p.x), y: CGFloat(-p.y))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0.02)
        let repeats = size / 2
        let m: SCNMaterial
        switch look.floor {
        case .planks(let light, let dark):
            m = textured(Textures.planks(light, dark), repeatX: repeats, repeatY: repeats, rough: 0.55)
        case .concrete:
            m = textured(Textures.concrete(), repeatX: repeats, repeatY: repeats, rough: 0.8)
        }
        shape.materials = [m]
        let node = SCNNode(geometry: shape)
        node.eulerAngles.x = -Float.pi / 2
        node.position.y = floorY - 0.01
        return node
    }

    private static func wallNode(_ wall: RoomResult.Solid, look: StyleLook) -> SCNNode {
        let len = wall.dimensions.x, h = wall.dimensions.y
        let m: SCNMaterial
        if look.brick {
            m = textured(Textures.brick(look.wall), repeatX: len, repeatY: h, rough: 0.9)
        } else {
            m = material(look.wall, rough: 0.85)
        }
        let node = SCNNode()
        node.simdTransform = wall.transform
        node.addChildNode(box(len, h, 0.08, m))
        // плинтус с обеих сторон
        let trim = material(look.trim, rough: 0.5)
        let y = -h / 2 + 0.04
        node.addChildNode(box(len, 0.08, 0.015, trim, at: SCNVector3(0, y, 0.047)))
        node.addChildNode(box(len, 0.08, 0.015, trim, at: SCNVector3(0, y, -0.047)))
        return node
    }

    private static func frame(_ w: Float, _ h: Float, _ m: SCNMaterial, bottom: Bool) -> [SCNNode] {
        let t: Float = 0.05, d: Float = 0.13
        var nodes = [
            box(w, t, d, m, at: SCNVector3(0, h / 2 - t / 2, 0)),
            box(t, h, d, m, at: SCNVector3(-w / 2 + t / 2, 0, 0)),
            box(t, h, d, m, at: SCNVector3(w / 2 - t / 2, 0, 0)),
        ]
        if bottom { nodes.append(box(w, t, d, m, at: SCNVector3(0, -h / 2 + t / 2, 0))) }
        return nodes
    }

    private static func openingNode(_ o: RoomResult.Solid, look: StyleLook) -> SCNNode {
        let w = o.dimensions.x, h = o.dimensions.y
        let node = SCNNode()
        node.simdTransform = o.transform
        let trim = material(look.trim, rough: 0.4)
        switch o.kind {
        case "window":
            let glass = material(rgb(0.70, 0.86, 0.97), rough: 0.05)
            glass.transparency = 0.45
            glass.blendMode = .alpha
            glass.isDoubleSided = true
            glass.writesToDepthBuffer = false
            node.addChildNode(box(max(w - 0.08, 0.05), max(h - 0.08, 0.05), 0.1, glass))
            frame(w, h, trim, bottom: true).forEach { node.addChildNode($0) }
            // подоконник
            node.addChildNode(box(w + 0.1, 0.03, 0.26, trim, at: SCNVector3(0, -h / 2 - 0.015, 0)))
        case "door":
            let panel = material(look.wood, rough: 0.55)
            node.addChildNode(box(max(w - 0.08, 0.05), max(h - 0.04, 0.05), 0.1, panel, at: SCNVector3(0, -0.02, 0)))
            frame(w, h, trim, bottom: false).forEach { node.addChildNode($0) }
            let metal = material(rgb(0.75, 0.72, 0.65), rough: 0.3, metal: 1)
            let hx = w / 2 - 0.12
            node.addChildNode(box(0.12, 0.02, 0.03, metal, at: SCNVector3(hx, 0, 0.07)))
            node.addChildNode(box(0.12, 0.02, 0.03, metal, at: SCNVector3(hx, 0, -0.07)))
        default:
            // проём без двери: тёмный проход в рамке
            let dark = material(rgb(0.22, 0.22, 0.24), rough: 0.9)
            node.addChildNode(box(max(w - 0.08, 0.05), max(h - 0.04, 0.05), 0.1, dark, at: SCNVector3(0, -0.02, 0)))
            frame(w, h, trim, bottom: false).forEach { node.addChildNode($0) }
        }
        return node
    }

    private static func furnitureNode(_ o: RoomResult.Solid, look: StyleLook) -> SCNNode {
        let w = o.dimensions.x, h = o.dimensions.y, d = o.dimensions.z
        let node = SCNNode()
        node.simdTransform = o.transform
        let soft = material(look.soft, rough: 0.95)
        let wood = material(look.wood, rough: 0.6)
        let accent = material(look.accent, rough: 0.8)
        let ceramic = material(rgb(0.97, 0.97, 0.97), rough: 0.12)
        let appliance = material(look.appliance, rough: 0.3, metal: 0.3)
        let r: Float = 0.03
        switch o.kind {
        case "sofa":
            let seatH = h * 0.45
            node.addChildNode(box(w, seatH, d, soft, at: SCNVector3(0, -h / 2 + seatH / 2, 0), chamfer: r))
            node.addChildNode(box(w, h, d * 0.25, soft, at: SCNVector3(0, 0, -d / 2 + d * 0.125), chamfer: r))
            let armW = min(Float(0.15), w * 0.1), armH = h * 0.7
            node.addChildNode(box(armW, armH, d, soft, at: SCNVector3(-w / 2 + armW / 2, -h / 2 + armH / 2, 0), chamfer: r))
            node.addChildNode(box(armW, armH, d, soft, at: SCNVector3(w / 2 - armW / 2, -h / 2 + armH / 2, 0), chamfer: r))
            let py = -h / 2 + seatH + 0.17
            node.addChildNode(box(0.4, 0.34, 0.12, accent, at: SCNVector3(-w / 4, py, -d / 4), chamfer: 0.05))
            node.addChildNode(box(0.4, 0.34, 0.12, accent, at: SCNVector3(w / 4, py, -d / 4), chamfer: 0.05))
        case "bed":
            let baseH = min(h * 0.45, 0.3)
            node.addChildNode(box(w, baseH, d, wood, at: SCNVector3(0, -h / 2 + baseH / 2, 0), chamfer: r))
            let mattressH: Float = 0.2
            let my = -h / 2 + baseH + mattressH / 2
            let linen = material(rgb(0.96, 0.95, 0.93), rough: 0.95)
            node.addChildNode(box(w - 0.04, mattressH, d - 0.04, linen, at: SCNVector3(0, my, 0), chamfer: 0.05))
            node.addChildNode(box(w - 0.02, 0.05, d * 0.55, accent, at: SCNVector3(0, my + 0.1, d * 0.2), chamfer: 0.02))
            node.addChildNode(box(w, max(h, baseH + 0.5), 0.07, wood, at: SCNVector3(0, 0, -d / 2 + 0.035), chamfer: r))
            node.addChildNode(box(w * 0.7, 0.12, 0.35, linen, at: SCNVector3(0, my + 0.15, -d / 2 + 0.3), chamfer: 0.05))
        case "table":
            node.addChildNode(box(w, 0.04, d, wood, at: SCNVector3(0, h / 2 - 0.02, 0), chamfer: 0.01))
            addLegs(to: node, w: w, h: h - 0.04, d: d, top: h / 2 - 0.04, m: wood)
        case "chair":
            let seatY = -h / 2 + h * 0.47
            node.addChildNode(box(w, 0.05, d, soft, at: SCNVector3(0, seatY, 0), chamfer: 0.02))
            let backH = h / 2 - seatY
            node.addChildNode(box(w, backH, 0.04, wood, at: SCNVector3(0, seatY + backH / 2, -d / 2 + 0.02), chamfer: 0.01))
            addLegs(to: node, w: w, h: seatY + h / 2, d: d, top: seatY - 0.025, m: wood)
        case "storage":
            node.addChildNode(box(w, h - 0.05, d, wood, at: SCNVector3(0, 0.025, 0), chamfer: 0.01))
            node.addChildNode(box(w - 0.04, 0.05, d - 0.04, material(look.trim, rough: 0.6), at: SCNVector3(0, -h / 2 + 0.025, 0)))
        case "television":
            let screen = material(rgb(0.04, 0.04, 0.05), rough: 0.08, metal: 0.2)
            node.addChildNode(box(w, h, max(d, 0.04), screen, chamfer: 0.005))
        case "sink", "toilet", "bathtub":
            node.addChildNode(box(w, h, d, ceramic, chamfer: 0.06))
        case "refrigerator", "stove", "oven", "dishwasher", "washerDryer":
            node.addChildNode(box(w, h, d, appliance, chamfer: 0.02))
        case "fireplace":
            node.addChildNode(box(w, h, d, material(rgb(0.56, 0.53, 0.49), rough: 0.9), chamfer: 0.01))
        case "stairs":
            node.addChildNode(box(w, h, d, wood, chamfer: 0.01))
        default:
            node.addChildNode(box(w, h, d, soft, chamfer: r))
        }
        return node
    }

    private static func addLegs(to node: SCNNode, w: Float, h: Float, d: Float, top: Float, m: SCNMaterial) {
        let leg: Float = 0.045
        let lx = w / 2 - leg, lz = d / 2 - leg
        let y = top - h / 2
        for sx in [Float(-1), 1] {
            for sz in [Float(-1), 1] {
                node.addChildNode(box(leg, max(h, 0.02), leg, m, at: SCNVector3(sx * lx, y, sz * lz)))
            }
        }
    }

    private static func addLights(to root: SCNNode, center: SCNVector3, size: Float) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 350
        ambient.color = UIColor(white: 1, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1300
        sun.color = rgb(1.0, 0.97, 0.92)
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowRadius = 8
        sun.shadowSampleCount = 16
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowColor = UIColor(white: 0, alpha: 0.4)
        sun.orthographicScale = CGFloat(size)
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.position = SCNVector3(center.x + size, center.y + size * 2, center.z + size * 0.6)
        sunNode.look(at: center)
        root.addChildNode(sunNode)
    }
}

// MARK: - Экран «Ремонт в 3D»

struct Renovation3DView: View {
    let world: RoomResult.World
    let room: String
    @State private var style: RenoStyle = .scandi
    @State private var built: BuiltScene?
    @State private var exportURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            stylePicker
            ZStack {
                Color(red: 0.90, green: 0.93, blue: 0.95)
                if let built {
                    SceneView(scene: built.scene, pointOfView: built.camera, options: [.allowsCameraControl])
                        .id(built.id)
                } else {
                    ProgressView("Собираю комнату…")
                }
            }
            Text("Крутите комнату пальцем, приближайте двумя пальцами. Это пример отделки: цвета и мебель условные.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Ремонт в 3D")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: style) { await rebuild() }
    }

    private var stylePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RenoStyle.allCases) { s in
                    Button { style = s } label: {
                        Text(s.title).font(.subheadline.bold())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(s == style ? Palette.signal : Color(.secondarySystemGroupedBackground), in: Capsule())
                            .foregroundStyle(Palette.ink)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func rebuild() async {
        exportURL = nil
        built = RenovationScene.build(world, style: style, animate: true)
        // файл для «Поделиться»: отдельная копия сцены без анимации
        try? await Task.sleep(nanoseconds: 400_000_000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Remont-\(style.rawValue).usdz")
        try? FileManager.default.removeItem(at: url)
        let copy = RenovationScene.build(world, style: style, animate: false)
        if copy.scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) {
            exportURL = url
        }
    }
}
