import RoomPlan
import SwiftUI

/// Экран Apple RoomPlan: лидар строит стены, окна и двери прямо в камере.
struct RoomScanner: UIViewRepresentable {
    @ObservedObject var controller: ScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = controller
        controller.view = view
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

final class ScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    weak var view: RoomCaptureView?
    @Published var result: RoomResult?
    @Published var failed: String?
    @Published var finishing = false

    override init() { super.init() }
    // RoomCaptureViewDelegate требует NSCoding
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func finish() {
        finishing = true
        view?.captureSession.stop()
    }

    func cancel() { view?.captureSession.stop() }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error { DispatchQueue.main.async { self.failed = error.localizedDescription } }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        var result = RoomResult(processedResult)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Комната.usdz")
        try? FileManager.default.removeItem(at: url)
        if (try? processedResult.export(to: url)) != nil { result.usdz = url }
        DispatchQueue.main.async {
            self.finishing = false
            if let error { self.failed = error.localizedDescription }
            if result.walls.isEmpty { self.failed = "Не нашёл стен. Пройдите по комнате медленнее и снимите все углы." }
            else { self.result = result }
        }
    }
}

struct ScanScreen: View {
    @StateObject private var controller = ScanController()
    @Environment(\.dismiss) private var dismiss
    let onResult: (RoomResult) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            RoomScanner(controller: controller).ignoresSafeArea()
            HStack {
                Button("Отмена") { controller.cancel(); dismiss() }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Button {
                    controller.finish()
                } label: {
                    Text(controller.finishing ? "Считаю…" : "Готово").bold()
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Palette.signal, in: Capsule())
                        .foregroundStyle(Palette.ink)
                }
                .disabled(controller.finishing)
            }
            .padding()
        }
        .onChange(of: controller.result != nil) { ready in
            if ready, let r = controller.result { onResult(r); dismiss() }
        }
        .alert("Скан не получился", isPresented: .constant(controller.failed != nil)) {
            Button("Понятно") { controller.failed = nil; dismiss() }
        } message: { Text(controller.failed ?? "") }
    }
}
