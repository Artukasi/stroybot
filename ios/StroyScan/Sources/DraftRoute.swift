import SwiftUI
import simd

/// Эскизная трассировка инженерии между отмеченными на LiDAR-модели точками.
/// Не проверяет скрытые сети, конструктив, пожарные зоны, перепады давления или коллизии.
/// Канализацию, газ и отопление автоматически не проектируем.
enum DraftRoute {
    enum Service: String, CaseIterable, Identifiable {
        case cold = "Холодная вода"
        case hot = "Горячая вода"
        case sockets = "Кабель розеток"
        case light = "Кабель освещения"
        var id: String { rawValue }
        var isWire: Bool { self == .sockets || self == .light }
        var key: String {
            switch self {
            case .cold: return "cold"
            case .hot: return "hot"
            case .sockets: return "sockets"
            case .light: return "light"
            }
        }
        var allowed: [String] {
            switch self {
            case .cold: return ["cold", "washer"]
            case .hot: return ["hot"]
            case .sockets: return ["socket", "socket2", "socket_desk", "socket_power", "panel"]
            case .light: return ["switch", "sconce", "ceiling_light", "panel"]
            }
        }
    }
    static func points(_ service: Service, in engineering: Engineering) -> [Engineering.Point] {
        engineering.points.filter { service.allowed.contains($0.kind) }
    }
    /// Чисто геометрический вариант по осям с фиксированной высотной полосой.
    /// Даже если он попал внутрь стены или мебели, специалист обязан его пересмотреть.
    static func propose(_ a: Engineering.Point, _ b: Engineering.Point, service: Service, ceiling: Double) -> Engineering.Pipe? {
        let lane = service.isWire ? max(0.3, ceiling - 0.2) : 0.3
        guard ceiling > 0.6, [a.x, a.y, a.height, b.x, b.y, b.height].allSatisfy({ $0.isFinite }),
              a.id != b.id else { return nil }
        let coords = [
            SIMD3<Double>(a.x, a.y, a.height),
            SIMD3<Double>(a.x, a.y, lane),
            SIMD3<Double>(b.x, a.y, lane),
            SIMD3<Double>(b.x, b.y, lane),
            SIMD3<Double>(b.x, b.y, b.height)
        ]
        // Keep only nonzero segments.
        var clean: [SIMD3<Double>] = []
        for p in coords where clean.last.map({ simd_distance($0, p) > 0.0001 }) ?? true {
            clean.append(p)
        }
        guard clean.count > 1, clean.count < 20 else { return nil }
        return Engineering.Pipe(kind: service.key, diameter: service.isWire ? 0 : 20, points: clean)
    }
}

struct DraftRouteView: View {
    let room: RoomResult
    @Binding var engineering: Engineering
    @State private var service: DraftRoute.Service = .cold
    @State private var startID: UUID?
    @State private var endID: UUID?
    @State private var confirmed = false
    @State private var info: String?

    private var candidates: [Engineering.Point] { DraftRoute.points(service, in: engineering) }
    private var proposal: Engineering.Pipe? {
        guard let a = candidates.first(where: { $0.id == startID }),
              let b = candidates.first(where: { $0.id == endID }),
              a.id != b.id else { return nil }
        return DraftRoute.propose(a, b, service: service, ceiling: room.height)
    }
    private var remaining: Int {
        service.isWire ? Engineering.maxWires - engineering.wires.count :
            Engineering.maxPipes - engineering.pipes.count
    }
    private func title(_ p: Engineering.Point, at n: Int) -> String {
        let kind = EngKind.find(p.kind)?.title ?? p.kind
        return "\(n + 1). \(kind) · \(Int((p.height * 100).rounded())) см"
    }
    var body: some View {
        Form {
            Section {
                Text("Черновая трасса между двумя точками уже отмеченной на скане инженерии. Результат появится в редакторе 3D только после твоего подтверждения.")
                    .font(.subheadline)
                Picker("Система", selection: $service) {
                    ForEach(DraftRoute.Service.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .onChange(of: service) { _ in startID = nil; endID = nil; confirmed = false }
            } header: {
                Text("Эскиз по LiDAR")
            }
            Section("Точки на 3D-модели") {
                if candidates.count < 2 {
                    Text("Нужно сначала добавить минимум две подходящие точки в редакторе «Ремонт в 3D» → «Электрика» или «Сантехника».")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Откуда", selection: $startID) {
                        Text("Выберите").tag(nil as UUID?)
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { i, p in
                            Text(title(p, at: i)).tag(p.id as UUID?)
                        }
                    }
                    Picker("Куда", selection: $endID) {
                        Text("Выберите").tag(nil as UUID?)
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { i, p in
                            Text(title(p, at: i)).tag(p.id as UUID?)
                        }
                    }
                }
            }
            if let route = proposal {
                Section("Предложенная геометрия") {
                    LabeledContent("Длина без запаса", value: String(format: "%.2f м", route.length))
                    LabeledContent("Узлов эскиза", value: "\(route.points.count)")
                    Text("Трасса проходит вдоль осей X/Y и по высоте. Препятствия, несущие конструкции и скрытые сети не проверены.")
                        .font(.caption).foregroundStyle(.orange)
                    Toggle("Я понимаю: это эскиз, а не проект монтажа", isOn: $confirmed)
                    Button("Добавить черновик в 3D") {
                        guard confirmed, remaining > 0 else { return }
                        if service.isWire { engineering.wires.append(route) }
                        else { engineering.pipes.append(route) }
                        info = "Эскиз добавлен. Открой «Ремонт в 3D» и проверь трассу. До монтажа согласуй её со специалистом."
                        confirmed = false
                    }
                    .disabled(!confirmed || remaining <= 0)
                }
            }
            Section("Что проверить до монтажа") {
                Text("• Скрытые трубы и кабели в стенах, полу, потолке.")
                Text("• Доступ для обслуживания и допустимость отверстий.")
                Text("• Сечения, диаметры, крепления, температурные деформации и защиту.")
                Text("• Реальные препятствия: LiDAR не видит всё внутри конструкций.")
                Text("• Соответствие проекту, нормам и техническим картам.")
            }
            Section {
                Text("Для канализации, отопления и газа автотрасса намеренно отключена: там нужны специальные инженерные расчёты и согласования. Перегородки ГКЛ можно визуализировать через редактор отделки; автоматическая генерация каркаса пока не реализована.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Маршрут в 3D · эскиз")
        .navigationBarTitleDisplayMode(.inline)
        .alert("СтройСкан", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK", role: .cancel) { info = nil }
        } message: { Text(info ?? "") }
    }
}
