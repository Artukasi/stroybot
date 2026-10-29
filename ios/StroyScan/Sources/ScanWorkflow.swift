import RoomPlan
import SwiftUI

/// Shared save path for the new scanner / objects tabs.
/// Preserve existing engineering, tiling and versions when completing a room scan.
@MainActor
enum ScanWorkflow {
    static func save(_ outcome: ScanOutcome, request: ScanRequest,
                     store: ScanStore, hub: ScanHub, link: BotLink) -> UUID? {
        guard let result = outcome.rooms.first else { return nil }
        if let target = request.target, let previousScan = store.scan(target) {
            var updated = result
            updated.room = previousScan.room
            let old = store.result(target)
            if case .more = request.mode, let oldPhoto = old?.photo {
                updated.photo = oldPhoto
            }
            var archive = false
            var notes: [String] = []
            if case .room = request.mode { archive = true }

            if let old, !old.engineering.isEmpty {
                if case .more = request.mode,
                   let transferred = old.engineering.moved(from: old, to: updated) {
                    updated.engineering = transferred
                } else {
                    archive = true
                    notes.append("Инженерные точки и трассы остались в прошлой версии скана, расставьте их заново.")
                }
            }
            if let old, !old.defects.isEmpty {
                if case .more = request.mode, let transferred = updated.movedDefects(old) {
                    updated.defects = transferred
                } else {
                    archive = true
                    notes.append("Прежние дефекты остались в истории, проверьте их размещение заново.")
                }
            }
            if case .more = request.mode, let old, !old.tiling.isEmpty {
                updated.tiling = old.tiling
            }
            store.update(target, result: updated, resend: true, archive: archive)
            hub.keep(outcome.captured.first ?? [], for: target)
            if !notes.isEmpty { link.message = notes.joined(separator: "\n") }
            return target
        }
        let saved = store.add(result)
        hub.keep(outcome.captured.first ?? [], for: saved.id)
        return saved.id
    }

    static func saveFlat(_ outcome: ScanOutcome, store: ScanStore, hub: ScanHub) -> UUID {
        let data: [(RoomResult, [[Double]]?)] = outcome.rooms.enumerated().map { index, result in
            let outline: [[Double]]? = outcome.outlines.flatMap {
                $0.indices.contains(index) ? $0[index] : nil
            }
            return (result, outline)
        }
        let flat = store.addFlat(name: "Квартира", rooms: data)
        for (i, id) in flat.rooms.enumerated() where i < outcome.captured.count {
            hub.keep(outcome.captured[i], for: id)
        }
        if #available(iOS 17.0, *), !flat.outlines.isEmpty {
            let captured = hub.rooms(flat.rooms)
            if captured.count > 1 {
                let destination = store.flatModelURL(flat.id)
                Task.detached {
                    do {
                        let structure = try await StructureBuilder(options: [.beautifyObjects])
                            .capturedStructure(from: captured)
                        try structure.export(to: destination)
                    } catch {
                        // An individual room plan remains available if structure export fails.
                    }
                }
            }
        }
        return flat.id
    }

    static func rescanRequest(_ id: UUID, hub: ScanHub) -> ScanRequest {
        if let old = hub.rooms(for: id) {
            return ScanRequest(mode: .more(old), target: id)
        }
        return ScanRequest(mode: .room, target: id)
    }
}
