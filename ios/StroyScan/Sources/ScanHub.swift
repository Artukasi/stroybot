import ARKit
import RoomPlan
import SwiftUI

/// Общая камера ARKit для съёмок (iOS 17) и сканы комнат этой съёмки.
/// Пока приложение открыто и телефон помнит комнату, «Доснять» продолжает тот же скан, а не начинает сначала.
@MainActor
final class ScanHub: ObservableObject {
    private var ar: ARSession?
    /// Сканы каждой комнаты в координатах общего ARSession, по записи в истории
    private var captured: [UUID: [CapturedRoom]] = [:]
    private var order: [UUID] = []
    private var parkTask: Task<Void, Never>?

    /// Сколько держать камеру включённой после «Готово», чтобы можно было сразу доснять
    static let keepAlive: UInt64 = 90

    /// ARSession для новой съёмки (iOS 17), камеру не выключаем
    func session() -> ARSession? {
        guard #available(iOS 17.0, *) else { return nil }
        parkTask?.cancel()
        if ar == nil { ar = ARSession() }
        return ar
    }

    /// Съёмка закрыта: камеру выключим чуть позже (вдруг сразу «Доснять»)
    func scanClosed() {
        parkTask?.cancel()
        parkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ScanHub.keepAlive * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pause()
        }
    }

    /// Нужна другая камера (фото, рулетка, мебель в комнате) — общую выключаем сразу
    func pause() {
        parkTask?.cancel()
        ar?.pause()
    }

    func keep(_ rooms: [CapturedRoom], for id: UUID) {
        captured[id] = rooms
        order.removeAll { $0 == id }
        order.append(id)
        // в памяти — последние 12 комнат
        while order.count > 12 { captured[order.removeFirst()] = nil }
    }

    /// Прошлые сканы комнаты в этой съёмке (nil — приложение перезапускали, доснять можно только заново)
    func rooms(for id: UUID) -> [CapturedRoom]? {
        guard ar != nil else { return nil }
        return captured[id]
    }

    func forget(_ id: UUID) {
        captured[id] = nil
        order.removeAll { $0 == id }
    }

    /// Сканы комнат квартиры — для общей 3D-модели
    func rooms(_ ids: [UUID]) -> [CapturedRoom] {
        ids.compactMap { captured[$0]?.last }
    }
}
