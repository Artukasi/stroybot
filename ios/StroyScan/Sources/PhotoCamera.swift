import AVFoundation
import SwiftUI
import UIKit

/// Камера для фото комнаты: 0,5× / 1× / 2×, приближение двумя пальцами, фонарик.
final class PhotoCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "stroyscan.camera")
    private var device: AVCaptureDevice?
    /// videoZoomFactor, который на кнопках называется «1×» (у двойной широкоугольной камеры 1.0 — это 0,5×)
    private var base: CGFloat = 1
    private var configured = false

    @Published var zoom: CGFloat = 1
    @Published var torch = false
    @Published var hasTorch = false
    @Published var hasUltraWide = false
    @Published var denied = false
    @Published var shot: UIImage?
    @Published var busy = false

    var presets: [CGFloat] { hasUltraWide ? [0.5, 1, 2] : [1, 2] }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.configure() } else { self.denied = true }
                }
            }
        default:
            denied = true
        }
    }

    func stop() {
        setTorch(false)
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() {
        queue.async {
            if self.configured {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            // виртуальная камера сама переключает объективы при зуме
            let order: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera,
                                                       .builtInDualCamera, .builtInWideAngleCamera]
            let found = AVCaptureDevice.DiscoverySession(deviceTypes: order, mediaType: .video, position: .back).devices
            var picked: AVCaptureDevice?
            for type in order {
                if let d = found.first(where: { $0.deviceType == type }) { picked = d; break }
            }
            guard let device = picked ?? AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if self.session.canAddInput(input) { self.session.addInput(input) }
            if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            self.session.commitConfiguration()
            let ultra = device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera
            self.base = ultra ? CGFloat(device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2) : 1
            self.device = device
            self.configured = true
            self.session.startRunning()
            self.apply(zoom: 1, animated: false)
            let torch = device.hasTorch
            DispatchQueue.main.async {
                self.hasUltraWide = ultra
                self.hasTorch = torch
            }
        }
    }

    /// Зум как на кнопках камеры: 0.5, 1, 2…
    func setZoom(_ z: CGFloat, animated: Bool = true) {
        queue.async { self.apply(zoom: z, animated: animated) }
    }

    private func apply(zoom z: CGFloat, animated: Bool) {
        guard let device else { return }
        let hi = min(device.maxAvailableVideoZoomFactor, base * 10)
        let factor = min(max(z * base, device.minAvailableVideoZoomFactor), hi)
        do {
            try device.lockForConfiguration()
            if animated { device.ramp(toVideoZoomFactor: factor, withRate: 12) } else { device.videoZoomFactor = factor }
            device.unlockForConfiguration()
        } catch {
            return
        }
        let shown = factor / base
        DispatchQueue.main.async { self.zoom = shown }
    }

    func setTorch(_ on: Bool) {
        let target = device
        queue.async {
            let result = Torch.set(on, device: target)
            DispatchQueue.main.async { self.torch = result }
        }
    }

    func capture() {
        busy = true
        queue.async {
            if let connection = self.output.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.busy = false
            self.shot = image
        }
    }
}

/// Живая картинка с камеры
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}
}

/// Экран съёмки фото комнаты для ремонта
struct PhotoCameraView: View {
    @StateObject private var camera = PhotoCamera()
    @Environment(\.dismiss) private var dismiss
    @State private var pinchStart: CGFloat?
    let onPhoto: (Data) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.denied {
                VStack(spacing: 16) {
                    Text("Нет доступа к камере").font(.headline).foregroundStyle(.white)
                    Text("Разрешите: Настройки → СтройСкан → Камера.")
                        .foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    Button("Закрыть") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding()
            } else if let shot = camera.shot {
                review(shot)
            } else {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .gesture(MagnificationGesture()
                        .onChanged { scale in
                            if pinchStart == nil { pinchStart = camera.zoom }
                            camera.setZoom((pinchStart ?? 1) * scale, animated: false)
                        }
                        .onEnded { _ in pinchStart = nil })
                controls
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3.bold())
                        .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if camera.hasTorch {
                    Button { camera.setTorch(!camera.torch) } label: {
                        Image(systemName: camera.torch ? "flashlight.on.fill" : "flashlight.off.fill").font(.title3)
                            .frame(width: 44, height: 44)
                            .background(camera.torch ? Palette.signal : Color.clear, in: Circle())
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundStyle(camera.torch ? Palette.ink : Color.primary)
                    }
                    .accessibilityLabel(camera.torch ? "Выключить фонарик" : "Включить фонарик")
                }
            }
            .padding()
            Text("Встаньте в угол или в дверях, держите телефон ровно. 0,5× захватит больше комнаты.")
                .font(.footnote).foregroundStyle(.white)
                .padding(10).background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            Spacer()
            HStack(spacing: 10) {
                ForEach(camera.presets, id: \.self) { z in
                    let active = abs(camera.zoom - z) < 0.05
                    Button { camera.setZoom(z) } label: {
                        Text(active ? zoomText(camera.zoom) + "×" : zoomText(z))
                            .font(.footnote.bold())
                            .frame(width: 42, height: 42)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .foregroundStyle(active ? Palette.signal : Color.white)
                    }
                }
                if !camera.presets.contains(where: { abs(camera.zoom - $0) < 0.05 }) {
                    Text(zoomText(camera.zoom) + "×").font(.footnote.bold()).foregroundStyle(Palette.signal)
                        .frame(width: 48, height: 42).background(Color.black.opacity(0.55), in: Capsule())
                }
            }
            Button { camera.capture() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                    if camera.busy { ProgressView() }
                }
            }
            .disabled(camera.busy)
            .accessibilityLabel("Снять фото")
            .padding(.vertical, 24)
        }
    }

    private func review(_ shot: UIImage) -> some View {
        VStack(spacing: 16) {
            Image(uiImage: shot).resizable().scaledToFit()
            HStack(spacing: 12) {
                Button { camera.shot = nil } label: {
                    Text("Переснять").bold().frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                Button {
                    if let data = RoomResult.jpeg(shot) { onPhoto(data) }
                    dismiss()
                } label: {
                    Text("Взять это фото").bold().frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private func zoomText(_ z: CGFloat) -> String {
        let v = (z * 10).rounded() / 10
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v)).replacingOccurrences(of: ".", with: ",")
    }
}
