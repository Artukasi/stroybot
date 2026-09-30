import ARKit
import AVFoundation
import RoomPlan
import SwiftUI

/// Экран Apple RoomPlan: лидар строит стены, окна и двери прямо в камере.
struct RoomScanner: UIViewRepresentable {
    @ObservedObject var controller: ScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = controller
        // подсказки по ходу съёмки: RoomPlan сам сообщает, что мешает и что уже снято
        view.captureSession.delegate = controller.watcher
        controller.view = view
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

/// Слушает RoomPlan во время съёмки и передаёт события на главный поток
final class LiveWatcher: NSObject, RoomCaptureSessionDelegate {
    var onRoom: ((CapturedRoom) -> Void)?
    var onInstruction: ((RoomCaptureSession.Instruction) -> Void)?

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let handler = onRoom
        DispatchQueue.main.async { handler?(room) }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let handler = onInstruction
        DispatchQueue.main.async { handler?(instruction) }
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
    /// Что ещё не снято (по живому скану)
    @Published var liveIssues: [String] = []
    @Published var counts = ""
    @Published var torchOn = false
    let hasTorch = Torch.available
    /// Кадр камеры в момент «Готово» — фото комнаты для ИИ-ремонта
    private var photo: Data?
    private var instruction: String?
    private var instructionAt = Date.distantPast
    private let started = Date()
    private var ticks = 0

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
        watcher.onRoom = { [weak self] room in self?.update(room) }
        watcher.onInstruction = { [weak self] instruction in self?.coach(instruction) }
    }

    func finish() {
        finishing = true
        if let buffer = view?.captureSession.arSession.currentFrame?.capturedImage {
            photo = RoomResult.jpeg(from: buffer)
        }
        view?.captureSession.stop()
    }

    func cancel() {
        setTorch(false)
        view?.captureSession.stop()
    }

    func toggleTorch() { setTorch(!torchOn) }

    func setTorch(_ on: Bool) {
        guard hasTorch else { return }
        torchOn = Torch.set(on)
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

    private func update(_ room: CapturedRoom) {
        let windows = room.windows.count, doors = room.doors.count + room.openings.count
        counts = "Стен: \(room.walls.count) · окон: \(windows) · дверей: \(doors) · мебели: \(room.objects.count)"
        liveIssues = RoomResult.liveIssues(room)
    }

    /// Раз в секунду: что сказать человеку прямо сейчас
    func poll() {
        ticks += 1
        guard !finishing, let frame = view?.captureSession.arSession.currentFrame else { return }
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

    // MARK: - RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error { DispatchQueue.main.async { self.failed = error.localizedDescription } }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        var result = RoomResult(processedResult)
        result.photo = photo
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Комната.usdz")
        try? FileManager.default.removeItem(at: url)
        if (try? processedResult.export(to: url)) != nil { result.usdz = url }
        DispatchQueue.main.async {
            self.finishing = false
            self.setTorch(false)
            if let error { self.failed = error.localizedDescription }
            if result.walls.isEmpty { self.failed = "Не нашёл стен. Пройдите по комнате медленнее и снимите все углы." }
            else { self.result = result }
        }
    }
}

struct ScanScreen: View {
    @StateObject private var controller = ScanController()
    @Environment(\.dismiss) private var dismiss
    @State private var askFinish = false
    let onResult: (RoomResult) -> Void
    private let tick = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

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
        .onReceive(tick) { _ in controller.poll() }
        .onDisappear { controller.setTorch(false) }
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
