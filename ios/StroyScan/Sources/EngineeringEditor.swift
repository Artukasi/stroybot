import SceneKit
import SwiftUI
import simd

/// Режим 3D-редактора: ремонт, электрика или сантехника
enum EngMode: Equatable {
    case off, electric, plumbing
}

/// Что ставим нажатием: точку (розетку, вывод), трубу или провод (по точкам)
enum EngTool: Equatable {
    case point(String)
    case pipe(String, Int)
    case wire(String)

    /// Трасса нажатиями: труба или провод
    var isRoute: Bool {
        switch self {
        case .point: return false
        case .pipe, .wire: return true
        }
    }
}

/// Электрика и сантехника в 3D: нажали на стену — там розетка или вывод воды; трубы — нажатиями по стенам.
extension RenoEditor {
    func setEngMode(_ m: EngMode) {
        select(nil)
        engMode = m
        engTool = nil
        route = []
        engSelected = nil
        engHint = nil
        buildEngineering()
    }

    func setTool(_ t: EngTool?) {
        if engTool?.isRoute == true, t != engTool { route = [] }
        engTool = t
        engSelected = nil
        switch t {
        case .point(let id)?:
            let k = EngKind.find(id)
            engHint = k?.place == .ceiling ? "Нажмите на пол там, где под ним будет свет" : "Нажмите на стену, где поставить: \(k?.title.lowercased() ?? "точку")"
        case .pipe?:
            engHint = "Нажимайте по стенам и полу вдоль трассы трубы, потом «Готово»"
        case .wire?:
            engHint = "Ведите провод: нажимайте по стенам от щитка или коробки до точки, потом «Готово»"
        case nil:
            engHint = nil
        }
        buildEngineering()
    }

    var selectedPoint: Engineering.Point? { eng.points.first { $0.id == engSelected } }
    var selectedPipe: Engineering.Pipe? { eng.pipes.first { $0.id == engSelected } }
    var selectedWire: Engineering.Pipe? { eng.wires.first { $0.id == engSelected } }

    // MARK: Правки

    func moveSelected(height delta: Double) {
        guard let i = eng.points.firstIndex(where: { $0.id == engSelected }), eng.points[i].wall != nil else { return }
        let top = Double(room.height) - 0.05
        eng.points[i].height = min(max(eng.points[i].height + delta, 0.05), top)
        buildEngineering()
    }

    func setPipeDiameter(_ d: Int) {
        guard let i = eng.pipes.firstIndex(where: { $0.id == engSelected }) else { return }
        eng.pipes[i].diameter = d
        buildEngineering()
    }

    func removeSelected() {
        eng.points.removeAll { $0.id == engSelected }
        eng.pipes.removeAll { $0.id == engSelected }
        eng.wires.removeAll { $0.id == engSelected }
        engSelected = nil
        buildEngineering()
    }

    func undoRoutePoint() {
        guard !route.isEmpty else { return }
        route.removeLast()
        buildEngineering()
    }

    /// Труба проведена: в список
    func finishRoute() {
        if case .wire(let kind)? = engTool {
            if route.count >= 2, eng.wires.count < Engineering.maxWires {
                let wire = Engineering.Pipe(kind: kind, diameter: 0, points: route)
                eng.wires.append(wire)
                engSelected = wire.id
            }
            route = []
            buildEngineering()
            return
        }
        guard case .pipe(let kind, let d)? = engTool, route.count >= 2, eng.pipes.count < Engineering.maxPipes else {
            route = []
            buildEngineering()
            return
        }
        let pipe = Engineering.Pipe(kind: kind, diameter: d, points: route)
        eng.pipes.append(pipe)
        route = []
        engSelected = pipe.id
        buildEngineering()
    }

    /// Труба из скана камерой: если координаты те же, что у скана, — сразу на место, иначе ждём нажатия на стену
    func addScannedPipe(_ pipe: Engineering.Pipe, anchored: Bool) {
        guard eng.pipes.count < Engineering.maxPipes else { return }
        if anchored {
            eng.pipes.append(pipe)
            engSelected = pipe.id
            if engMode != .plumbing { engMode = .plumbing }
            engHint = nil
        } else {
            if engMode != .plumbing { engMode = .plumbing }
            pendingPipe = pipe
            engTool = nil
            engHint = "Нажмите на стену, где начинается труба — она ляжет вдоль этой стены"
        }
        buildEngineering()
    }

    func cancelPending() {
        pendingPipe = nil
        engHint = nil
        buildEngineering()
    }

    // MARK: Нажатия

    func engTap(at p: CGPoint) {
        let hits = view.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        // уже поставленная точка или труба — выбрать (если ничего не ставим)
        if engTool == nil && pendingPipe == nil {
            for h in hits {
                var n: SCNNode? = h.node
                while let cur = n {
                    if let name = cur.name, name.hasPrefix("eng:"), let id = UUID(uuidString: String(name.dropFirst(4))) {
                        engSelected = id
                        buildEngineering()
                        return
                    }
                    n = cur.parent
                }
            }
            engSelected = nil
            buildEngineering()
            return
        }
        guard let (wall, world) = surfaceHit(hits) else {
            engHint = "Не попали в стену — нажмите ещё раз"
            return
        }
        let plan = SIMD2(Double(world.x), Double(world.z))
        let h = Double(world.y)

        if var pipe = pendingPipe {
            // привязка трубы из скана: первая точка — сюда, дальше вдоль стены
            guard let w = wall, let start = result.nearestWall(plan), start.wall == w,
                  let line = result.wallLines[safe: w] else { return }
            let a = SIMD2(line.x, line.y), b = SIMD2(line.z, line.w)
            let len = simd_distance(a, b)
            guard len > 0 else { return }
            let u = (b - a) / len
            let base = pipe.points.first ?? SIMD3(0, 0, 0)
            // в трубе из скана x — вдоль, z — высота от пола; идём в сторону, где на стене больше места
            let span = (pipe.points.map(\.x).max() ?? 0) - (pipe.points.map(\.x).min() ?? 0)
            let dir: Double = start.offset + span <= len + 0.05 ? 1 : -1
            pipe.points = pipe.points.map { q in
                let s = min(max(start.offset + dir * (q.x - base.x), 0), len)
                let pt = a + u * s
                return SIMD3(pt.x, pt.y, max(0, q.z))
            }
            eng.pipes.append(pipe)
            engSelected = pipe.id
            pendingPipe = nil
            engHint = nil
            buildEngineering()
            return
        }

        switch engTool {
        case .point(let id)?:
            guard let kind = EngKind.find(id), eng.points.count < Engineering.maxPoints else { return }
            var point: Engineering.Point
            if kind.place == .ceiling {
                guard room.inside(SIMD2(Float(plan.x), Float(plan.y))) else { return }
                point = Engineering.Point(kind: id, wall: nil, offset: 0, x: plan.x, y: plan.y, height: Double(room.height))
            } else {
                guard let w = wall, let found = result.nearestWall(plan), found.wall == w,
                      let at = result.wallPoint(w, offset: found.offset) else {
                    engHint = "Это ставится на стену — нажмите на стену"
                    return
                }
                // высота — где нажали; если нажали на пол — обычная высота для этой точки
                let height = h > 0.03 ? min(h, Double(room.height) - 0.05) : kind.height
                point = Engineering.Point(kind: id, wall: w, offset: found.offset, x: at.x, y: at.y, height: height)
            }
            eng.points.append(point)
            engSelected = point.id
            buildEngineering()
        case .pipe?, .wire?:
            // трасса у стены: точку прижимаем к стене, на полу — как есть
            var q = SIMD3(plan.x, plan.y, max(0, h))
            if let w = wall, let found = result.nearestWall(plan), found.wall == w, let at = result.wallPoint(w, offset: found.offset) {
                q = SIMD3(at.x, at.y, max(0, h))
            }
            route.append(q)
            buildEngineering()
        case nil:
            break
        }
    }

    /// Куда нажали: стена (номер скана) или пол/потолок, и точка в мире
    private func surfaceHit(_ hits: [SCNHitTestResult]) -> (Int?, SIMD3<Float>)? {
        for h in hits {
            var n: SCNNode? = h.node
            var isEng = false
            while let cur = n {
                if cur.name == "sel" || cur.name?.hasPrefix("eng") == true { isEng = true; break }
                if let name = cur.name {
                    if name.hasPrefix("wall:"), let i = Int(name.dropFirst(5)) { return (i, h.simdWorldCoordinates) }
                    if name.hasPrefix("win:") || name.hasPrefix("door:") { break }
                    if name == "floor" || name == "ceiling" { return (nil, h.simdWorldCoordinates) }
                }
                n = cur.parent
            }
            if isEng { continue }
        }
        // промахнулись по сцене — пол под пальцем
        return nil
    }

    // MARK: Сцена

    func buildEngineering() {
        engHolder.childNodes.forEach { $0.removeFromParentNode() }
        engWallOf = [:]
        let normals = Dictionary(room.walls.map { ($0.index, $0.normal) }, uniquingKeysWith: { a, _ in a })
        let angles = Dictionary(room.walls.map { ($0.index, atan2(-$0.dir.y, $0.dir.x)) }, uniquingKeysWith: { a, _ in a })
        let top = room.height

        // точки
        for p in eng.points {
            guard let kind = EngKind.find(p.kind) else { continue }
            let node: SCNNode
            if kind.place == .ceiling {
                node = Eng3D.ceilingLight()
                node.simdPosition = SIMD3(Float(p.x), top, Float(p.y))
            } else {
                guard let w = p.wall, let n = normals[w], let ang = angles[w] else { continue }
                // на голых стенах — вырез под подрозетник, а не готовая розетка
                node = bare && kind.group == .electric && kind.id != "sconce" ? Eng3D.cutout(kind) : Eng3D.point(kind)
                node.simdPosition = SIMD3(Float(p.x) + n.x * 0.003, Float(p.height), Float(p.y) + n.y * 0.003)
                node.eulerAngles.y = ang
                engWallOf[p.id] = w
            }
            node.name = "eng:\(p.id.uuidString)"
            if p.id == engSelected { node.addChildNode(Self.ring(kind.place == .ceiling)) }
            engHolder.addChildNode(node)
        }

        // трубы — в режиме сантехники; кабели — в режиме электрики
        let inset = { (q: SIMD3<Double>) -> SIMD3<Float> in
            let p2 = SIMD2(Float(q.x), Float(q.y))
            var n = SIMD2<Float>(0, 0)
            if let w = self.result.nearestWall(SIMD2(q.x, q.y)), w.distance < 0.15, let nn = normals[w.wall] { n = nn * 0.04 }
            return SIMD3(p2.x + n.x, Float(q.z), p2.y + n.y)
        }
        if engMode == .plumbing {
            for p in eng.pipes {
                let node = Eng3D.pipe(p, inset: inset)
                node.name = "eng:\(p.id.uuidString)"
                if p.id == engSelected, let first = p.points.first {
                    let ring = Self.ring(false)
                    ring.simdPosition = inset(first)
                    node.addChildNode(ring)
                }
                engHolder.addChildNode(node)
            }
            if route.count >= 1, case .pipe(let kind, let d)? = engTool {
                let preview = Eng3D.pipe(Engineering.Pipe(kind: kind, diameter: d, points: route.count == 1 ? [route[0], route[0]] : route),
                                         inset: inset)
                preview.opacity = 0.75
                engHolder.addChildNode(preview)
            }
        }
        if engMode == .electric {
            let onWall = { (q: SIMD3<Double>) -> SIMD3<Float> in
                var n = SIMD2<Float>(0, 0)
                if let w = self.result.nearestWall(SIMD2(q.x, q.y)), w.distance < 0.15, let nn = normals[w.wall] { n = nn * 0.008 }
                return SIMD3(Float(q.x) + n.x, Float(q.z), Float(q.y) + n.y)
            }
            for p in eng.wires {
                let node = Eng3D.cable(p.points.map(onWall), color: WireKind.find(p.kind)?.color ?? EngKind.electricColor, radius: 0.009)
                node.name = "eng:\(p.id.uuidString)"
                if p.id == engSelected, let first = p.points.first {
                    let ring = Self.ring(false)
                    ring.simdPosition = onWall(first)
                    node.addChildNode(ring)
                }
                engHolder.addChildNode(node)
            }
            if !route.isEmpty, case .wire(let kind)? = engTool {
                let pts = route.count == 1 ? [route[0], route[0] + SIMD3(0, 0, 0.01)] : route
                let preview = Eng3D.cable(pts.map(onWall), color: WireKind.find(kind)?.color ?? EngKind.electricColor, radius: 0.009)
                preview.opacity = 0.75
                engHolder.addChildNode(preview)
            }
            // своих проводов нет — бледная примерная схема (вверх в штробу под потолком и вдоль стены)
            if eng.wires.isEmpty {
                for c in cables() {
                    let node = Eng3D.cable(c)
                    node.opacity = 0.4
                    engHolder.addChildNode(node)
                }
            }
        }
        syncEngVisibility()
    }

    /// Схема проводки: от точки вверх в штробу под потолком и вдоль стены
    private func cables() -> [[SIMD3<Float>]] {
        let lineTop = max(room.height - 0.15, 1.8)
        var out: [[SIMD3<Float>]] = []
        var byWall: [Int: [Engineering.Point]] = [:]
        for p in eng.points where EngKind.find(p.kind)?.group == .electric && p.wall != nil {
            byWall[p.wall!, default: []].append(p)
        }
        let normals = Dictionary(room.walls.map { ($0.index, $0.normal) }, uniquingKeysWith: { a, _ in a })
        for (w, list) in byWall {
            let n = (normals[w] ?? .zero) * 0.006
            for p in list where p.height < Double(lineTop) {
                out.append([SIMD3(Float(p.x) + n.x, Float(p.height) + 0.05, Float(p.y) + n.y),
                            SIMD3(Float(p.x) + n.x, lineTop, Float(p.y) + n.y)])
            }
            let sorted = list.sorted { $0.offset < $1.offset }
            if let a = sorted.first, let b = sorted.last, b.offset - a.offset > 0.01 {
                out.append([SIMD3(Float(a.x) + n.x, lineTop, Float(a.y) + n.y), SIMD3(Float(b.x) + n.x, lineTop, Float(b.y) + n.y)])
            }
        }
        return out
    }

    /// Точки на стене, которую сейчас срезали (вид сверху), прячем вместе со стеной
    func syncEngVisibility() {
        let posOf = Dictionary(room.walls.enumerated().map { ($0.element.index, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for node in engHolder.childNodes {
            guard let name = node.name, name.hasPrefix("eng:"), let id = UUID(uuidString: String(name.dropFirst(4))),
                  let w = engWallOf[id], let pos = posOf[w], pos < wallNodes.count else { continue }
            let hide = wallNodes[pos].isHidden
            if node.isHidden != hide { node.isHidden = hide }
        }
    }

    /// Жёлтое кольцо выбора
    private static func ring(_ ceiling: Bool) -> SCNNode {
        let t = SCNTorus(ringRadius: 0.09, pipeRadius: 0.008)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(red: 0.96, green: 0.77, blue: 0.09, alpha: 1)
        m.emission.contents = UIColor(red: 0.96, green: 0.77, blue: 0.09, alpha: 1)
        m.lightingModel = .constant
        t.firstMaterial = m
        let n = SCNNode(geometry: t)
        n.name = "sel"
        if !ceiling { n.eulerAngles.x = .pi / 2 }
        n.simdPosition.z = ceiling ? 0 : 0.03
        if ceiling { n.simdPosition.y = -0.03 }
        return n
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Панель электрики и сантехники

struct EngPanel: View {
    @ObservedObject var editor: RenoEditor
    @EnvironmentObject var hub: ScanHub
    let scanPipe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hint = editor.engHint {
                Label(hint, systemImage: "hand.tap").font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editor.pendingPipe != nil {
                Button("Отменить привязку трубы", role: .destructive) { editor.cancelPending() }.font(.subheadline.bold())
            } else if let p = editor.selectedPoint, let k = EngKind.find(p.kind) {
                selectedPoint(p, k)
            } else if let pipe = editor.selectedPipe {
                selectedPipe(pipe)
            } else if let wire = editor.selectedWire {
                selectedWire(wire)
            } else {
                tools
            }
            summary
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
    }

    @ViewBuilder private var tools: some View {
        let kinds = EngKind.list(editor.engMode == .electric ? .electric : .plumbing)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(kinds) { k in
                    chip(k.title, k.icon, editor.engTool == .point(k.id)) {
                        editor.setTool(editor.engTool == .point(k.id) ? nil : .point(k.id))
                    }
                }
            }
        }
        if editor.engMode == .electric {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WireKind.all) { k in
                        let on = editor.engTool == .wire(k.id)
                        chip(k.title, "point.topleft.down.to.point.bottomright.curvepath", on) {
                            editor.setTool(on ? nil : .wire(k.id))
                        }
                    }
                }
            }
        }
        if editor.engMode == .plumbing {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PipeKind.all) { k in
                        let on: Bool = { if case .pipe(let id, _)? = editor.engTool { return id == k.id }; return false }()
                        chip("Труба: \(k.title.lowercased())", "line.diagonal", on) {
                            editor.setTool(on ? nil : .pipe(k.id, k.diameter))
                        }
                    }
                    chip("Скан трубы камерой", "camera.viewfinder", false) { hub.pause(); scanPipe() }
                }
            }
        }
        if editor.engTool?.isRoute == true {
            HStack(spacing: 16) {
                Button { editor.finishRoute() } label: { Label("Готово", systemImage: "checkmark") }
                    .disabled(editor.route.count < 2)
                Button { editor.undoRoutePoint() } label: { Label("Убрать точку", systemImage: "arrow.uturn.backward") }
                    .disabled(editor.route.isEmpty)
                Text("точек: \(editor.route.count)").font(.caption).foregroundStyle(.secondary)
            }
            .font(.subheadline.bold())
        }
        if editor.engTool == nil {
            Text(editor.engMode == .electric
                 ? "Крутите модель пальцем или кнопками справа, мебель убирается кнопкой с диваном. Вырезы: выберите розетку или выключатель и нажмите на стену. Провода: выберите провод и ведите нажатиями по стенам. Нажмите на поставленное, чтобы поменять или убрать."
                 : "Выберите, что ставить, и нажмите на стену. Трубы ведите нажатиями по стенам и полу. Нажмите на поставленное, чтобы поменять или убрать.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func selectedPoint(_ p: Engineering.Point, _ k: EngKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: k.icon).foregroundStyle(Color(k.color))
                Text(k.title).font(.headline)
                Spacer()
                Button { editor.engSelected = nil; editor.buildEngineering() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            if let w = p.wall {
                Text("Стена \(w + 1), \(cm(p.offset)) см от угла, высота \(cm(p.height)) см от пола")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button { editor.moveSelected(height: -0.05) } label: { Label("Ниже", systemImage: "arrow.down") }
                    Button { editor.moveSelected(height: 0.05) } label: { Label("Выше", systemImage: "arrow.up") }
                    Spacer()
                    Button(role: .destructive) { editor.removeSelected() } label: { Label("Убрать", systemImage: "trash") }
                }
                .font(.subheadline.bold())
            } else {
                Button(role: .destructive) { editor.removeSelected() } label: { Label("Убрать", systemImage: "trash") }
                    .font(.subheadline.bold())
            }
        }
    }

    private func selectedPipe(_ p: Engineering.Pipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Труба: \(PipeKind.find(p.kind)?.title.lowercased() ?? "")").font(.headline)
                Spacer()
                Button { editor.engSelected = nil; editor.buildEngineering() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            Text("Длина \(fmt((p.length * 100).rounded() / 100)) м, Ø\(p.diameter) мм").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(PipeKind.find(p.kind)?.diameters ?? [], id: \.self) { d in
                    chip("Ø\(d)", nil, d == p.diameter) { editor.setPipeDiameter(d) }
                }
                Spacer()
                Button(role: .destructive) { editor.removeSelected() } label: { Label("Убрать", systemImage: "trash") }
                    .font(.subheadline.bold())
            }
        }
    }

    private func selectedWire(_ p: Engineering.Pipe) -> some View {
        let k = WireKind.find(p.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Color(k?.color ?? EngKind.electricColor)).frame(width: 10, height: 10)
                Text(k?.title ?? "Провод").font(.headline)
                Spacer()
                Button { editor.engSelected = nil; editor.buildEngineering() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(k?.cable ?? "") · длина \(fmt((p.length * 100).rounded() / 100)) м").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { editor.removeSelected() } label: { Label("Убрать", systemImage: "trash") }
                    .font(.subheadline.bold())
            }
        }
    }

    private var summary: some View {
        let e = editor.eng
        let text: String
        if editor.engMode == .electric {
            let cable = e.cableMeters(ceiling: Double(editor.room.height), wallLines: editor.result.wallLines)
            text = "Точек электрики: \(e.count(.electric)) · " + (e.wires.isEmpty
                ? "кабель ≈ \(Int(cable.rounded(.up))) м (примерно — проведите провода сами, будет точнее)"
                : "провода \(Int(cable.rounded(.up))) м с запасом")
        } else {
            let pipes = e.pipeMeters.map { "\($0.0.title.lowercased()) \(fmt(($0.1 * 10).rounded() / 10)) м" }.joined(separator: ", ")
            text = "Выводов сантехники: \(e.count(.plumbing))" + (pipes.isEmpty ? "" : " · трубы: \(pipes)")
        }
        return Text(text).font(.caption.bold()).foregroundStyle(.secondary)
    }

    private func chip(_ title: String, _ icon: String?, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(on ? Palette.signal : Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(on ? Palette.ink : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func cm(_ v: Double) -> Int { Int((v * 100).rounded()) }
}
