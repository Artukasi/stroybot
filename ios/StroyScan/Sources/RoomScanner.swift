import ARKit
import AVFoundation
import RoomPlan
import SwiftUI
import UIKit

/// Экран скана — стандартный вид Apple RoomPlan: живая 3D-модель комнаты прямо в камере (контуры стен,
/// окон и дверей, коробки мебели). RoomPlan сам уточняет её, когда камера снова видит стену или предмет.
/// Своего поверх камеры не рисуем — ни пунктира, ни заливки. Выпрямленная комната — на мини-плане и в итоге.
struct RoomScanner: UIViewRepresentable {
    @ObservedObject var controller: ScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        controller.start(in: view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

/// Слушает RoomPlan во время съёмки и передаёт события на главный поток
final class LiveWatcher: NSObject, RoomCaptureSessionDelegate {
    var onRoom: ((CapturedRoom) -> Void)?
    var onInstruction: ((RoomCaptureSession.Instruction) -> Void)?
    var onEnd: ((CapturedRoomData, Error?) -> Void)?

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let handler = onRoom
        DispatchQueue.main.async { handler?(room) }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let handler = onInstruction
        DispatchQueue.main.async { handler?(instruction) }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        let handler = onEnd
        DispatchQueue.main.async { handler?(data, error) }
    }
}

/// Фонарик телефона. Работает и во время съёмки лидаром.
enum Torch {
    static var device: AVCaptureDevice? { AVCaptureDevice.default(for: .video) }
    static var available: Bool { device?.hasTorch ?? false }

    /// Включает или выключает, возвращает, что получилось
    @discardableResult
    static func set(_ on: Bool, device: AVCaptureDevice? = Torch.device) -> Bool {
        guard let device, device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on && device.isTorchAvailable {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                return true
            }
            device.torchMode = .off
            return false
        } catch {
            return false
        }
    }
}

final class ScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    weak var view: RoomCaptureView?
    let watcher = LiveWatcher()
    @Published var result: RoomResult?
    @Published var failed: String?
    @Published var finishing = false
    /// Подсказка поверх камеры и важная ли она
    @Published var hint: String?
    @Published var hintWarn = false
    /// Что ещё не снято — считается в момент «Готово», для окна «Ещё не всё снято»
    @Published var unfinished: [String] = []
    @Published var counts = ""
    @Published var torchOn = false
    /// Мини-план по выпрямленным стенам и мебели и где сейчас телефон: x, z и куда смотрит
    @Published var plan = LivePlan()
    @Published var me: SIMD3<Double>?
    let hasTorch = Torch.available
    /// Кадр камеры в момент «Готово» — фото комнаты для ИИ-ремонта
    private var photo: Data?
    private var instruction: String?
    private var instructionAt = Date.distantPast
    private let started = Date()
    private var ticks = 0
    /// Последний живой скан, его подгонка и угол сетки (чтобы линии не дёргались).
    /// Подгонку каждый раз считаем заново по всему свежему скану: уже снятые стены, углы и мебель
    /// тоже подстраиваются под новые замеры RoomPlan
    private var latest: CapturedRoom?
    private var rect: Rectify.Result?
    private var gridAngle: Double?
    private var drawnAt = Date.distantPast
    private var drawQueued = false
    private var running = false
    private var cancelled = false
    private var building = false
    /// Места живого скана, которые стоит доснять, и что ещё не видно (дверь, мебель)
    private var marks: [RoomResult.LiveMark] = []
    private var extras: [String] = []
    /// Сколько секунд камера смотрела на клетки пола у мест «доснять» (0,5 × 0,5 м). Место снято — счёт с нуля
    private var looked: [SIMD2<Int32>: Double] = [:]
    private var marked = Set<SIMD2<Int32>>()
    private var lookedTick: Date?
    /// Куда показывает подсказка: держим сторону и метры, пока телефон чуть поворачивают
    private var placeTarget: SIMD2<Double>?
    private var placeSide: Side?
    private var placeMeters: Int?
    private var placeNear = false

    /// Клетка пола, сколько метров и в каком конусе камера «смотрит» на место, сколько секунд — и место точно проблемное
    static let cellSize = 0.5
    static let lookRange = 2.5
    static let lookAngle = 35 * Rectify.deg
    static let realAfter = 3.0

    private static let tips = [
        "Снимите все углы комнаты — медленно, по кругу",
        "Загляните за диван и шкаф: обойдите мебель с двух сторон",
        "Наведите камеру на пол и на потолок у стен",
        "Задержитесь у окон и дверей на пару секунд",
        "Держитесь в 1–3 метрах от стен",
    ]

    override init() {
        super.init()
        listen()
    }
    // RoomCaptureViewDelegate требует NSCoding
    required init?(coder: NSCoder) {
        super.init()
        listen()
    }
    func encode(with coder: NSCoder) {}

    private func listen() {
        watcher.onRoom = { [weak self] room in self?.received(room) }
        watcher.onInstruction = { [weak self] instruction in self?.coach(instruction) }
        watcher.onEnd = { [weak self] data, error in self?.ended(data, error) }
    }

    /// Сессия вида RoomPlan: её живой скан и подсказки слушаем сами, 3D-модель вид рисует сам
    private var session: RoomCaptureSession? { view?.captureSession }
    private var frame: ARFrame? { session?.arSession.currentFrame }

    func start(in view: RoomCaptureView) {
        self.view = view
        view.delegate = self
        view.captureSession.delegate = watcher
        guard !running, !cancelled else { return }
        running = true
        // скан идёт минуту-две без касаний: экран не должен гаснуть и блокироваться
        UIApplication.shared.isIdleTimerDisabled = true
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        if let buffer = frame?.capturedImage {
            photo = RoomResult.jpeg(from: buffer)
        }
        stop()
    }

    func cancel() {
        cancelled = true
        setTorch(false)
        stop()
    }

    private func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard running else { return }
        running = false
        session?.stop()
    }

    func toggleTorch() { setTorch(!torchOn) }

    func setTorch(_ on: Bool) {
        guard hasTorch else { return }
        torchOn = Torch.set(on)
    }

    // MARK: - Живой скан

    /// RoomPlan присылает скан часто: перерисовываем не чаще ~7 раз в секунду
    private func received(_ room: CapturedRoom) {
        latest = room
        guard !drawQueued else { return }
        drawQueued = true
        let wait = max(0, 0.15 - Date().timeIntervalSince(drawnAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.drawQueued = false
            self?.redraw()
        }
    }

    private func redraw() {
        guard let room = latest, !finishing, !cancelled else { return }
        drawnAt = Date()
        let rect = RoomResult.rectify(room, prev: gridAngle)
        gridAngle = rect.angle
        self.rect = rect
        plan = LivePlan(rect, room)
        marks = rect.walls.count >= 3 ? RoomResult.liveMarks(rect) : []
        extras = RoomResult.liveExtras(room)
        marked = Set(marks.flatMap { ScanController.samples($0.path) }.compactMap(ScanController.cell))
        looked = looked.filter { marked.contains($0.key) }
        let windows = room.windows.count, doors = room.doors.count + room.openings.count
        counts = "Стен: \(rect.wallCount) · окон: \(windows) · дверей: \(doors) · мебели: \(room.objects.count)"
    }

    /// Где телефон и куда смотрит — для мини-плана и подсказок (несколько раз в секунду)
    func trackCamera() {
        guard !finishing, let t = frame?.camera.transform else { return }
        let pos = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
        let f = SIMD2(Double(-t.columns.2.x), Double(-t.columns.2.z))
        // смотрит в пол или потолок — направление оставляем прежним
        let heading = simd_length(f) > 0.15 ? atan2(f.y, f.x) : (me?.z ?? 0)
        look(pos, heading)
        if let me, simd_distance(SIMD2(me.x, me.y), pos) < 0.03, abs(remainder(me.z - heading, 2 * Double.pi)) < 0.05 { return }
        me = SIMD3(pos.x, pos.y, heading)
    }

    /// Копит, сколько камера смотрела на места «доснять»: клетки до 2,5 м впереди, в пределах ±35°
    private func look(_ pos: SIMD2<Double>, _ heading: Double) {
        let now = Date()
        let dt = min(0.5, lookedTick.map { now.timeIntervalSince($0) } ?? 0)
        lookedTick = now
        guard dt > 0 else { return }
        let fwd = SIMD2(cos(heading), sin(heading))
        let size = ScanController.cellSize
        for c in marked {
            let center = SIMD2(Double(c.x) + 0.5, Double(c.y) + 0.5) * size
            let v = center - pos
            let d = simd_length(v)
            if d > ScanController.lookRange { continue }
            if d > size && simd_dot(v / d, fwd) < cos(ScanController.lookAngle) { continue }
            looked[c, default: 0] += dt
        }
    }

    /// Точки ломаной через каждые 0,3 м (с концами)
    private static func samples(_ path: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard let first = path.first else { return [] }
        var out = [first]
        for (p, q) in zip(path, path.dropFirst()) {
            let n = max(1, Int((simd_distance(p, q) / 0.3).rounded(.up)))
            for k in 1...n { out.append(p + (q - p) * (Double(k) / Double(n))) }
        }
        return out
    }

    private static func cell(_ p: SIMD2<Double>) -> SIMD2<Int32>? {
        guard p.x.isFinite, p.y.isFinite, abs(p.x) < 10_000, abs(p.y) < 10_000 else { return nil }
        return SIMD2(Int32((p.x / cellSize).rounded(.down)), Int32((p.y / cellSize).rounded(.down)))
    }

    /// На место уже смотрели несколько секунд, а оно так и не снято — значит, правда надо доснять
    private func isReal(_ m: RoomResult.LiveMark) -> Bool {
        ScanController.samples(m.path).contains { p in ScanController.cell(p).map { looked[$0, default: 0] >= ScanController.realAfter } ?? false }
    }

    /// Ближайшее к телефону место из списка и точка на нём
    private static func nearest(_ list: [RoomResult.LiveMark], to pos: SIMD2<Double>) -> (RoomResult.LiveMark, SIMD2<Double>)? {
        var best: (RoomResult.LiveMark, SIMD2<Double>)?
        var bestDist = Double.greatestFiniteMagnitude
        for m in list {
            for (p, q) in zip(m.path, m.path.dropFirst()) {
                let (d, c) = RoomResult.segmentDistance(pos, p, q)
                if d < bestDist {
                    bestDist = d
                    best = (m, c)
                }
            }
        }
        return best
    }

    /// Сторона относительно взгляда; угол в градусах, плюс — справа
    private enum Side {
        case ahead, right, behind, left

        init(_ a: Double) {
            if abs(a) < 35 {
                self = .ahead
            } else if abs(a) < 125 {
                self = a > 0 ? .right : .left
            } else {
                self = .behind
            }
        }

        /// Угол ещё в этой стороне, с запасом margin градусов за границу
        func holds(_ a: Double, margin m: Double) -> Bool {
            switch self {
            case .ahead: return abs(a) < 35 + m
            case .right: return a > 35 - m && a < 125 + m
            case .left: return a < -35 + m && a > -125 - m
            case .behind: return abs(a) > 125 - m
            }
        }

        var word: String {
            switch self {
            case .ahead: return "впереди"
            case .right: return "справа"
            case .behind: return "сзади"
            case .left: return "слева"
            }
        }
    }

    /// Угол от взгляда к точке, градусы (−180…180, плюс — справа)
    private static func bearing(_ v: SIMD2<Double>, _ heading: Double) -> Double {
        let fwd = SIMD2(cos(heading), sin(heading)), right = SIMD2(-fwd.y, fwd.x)
        return atan2(simd_dot(v, right), simd_dot(v, fwd)) / Rectify.deg
    }

    /// «справа, 2 м» — как есть, для списка в окне «Ещё не всё снято»
    private static func place(_ target: SIMD2<Double>, from me: SIMD3<Double>) -> String {
        let v = target - SIMD2(me.x, me.y)
        let d = simd_length(v)
        if d < 1 { return "рядом с вами" }
        return "\(Side(bearing(v, me.z)).word), \(max(1, Int(d.rounded()))) м"
    }

    /// «справа, 2 м» без дрожи: сторона меняется, только когда ушла за границу на 10°, метры — с запасом 0,8 м
    private func steadyPlace(_ target: SIMD2<Double>, from me: SIMD3<Double>) -> String {
        if let t = placeTarget, simd_distance(t, target) > 0.7 {
            placeSide = nil
            placeMeters = nil
            placeNear = false
        }
        placeTarget = target
        let v = target - SIMD2(me.x, me.y)
        let d = simd_length(v)
        placeNear = placeNear ? d < 1.3 : d < 1.0
        if placeNear { return "рядом с вами" }
        let ang = ScanController.bearing(v, me.z)
        let side = placeSide.flatMap { $0.holds(ang, margin: 10) ? $0 : nil } ?? Side(ang)
        placeSide = side
        let meters = placeMeters.flatMap { abs(d - Double($0)) <= 0.8 ? $0 : nil } ?? max(1, Int(d.rounded()))
        placeMeters = meters
        return "\(side.word), \(meters) м"
    }

    /// Подсказка про места «доснять». Пока комнату обходят — куда идти дальше. Предупреждение — только когда
    /// комната обойдена, а на место уже смотрели несколько секунд и оно так и не снято
    private func markHint() -> (String, Bool)? {
        guard let rect else { return nil }
        if rect.walls.count < 3 { return ("Пока видно мало стен — медленно обведите камерой всю комнату", false) }
        guard let me, !marks.isEmpty else { return nil }
        // контур не замкнулся, есть открытый конец или пропущенная стена — комнату ещё обходят
        let covered = !rect.loop.isEmpty && !marks.contains { $0.inProgress }
        let real = covered ? marks.filter(isReal) : []
        guard let (mark, point) = ScanController.nearest(real.isEmpty ? marks : real, to: SIMD2(me.x, me.y)) else { return nil }
        let place = steadyPlace(point, from: me)
        if !real.isEmpty { return ("\(mark.text) — \(place)", true) }
        return (covered ? "Доснимите: \(mark.text.lowercasedFirst) — \(place)" : "Снимайте дальше по кругу — \(place)", false)
    }

    /// «Готово»: что ещё не снято, с местами, и чего не видно — прямо сейчас
    func checkFinish() -> [String] {
        var out: [String] = []
        if let rect, rect.walls.count < 3 { out.append("Видно мало стен — обведите камерой всю комнату") }
        // ближние места — первыми, одинаковые строки — один раз
        var lines: [(Double, String)] = []
        for m in marks {
            if let me, let found = ScanController.nearest([m], to: SIMD2(me.x, me.y)) {
                lines.append((simd_distance(found.1, SIMD2(me.x, me.y)), "\(m.text) — \(ScanController.place(found.1, from: me))"))
            } else {
                lines.append((0, m.text))
            }
        }
        var seen = Set<String>()
        for (_, line) in lines.sorted(by: { $0.0 < $1.0 }) where seen.insert(line).inserted { out.append(line) }
        out += extras
        unfinished = out
        return out
    }

    /// Текст окна «Ещё не всё снято»: первые четыре места и сколько ещё
    var unfinishedText: String {
        var shown = Array(unfinished.prefix(4))
        if unfinished.count > 4 { shown.append("и ещё \(unfinished.count - 4)") }
        return shown.joined(separator: "\n")
    }

    // MARK: - Готово: собираем комнату

    /// Скан закончился: данные приходят и от сессии, и от вида RoomPlan — собираем один раз
    private func ended(_ data: CapturedRoomData, _ error: Error?) {
        UIApplication.shared.isIdleTimerDisabled = false
        guard !cancelled, !building else { return }
        building = true
        running = false
        // RoomPlan мог остановиться сам (телефон перегрелся, камера потерялась) — собираем, что успели
        finishing = true
        let photo = self.photo
        Task {
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                let result = ScanController.build(room, photo: photo)
                await MainActor.run { self.done(result) }
            } catch let built {
                let text = ScanController.failText(error ?? built)
                await MainActor.run { self.fail(text) }
            }
        }
    }

    /// Итог скана: размеры по выпрямленным стенам, фото и файл 3D-модели
    private static func build(_ room: CapturedRoom, photo: Data?) -> RoomResult {
        var result = RoomResult(room)
        result.photo = photo
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Комната.usdz")
        try? FileManager.default.removeItem(at: url)
        if (try? room.export(to: url)) != nil { result.usdz = url }
        return result
    }

    private static func failText(_ error: Error) -> String {
        let text = "Не получилось собрать комнату. Пройдите по комнате медленнее, при хорошем свете, и снимите все углы."
        let reason = error.localizedDescription
        return reason.isEmpty ? text : text + "\n\n" + reason
    }

    // MARK: - RoomCaptureViewDelegate

    /// Комнату собираем сами (RoomBuilder, ровная мебель) — вид RoomPlan её не обрабатывает
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        DispatchQueue.main.async { self.ended(roomDataForProcessing, error) }
        return false
    }

    private func done(_ r: RoomResult) {
        guard !cancelled else { return }
        finishing = false
        setTorch(false)
        if r.walls.isEmpty { failed = "Не нашёл стен. Пройдите по комнате медленнее и снимите все углы." } else { result = r }
    }

    private func fail(_ text: String) {
        guard !cancelled else { return }
        finishing = false
        setTorch(false)
        failed = text
    }

    // MARK: - Подсказки

    private func coach(_ i: RoomCaptureSession.Instruction) {
        switch i {
        case .moveCloseToWall: instruction = "Подойдите ближе к стене"
        case .moveAwayFromWall: instruction = "Отойдите от стены на 1–2 метра"
        case .slowDown: instruction = "Ведите телефон медленнее"
        case .turnOnLight: instruction = hasTorch && !torchOn ? "Темно — включите фонарик кнопкой вверху" : "Темно — включите свет в комнате"
        case .lowTexture: instruction = "Мало деталей — наведите камеру на углы и мебель"
        case .normal: instruction = nil
        @unknown default: instruction = nil
        }
        if instruction != nil { instructionAt = Date() }
    }

    /// Примерно раз в секунду: что сказать человеку прямо сейчас
    func poll() {
        ticks += 1
        guard !finishing, let frame else { return }
        var text: String?
        if Date().timeIntervalSince(instructionAt) < 2.5 { text = instruction }
        if text == nil { text = ScanController.trackingHint(frame.camera.trackingState) }
        if text == nil, !torchOn, ScanController.isDark(frame) {
            text = hasTorch ? "Темновато — включите фонарик кнопкой вверху" : "Темновато — включите свет в комнате"
        }
        let settled = Date().timeIntervalSince(started) > 10
        if text == nil, settled, let (say, warn) = markHint() {
            hint = say
            hintWarn = warn
            return
        }
        if text == nil, settled, let first = extras.first { text = first }
        if let text {
            hint = text
            hintWarn = true
        } else {
            hint = ScanController.tips[(ticks / 6) % ScanController.tips.count]
            hintWarn = false
        }
    }

    private static func trackingHint(_ state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal: return nil
        case .notAvailable: return "Камера не видит комнату — наведите её на стены"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "Ведите телефон медленнее"
            case .insufficientFeatures: return "Камере не за что зацепиться — наведите её на углы и мебель"
            case .initializing: return "Подождите секунду — камера настраивается"
            case .relocalizing: return "Вернитесь туда, откуда начали съёмку"
            @unknown default: return nil
            }
        }
    }

    /// Темно ли в кадре: оценка света ARKit и средняя яркость картинки
    private static func isDark(_ frame: ARFrame) -> Bool {
        if let light = frame.lightEstimate, light.ambientIntensity < 250 { return true }
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) > 0 else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return false }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, count = 0
        for y in stride(from: 0, to: h, by: max(1, h / 24)) {
            for x in stride(from: 0, to: w, by: max(1, w / 32)) {
                sum += Int(luma[y * row + x])
                count += 1
            }
        }
        return count > 0 && Double(sum) / Double(count) < 45
    }
}

struct ScanScreen: View {
    @StateObject private var controller = ScanController()
    @Environment(\.dismiss) private var dismiss
    @State private var askFinish = false
    let onResult: (RoomResult) -> Void
    private let tick = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()
    private let fast = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            RoomScanner(controller: controller).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("Отмена") { controller.cancel(); dismiss() }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if controller.hasTorch {
                        Button { controller.toggleTorch() } label: {
                            Image(systemName: controller.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(controller.torchOn ? Palette.signal : Color.clear, in: Circle())
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundStyle(controller.torchOn ? Palette.ink : Color.primary)
                        }
                        .accessibilityLabel(controller.torchOn ? "Выключить фонарик" : "Включить фонарик")
                    }
                    Button {
                        if controller.checkFinish().isEmpty { controller.finish() } else { askFinish = true }
                    } label: {
                        Text(controller.finishing ? "Считаю…" : "Готово").bold()
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Palette.signal, in: Capsule())
                            .foregroundStyle(Palette.ink)
                    }
                    .disabled(controller.finishing)
                }
                if let hint = controller.hint, !controller.finishing {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: controller.hintWarn ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                            .foregroundStyle(controller.hintWarn ? Palette.signal : Color.white)
                        Text(hint).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                    .animation(.easeInOut(duration: 0.25), value: hint)
                }
                if !controller.finishing {
                    // внизу экрана — 3D-модель RoomPlan, поэтому мини-план сверху, справа от счётчиков
                    HStack(alignment: .top, spacing: 10) {
                        if !controller.counts.isEmpty {
                            Text(controller.counts)
                                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Spacer(minLength: 0)
                        if !controller.plan.isEmpty {
                            MiniPlanView(plan: controller.plan, me: controller.me)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .padding()
        }
        .overlay {
            if controller.finishing {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Собираю комнату…").font(.headline).foregroundStyle(.white)
                }
                .padding(24)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .onReceive(tick) { _ in controller.poll() }
        .onReceive(fast) { _ in controller.trackCamera() }
        .onDisappear {
            controller.setTorch(false)
            UIApplication.shared.isIdleTimerDisabled = false
            if controller.result == nil { controller.cancel() }
        }
        .onChange(of: controller.result != nil) { ready in
            if ready, let r = controller.result { onResult(r); dismiss() }
        }
        .alert("Ещё не всё снято", isPresented: $askFinish) {
            Button("Доснять", role: .cancel) {}
            Button("Закончить так") { controller.finish() }
        } message: {
            Text(controller.unfinishedText)
        }
        .alert("Скан не получился", isPresented: .constant(controller.failed != nil)) {
            Button("Понятно") { controller.failed = nil; dismiss() }
        } message: { Text(controller.failed ?? "") }
    }
}
