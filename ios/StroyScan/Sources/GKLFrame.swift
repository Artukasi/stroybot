import SceneKit
import SwiftUI
import simd

/// Предварительная геометрическая раскладка металлических профилей по RoomPlan.
/// Это эскиз, не расчёт несущей способности, противопожарных узлов или подвесов.
enum GKLFrame {
    enum Mode: String, CaseIterable, Identifiable {
        case wall = "Стена / облицовка"
        case ceiling = "Потолок"
        var id: String { rawValue }
    }
    struct Beam {
        let a: SIMD3<Float>
        let b: SIMD3<Float>
        let label: String
        var length: Float { simd_distance(a, b) }
    }
    struct Layout {
        let beams: [Beam]
        let height: Float
        var meters: Double { beams.reduce(0) { $0 + Double($1.length) } }
        var stock3m: Int { Int(ceil(meters * 1.12 / 3)) }
    }
    static func room(_ r: RoomResult) -> Room3D { Room3D(r) }
    static func generate(_ r: RoomResult, mode: Mode, wallIndex: Int, spacing: Float, drop: Float) -> Layout {
        let room = Room3D(r)
        let step = max(0.3, min(spacing, 0.9))
        let h = room.height
        var beams: [Beam] = []
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ label: String) {
            guard simd_distance(a, b) > 0.045, beams.count < 3000 else { return }
            beams.append(Beam(a: a, b: b, label: label))
        }
        if mode == .wall {
            guard room.walls.indices.contains(wallIndex) else { return Layout(beams: [], height: h) }
            let wall = room.walls[wallIndex]
            let openings = room.openings[wallIndex]
            let inward: Float = 0.075
            func p(_ distance: Float, _ height: Float) -> SIMD3<Float> {
                let q = wall.point(distance) + wall.normal * inward
                return SIMD3(q.x, height, q.y)
            }
            add(p(0, 0), p(wall.length, 0), "Нижняя направляющая — эскиз")
            add(p(0, h), p(wall.length, h), "Верхняя направляющая — эскиз")
            let n = Int(ceil(wall.length / step))
            for i in 0...min(n, 500) {
                let x = min(Float(i) * step, wall.length)
                if x > wall.length + 0.001 { continue }
                if let opening = openings.first(where: { x > $0.left + 0.01 && x < $0.right - 0.01 }) {
                    if opening.bottom > 0.05 { add(p(x, 0), p(x, opening.bottom), "Стойка под проёмом") }
                    if opening.top < h - 0.05 { add(p(x, opening.top), p(x, h), "Стойка над проёмом") }
                } else {
                    add(p(x, 0), p(x, h), "Стойка")
                }
            }
            // Границы проёмов и перемычки. Конкретное усиление по системе производителя.
            for op in openings {
                let l = max(0, op.left), rr = min(wall.length, op.right)
                guard rr > l else { continue }
                add(p(l, 0), p(l, h), "Край проёма: схема усиления")
                add(p(rr, 0), p(rr, h), "Край проёма: схема усиления")
                add(p(l, op.top), p(rr, op.top), "Перемычка сверху")
                if op.bottom > 0.05 { add(p(l, op.bottom), p(rr, op.bottom), "Перемычка снизу") }
            }
        } else {
            let y = max(1.9, h - max(0.08, min(drop, h - 1.85)))
            let minX = room.lo.x, maxX = room.hi.x
            let minZ = room.lo.y, maxZ = room.hi.y
            // Дискретизация видимой внутри комнаты длины, чтобы не рисовать
            // балки через вырезы Г-образных помещений.
            func clipLine(fixed: Float, alongX: Bool) {
                let lower = alongX ? minX : minZ
                let upper = alongX ? maxX : maxZ
                let grain: Float = 0.05
                var begin: Float?
                var t = lower
                while t <= upper + grain / 2 {
                    let q = alongX ? SIMD2<Float>(t, fixed) : SIMD2<Float>(fixed, t)
                    let inside = t <= upper && room.inside(q)
                    if inside && begin == nil { begin = t }
                    if !inside, let b = begin {
                        let a = alongX ? SIMD3<Float>(b, y, fixed) : SIMD3<Float>(fixed, y, b)
                        let c = alongX ? SIMD3<Float>(min(t, upper), y, fixed) : SIMD3<Float>(fixed, y, min(t, upper))
                        add(a, c, alongX ? "Продольный профиль" : "Поперечный профиль")
                        begin = nil
                    }
                    t += grain
                }
                if let b = begin {
                    let a = alongX ? SIMD3<Float>(b, y, fixed) : SIMD3<Float>(fixed, y, b)
                    let c = alongX ? SIMD3<Float>(upper, y, fixed) : SIMD3<Float>(fixed, y, upper)
                    add(a, c, "Потолочный профиль")
                }
            }
            let countX = min(500, Int(ceil((maxZ - minZ) / step)))
            for i in 0...countX { clipLine(fixed: min(minZ + Float(i) * step, maxZ), alongX: true) }
            // Поперечины: частота предварительная, не норматив монтажной системы.
            let countZ = min(500, Int(ceil((maxX - minX) / 1.2)))
            for i in 0...countZ { clipLine(fixed: min(minX + Float(i) * 1.2, maxX), alongX: false) }
        }
        return Layout(beams: beams, height: h)
    }

    static func scene(_ r: RoomResult, layout: Layout) -> SCNScene {
        let room = Room3D(r)
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.04, green: 0.08, blue: 0.14, alpha: 1)
        func material(_ color: UIColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.lightingModel = .physicallyBased
            m.metalness.contents = 0.25
            m.roughness.contents = 0.55
            return m
        }
        let profile = material(UIColor(red: 0.98, green: 0.60, blue: 0.30, alpha: 1))
        let outline = material(UIColor(red: 0.36, green: 0.58, blue: 0.77, alpha: 0.55))
        func draw(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: CGFloat, mat: SCNMaterial) {
            let delta = b - a
            let length = simd_length(delta)
            guard length > 0.02 else { return }
            let beam = SCNBox(width: width, height: CGFloat(length), length: width, chamferRadius: width * 0.08)
            beam.materials = [mat]
            let node = SCNNode(geometry: beam)
            node.simdPosition = (a + b) / 2
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            scene.rootNode.addChildNode(node)
        }
        // Контур помещения без закрывающих стен — так профили остаются видны.
        for w in room.walls {
            let a = SIMD3<Float>(w.a.x, 0, w.a.y)
            let b = SIMD3<Float>(w.b.x, 0, w.b.y)
            draw(a, b, width: 0.015, mat: outline)
            draw(a + SIMD3<Float>(0, room.height, 0), b + SIMD3<Float>(0, room.height, 0), width: 0.015, mat: outline)
            for q in [w.a, w.b] {
                draw(SIMD3<Float>(q.x, 0, q.y),
                     SIMD3<Float>(q.x, room.height, q.y), width: 0.012, mat: outline)
            }
        }
        for beam in layout.beams {
            draw(beam.a, beam.b, width: 0.036, mat: profile)
        }
        let middle = room.centroid
        let range = max(2, max(room.hi.x - room.lo.x, room.hi.y - room.lo.y))
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.05
        camera.zFar = 150
        cameraNode.camera = camera
        cameraNode.simdPosition = SIMD3<Float>(middle.x + range * 1.35, room.height + range * 0.9, middle.y + range * 1.35)
        cameraNode.look(at: SCNVector3(middle.x, room.height * 0.47, middle.y))
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode({
            let node = SCNNode()
            let light = SCNLight()
            light.type = .omni
            light.intensity = 1100
            node.light = light
            node.position = SCNVector3(middle.x, room.height + 5, middle.y + 3)
            return node
        }())
        scene.rootNode.addChildNode({
            let node = SCNNode()
            let light = SCNLight()
            light.type = .ambient
            light.intensity = 360
            node.light = light
            return node
        }())
        return scene
    }
}

struct GKLFrameView: View {
    let result: RoomResult
    @State private var mode: GKLFrame.Mode = .wall
    @State private var wall = 0
    @State private var spacing = 0.6
    @State private var drop = 0.15

    private var geo: Room3D { Room3D(result) }
    private var layout: GKLFrame.Layout {
        GKLFrame.generate(result, mode: mode, wallIndex: wall,
                          spacing: Float(spacing), drop: Float(drop))
    }
    private var report: String {
        let mat = layout
        return """
        СтройСкан — ЭСКИЗ КАРКАСА ГКЛ
        Помещение: \(result.room)
        Режим: \(mode.rawValue)
        Шаг предварительной раскладки: \(Int((spacing * 100).rounded())) см
        Профили на 3D-схеме: \(mat.beams.count) отрезков
        Общая геометрическая длина: \(String(format: "%.1f", mat.meters)) м
        Ориентир заготовок 3 м с запасом 12%: \(mat.stock3m) шт.
        Листы ГКЛ, подвесы, соединители, крепёж, усиления, фактический раскрой,
        нагрузка, геометрия конструкций и нормативный шаг рассчитываются отдельно.
        Это НЕ монтажный проект. Шаг, крепления, допустимые нагрузки, проёмы и
        огнестойкость проверяются по конкретной сертифицированной системе.
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Схема каркаса по LiDAR")
                    .font(.title2.bold())
                Text("Оранжевым показаны предполагаемые профили. Поворачивай 3D-модель пальцем и приближай двумя пальцами.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Конструкция", selection: $mode) {
                    ForEach(GKLFrame.Mode.allCases) { value in Text(value.rawValue).tag(value) }
                }.pickerStyle(.segmented)
                if mode == .wall {
                    Picker("Существующая стена", selection: $wall) {
                        ForEach(geo.walls.indices, id: \.self) { index in
                            Text("Стена \(index + 1) · \(String(format: "%.2f", geo.walls[index].length)) м")
                                .tag(index)
                        }
                    }
                }
                HStack {
                    Text("Шаг профилей")
                    Spacer()
                    Text("\(Int((spacing * 100).rounded())) см").monospacedDigit()
                }
                Picker("Шаг", selection: $spacing) {
                    Text("40 см").tag(0.4)
                    Text("60 см").tag(0.6)
                }.pickerStyle(.segmented)
                if mode == .ceiling {
                    HStack {
                        Text("Опуск потолка")
                        Spacer()
                        Text("\(Int((drop * 100).rounded())) см")
                    }
                    Slider(value: $drop, in: 0.1...0.4, step: 0.05)
                }
                SceneView(scene: GKLFrame.scene(result, layout: layout),
                          options: [.allowsCameraControl, .autoenablesDefaultLighting])
                    .frame(height: 365)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                    .id("\(mode.rawValue)-\(wall)-\(spacing)-\(drop)")
                VStack(alignment: .leading, spacing: 8) {
                    Label("Предварительная ведомость", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    LabeledContent("Отрезков профилей в модели", value: "\(layout.beams.count)")
                    LabeledContent("Суммарная длина", value: String(format: "%.1f м", layout.meters))
                    LabeledContent("Заготовки по 3 м (+12%)", value: "\(layout.stock3m) шт.")
                    Text("Количество профилей ориентировочное. Это не раскрой и не закупочная ведомость конкретной системы.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                ShareLink(item: report) {
                    Label("Переслать схему и подсчёт", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.signal)
                Label("Для монтажа обязательно проверить расположение и усиление проёмов, шаг каркаса, подвесы, крепёж к основанию, нагрузки, звукоизоляцию и огнестойкость по выбранной системе ГКЛ. Для потолка текущая сетка — схема расположения осей, не расчёт подвесов.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }.padding()
        }
        .navigationTitle("Каркас ГКЛ · 3D")
        .navigationBarTitleDisplayMode(.inline)
    }
}
