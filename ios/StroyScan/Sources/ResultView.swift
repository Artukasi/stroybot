import SwiftUI
import simd

/// Результат скана: план сверху с длинами стен, площади и отправка в бот.
struct ResultView: View {
    @EnvironmentObject var link: BotLink
    @State var result: RoomResult
    @State private var drawn: CGFloat = 0
    @State private var sent = false
    private let rooms = ["Комната", "Кухня", "Ванная", "Санузел", "Спальня", "Гостиная", "Детская", "Коридор", "Балкон"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlanShape(points: result.plan)
                    .trim(from: 0, to: drawn)
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
                    .background(PlanShape(points: result.plan).fill(Palette.draft.opacity(0.1)))
                    .overlay(PlanLabels(points: result.plan).opacity(drawn >= 1 ? 1 : 0))
                    .aspectRatio(max(0.6, min(1.8, result.length / max(result.width, 0.1))), contentMode: .fit)
                    .padding(28)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .onAppear { withAnimation(.easeOut(duration: 1.4)) { drawn = 1 } }

                Picker("Помещение", selection: $result.room) {
                    ForEach(rooms, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    stat("Пол", fmt(result.floorArea), "м²")
                    stat("Стены без проёмов", fmt(result.wallArea), "м²")
                    stat("Периметр", fmt(result.perimeter), "м")
                    stat("Высота", fmt(result.height), "м")
                    stat("Длина × ширина", "\(fmt(result.length)) × \(fmt(result.width))", "м")
                    stat("Окна и двери", "\(result.windows) и \(result.doors)", "шт")
                }

                Button {
                    Task { sent = await link.send(result) }
                } label: {
                    Group {
                        if link.busy { ProgressView() }
                        else { Label(sent ? "Отправлено в СтройБот" : "Отправить в СтройБот", systemImage: sent ? "checkmark" : "paperplane.fill") }
                    }
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(Palette.ink)
                }
                .disabled(!link.connected || link.busy)
                if !link.connected {
                    Text("Сначала подключите бота на главном экране.").font(.footnote).foregroundStyle(.secondary)
                }
                if let usdz = result.usdz {
                    ShareLink(item: usdz) { Label("3D-модель комнаты (USDZ)", systemImage: "cube") }
                }
            }
            .padding()
        }
        .navigationTitle(result.room)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()) + Text(" \(unit)").font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Контур пола, вписанный в рамку
struct PlanShape: Shape {
    let points: [SIMD2<Double>]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pts = fit(points, in: rect)
        guard let first = pts.first else { return p }
        p.move(to: first)
        pts.dropFirst().forEach { p.addLine(to: $0) }
        p.closeSubpath()
        return p
    }
}

/// Длины стен у каждой стороны плана
struct PlanLabels: View {
    let points: [SIMD2<Double>]

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let pts = fit(points, in: rect)
            let cx = pts.map(\.x).reduce(0, +) / CGFloat(max(pts.count, 1))
            let cy = pts.map(\.y).reduce(0, +) / CGFloat(max(pts.count, 1))
            ForEach(Array(points.indices), id: \.self) { i in
                let j = (i + 1) % points.count
                let len = simd_distance(points[i], points[j])
                if len > 0.4, pts.count == points.count {
                    let mx = (pts[i].x + pts[j].x) / 2
                    let my = (pts[i].y + pts[j].y) / 2
                    let d = max(hypot(mx - cx, my - cy), 1)
                    Text(fmt(len))
                        .font(.caption.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Palette.signal, in: Capsule())
                        .foregroundStyle(Palette.ink)
                        .position(x: mx + (mx - cx) / d * 16, y: my + (my - cy) / d * 16)
                }
            }
        }
    }
}

func fit(_ points: [SIMD2<Double>], in rect: CGRect) -> [CGPoint] {
    guard let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max(), maxX > 0, maxY > 0 else { return [] }
    let k = min(rect.width / maxX, rect.height / maxY)
    let ox = rect.minX + (rect.width - maxX * k) / 2, oy = rect.minY + (rect.height - maxY * k) / 2
    return points.map { CGPoint(x: ox + $0.x * k, y: oy + $0.y * k) }
}
