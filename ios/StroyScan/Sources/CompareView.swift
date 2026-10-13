import SwiftUI
import simd

/// Прогресс стройки: прошлая съёмка комнаты против нынешней — планы наложены, фото «было — стало», что изменилось в цифрах
struct CompareView: View {
    @EnvironmentObject var store: ScanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: UUID
    let now: RoomResult
    @State private var versions: [ScanStore.Version] = []
    @State private var pick = ""
    @State private var split: CGFloat = 0.5
    @State private var shown = false

    private var before: ScanStore.Version? { versions.first { $0.id == pick } ?? versions.last }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let before {
                    if versions.count > 1 {
                        Picker("Сравнить с", selection: $pick) {
                            ForEach(versions.reversed()) { v in
                                Text(v.date.formatted(date: .abbreviated, time: .shortened)).tag(v.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    photos(before)
                    plans(before)
                    table(before.result)
                } else {
                    Text("Прошлых съёмок нет. Переснимите комнату через «Доснять / Переснять», и здесь появится «было — стало».")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Было — стало")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            versions = store.versions(id)
            if pick.isEmpty { pick = versions.last?.id ?? "" }
            withAnimation(AppMotion.adaptive(reduceMotion: reduceMotion, full: .easeOut(duration: 0.38))) {
                shown = true
            }
        }
    }

    // MARK: - Фото: шторка

    @ViewBuilder private func photos(_ v: ScanStore.Version) -> some View {
        if let a = v.result.photo.flatMap(UIImage.init(data:)), let b = now.photo.flatMap(UIImage.init(data:)) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Image(uiImage: b).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                        Image(uiImage: a).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                            .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * split) }
                        Rectangle().fill(.white).frame(width: 3).offset(x: geo.size.width * split - 1.5)
                            .shadow(radius: 3)
                        Image(systemName: "arrow.left.and.right.circle.fill")
                            .font(.system(size: 34)).foregroundStyle(.white, Palette.ink)
                            .offset(x: geo.size.width * split - 17)
                        HStack {
                            tag("Было · \(v.date.formatted(date: .abbreviated, time: .omitted))")
                            Spacer()
                            tag("Стало")
                        }
                        .padding(10)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        split = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                    })
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                Text("Двигайте шторку пальцем.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Планы друг на друге

    private func plans(_ v: ScanStore.Version) -> some View {
        let old = v.result.plan, new = now.plan
        return VStack(alignment: .leading, spacing: 8) {
            Canvas { ctx, size in
                // оба плана центрируем по середине: съёмки в разные дни — начало координат у них своё
                let c = { (p: [SIMD2<Double>]) in p.reduce(SIMD2<Double>(0, 0), +) / Double(max(p.count, 1)) }
                let a = old.map { $0 - c(old) }, b = new.map { $0 - c(new) }
                let all = a + b
                guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
                      let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(), maxX > minX, maxY > minY else { return }
                let k = min((size.width - 20) / CGFloat(maxX - minX), (size.height - 20) / CGFloat(maxY - minY))
                let ox = (size.width - CGFloat(maxX - minX) * k) / 2, oy = (size.height - CGFloat(maxY - minY) * k) / 2
                let path = { (pts: [SIMD2<Double>]) -> Path in
                    var p = Path()
                    for (i, q) in pts.enumerated() {
                        let pt = CGPoint(x: ox + CGFloat(q.x - minX) * k, y: oy + CGFloat(q.y - minY) * k)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    p.closeSubpath()
                    return p
                }
                ctx.fill(path(b), with: .color(Palette.draft.opacity(0.12)))
                ctx.stroke(path(a), with: .color(.orange), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [6, 4]))
                ctx.stroke(path(b).trimmedPath(from: 0, to: shown ? 1 : 0), with: .color(Palette.ink),
                           style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            }
            .frame(height: 240)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            HStack(spacing: 16) {
                legend(.orange, dashed: true, "было")
                legend(Palette.ink, dashed: false, "стало")
            }
            .font(.caption)
        }
    }

    private func legend(_ color: Color, dashed: Bool, _ s: String) -> some View {
        HStack(spacing: 6) {
            Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 24, y: 4)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, dash: dashed ? [5, 3] : []))
                .frame(width: 24, height: 8)
            Text(s)
        }
    }

    // MARK: - Цифры

    private func table(_ old: RoomResult) -> some View {
        let rows: [(String, Double, Double, String)] = [
            ("Пол", old.floorArea, now.floorArea, "м²"),
            ("Стены без проёмов", old.wallArea, now.wallArea, "м²"),
            ("Периметр", old.perimeter, now.perimeter, "м"),
            ("Высота", old.height, now.height, "м"),
            ("Окна", Double(old.windows), Double(now.windows), "шт"),
            ("Двери", Double(old.doors), Double(now.doors), "шт"),
            ("Мебель и техника", Double(old.items.count), Double(now.items.count), "шт"),
            ("Точки электрики", Double(old.engineering.count(.electric)), Double(now.engineering.count(.electric)), "шт"),
            ("Выводы сантехники", Double(old.engineering.count(.plumbing)), Double(now.engineering.count(.plumbing)), "шт"),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Что").frame(maxWidth: .infinity, alignment: .leading)
                Text("Было").frame(width: 64, alignment: .trailing)
                Text("Стало").frame(width: 64, alignment: .trailing)
                Text("Разница").frame(width: 76, alignment: .trailing)
            }
            .font(.caption.bold()).foregroundStyle(.secondary).padding(.vertical, 8)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                let d = r.2 - r.1
                let same = abs(d) < (r.3 == "шт" ? 0.5 : 0.02)
                HStack {
                    Text(r.0).frame(maxWidth: .infinity, alignment: .leading)
                    Text(num(r.1, r.3)).frame(width: 64, alignment: .trailing).foregroundStyle(.secondary)
                    Text(num(r.2, r.3)).frame(width: 64, alignment: .trailing).bold()
                    Text(same ? "—" : (d > 0 ? "+" : "−") + num(abs(d), r.3) + " " + r.3)
                        .frame(width: 76, alignment: .trailing)
                        .foregroundStyle(same ? Color.secondary : (d > 0 ? Color.green : Color.orange))
                }
                .font(.subheadline.monospacedDigit())
                .padding(.vertical, 7)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 8)
                .animation(reduceMotion ? .easeOut(duration: 0.12)
                                       : .easeOut(duration: 0.22).delay(0.02 * Double(i)),
                           value: shown)
                Divider()
            }
            Text("Пол и стены меньше на пару процентов — обычно это новая отделка (штукатурка, плитка) или разброс лидара ±1–2 см.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func num(_ v: Double, _ unit: String) -> String {
        unit == "шт" ? "\(Int(v.rounded()))" : fmt((v * 100).rounded() / 100)
    }
}
