import ARKit
import AVFoundation
import RoomPlan
import SceneKit
import SwiftUI

/// Экран скана: камера ARKit, лидар и распознавание — Apple RoomPlan, а линии рисуем сами.
/// Стены Apple во время съёмки «плывут» и двоятся, поэтому показываем выпрямленные: прямые углы,
/// куски одной стены — одна стена, углы сомкнуты. Где доснять — жёлтый пунктир прямо в комнате.
struct RoomScanner: UIViewRepresentable {
    @ObservedObject var controller: ScanController

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        controller.start(in: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
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

final class ScanController: NSObject, ObservableObject {
    let session = RoomCaptureSession()
    let watcher = LiveWatcher()
    private let overlay = LiveOverlay()
    @Published var result: RoomResult?
    @Published var failed: String?
    @Published var finishing = false
    /// Подсказка поверх камеры и важная ли она
    @Published var hint: String?
    @Published var hintWarn = false
    /// Что ещё не снято (по живому скану)
    @Published var liveIssues: [String] = []
    @Published var counts = ""
    @Published var torchOn = false
    /// Мини-план по выпрямленным стенам и где сейчас телефон: x, z и куда смотрит
    @Published var plan = LivePlan()
    @Published var me: SIMD3<Double>?
    let hasTorch = Torch.available
    /// Кадр камеры в момент «Готово» — фото комнаты для ИИ-ремонта
    private var photo: Data?
    private var instruction: String?
    private var instructionAt = Date.distantPast
    private let started = Date()
    private var ticks = 0
    /// Последний живой скан, его подгонка и угол сетки (чтобы линии не дёргались)
    private var latest: CapturedRoom?
    private var rect: Rectify.Result?
    private var gridAngle: Double?
    private var drawnAt = Date.distantPast
    private var drawQueued = false
    private var running = false
    private var cancelled = false

    private static let tips = [
        "Снимите все углы комнаты — медленно, по кругу",
        "Загляните за диван и шкаф: обойдите мебель с двух сторон",
        "Наведите камеру на пол и на потолок у стен",
        "Задержитесь у окон и дверей на пару секунд",
        "Держитесь в 1–3 метрах от стен",
    ]

    override init() {
        super.init()
        watcher.onRoom = { [weak self] room in self?.received(room) }
        watcher.onInstruction = { [weak self] instruction in self?.coach(instruction) }
        watcher.onEnd = { [weak self] data, error in self?.ended(data, error) }
        session.delegate = watcher
    }

    /// Камера — сессия RoomPlan (второй ARSession не запускаем), поверх — наши линии
    func start(in view: ARSCNView) {
        view.session = session.arSession
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.antialiasingMode = .multisampling4X
        view.scene.rootNode.addChildNode(overlay.root)
        guard !running, !cancelled else { return }
        running = true
        session.run(configuration: RoomCaptureSession.Configuration())
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        if let buffer = session.arSession.currentFrame?.capturedImage {
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
        guard running else { return }
        running = false
        session.stop()
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
        overlay.update(room, rect)
        plan = LivePlan(rect)
        let windows = room.windows.count, doors = room.doors.count + room.openings.count
        counts = "Стен: \(rect.walls.count) · окон: \(windows) · дверей: \(doors) · мебели: \(room.objects.count)"
        liveIssues = RoomResult.liveIssues(room, rect, where: gapPlace())
    }

    /// Где телефон и куда смотрит — для мини-плана (несколько раз в секунду)
    func trackCamera() {
        guard !finishing, let t = session.arSession.currentFrame?.camera.transform else { return }
        let pos = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
        let f = SIMD2(Double(-t.columns.2.x), Double(-t.columns.2.z))
        // смотрит в пол или потолок — направление оставляем прежним
        let heading = simd_length(f) > 0.15 ? atan2(f.y, f.x) : (me?.z ?? 0)
        if let me, simd_distance(SIMD2(me.x, me.y), pos) < 0.03, abs(remainder(me.z - heading, 2 * Double.pi)) < 0.05 { return }
        me = SIMD3(pos.x, pos.y, heading)
    }

    /// Где ближайший жёлтый пунктир относительно телефона: «справа, 2 м»
    private func gapPlace() -> String? {
        guard let rect, let me else { return nil }
        let pos = SIMD2(me.x, me.y)
        let fwd = SIMD2(cos(me.z), sin(me.z)), right = SIMD2(-fwd.y, fwd.x)
        var best: SIMD2<Double>?
        var bestDist = Double.greatestFiniteMagnitude
        for g in rect.gaps where g.kind != .hole {
            for (p, q) in zip(g.path, g.path.dropFirst()) {
                let ab = q - p
                let l2 = simd_dot(ab, ab)
                let t = l2 > 0 ? max(0, min(1, simd_dot(pos - p, ab) / l2)) : 0
                let c = p + ab * t
                let d = simd_distance(c, pos)
                if d < bestDist { bestDist = d; best = c }
            }
        }
        guard let best else { return nil }
        let v = best - pos
        if bestDist < 1 { return "рядом с вами" }
        let ang = abs(atan2(simd_dot(v, right), simd_dot(v, fwd))) / Rectify.deg
        let side: String
        if ang < 35 { side = "впереди" } else if ang < 125 { side = simd_dot(v, right) > 0 ? "справа" : "слева" } else { side = "сзади" }
        return "\(side), \(Int(bestDist.rounded())) м"
    }

    // MARK: - Готово: собираем комнату

    private func ended(_ data: CapturedRoomData, _ error: Error?) {
        guard !cancelled else { return }
        running = false
        // RoomPlan мог остановиться сам (телефон перегрелся, камера потерялась) — собираем, что успели
        finishing = true
        overlay.clear()
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

    /// Раз в секунду: что сказать человеку прямо сейчас
    func poll() {
        ticks += 1
        guard !finishing, let frame = session.arSession.currentFrame else { return }
        var text: String?
        if Date().timeIntervalSince(instructionAt) < 2.5 { text = instruction }
        if text == nil { text = ScanController.trackingHint(frame.camera.trackingState) }
        if text == nil, !torchOn, ScanController.isDark(frame) {
            text = hasTorch ? "Темновато — включите фонарик кнопкой вверху" : "Темновато — включите свет в комнате"
        }
        if text == nil, Date().timeIntervalSince(started) > 10, let first = liveIssues.first { text = first }
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
                        if controller.liveIssues.isEmpty { controller.finish() } else { askFinish = true }
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
                if !controller.counts.isEmpty && !controller.finishing {
                    Text(controller.counts)
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.45), in: Capsule())
                }
            }
            .padding()
        }
        .overlay(alignment: .bottomLeading) {
            if !controller.plan.isEmpty && !controller.finishing {
                VStack(alignment: .leading, spacing: 6) {
                    MiniPlanView(plan: controller.plan, me: controller.me)
                    HStack(spacing: 6) {
                        DashSample().stroke(Palette.signal, style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
                            .frame(width: 22, height: 3)
                        Text("доснять").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.45), in: Capsule())
                }
                .padding()
                .allowsHitTesting(false)
            }
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
            if controller.result == nil { controller.cancel() }
        }
        .onChange(of: controller.result != nil) { ready in
            if ready, let r = controller.result { onResult(r); dismiss() }
        }
        .alert("Ещё не всё снято", isPresented: $askFinish) {
            Button("Доснять", role: .cancel) {}
            Button("Закончить так") { controller.finish() }
        } message: {
            Text(controller.liveIssues.prefix(3).joined(separator: "\n"))
        }
        .alert("Скан не получился", isPresented: .constant(controller.failed != nil)) {
            Button("Понятно") { controller.failed = nil; dismiss() }
        } message: { Text(controller.failed ?? "") }
    }
}

/// Образец пунктира для подписи под мини-планом
struct DashSample: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
