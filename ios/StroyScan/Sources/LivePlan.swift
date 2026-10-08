import RoomPlan
import SwiftUI
import simd

/// Мини-план во время скана (вид сверху, по сетке комнаты): выпрямленные стены и мебель.
/// Пересобирается из каждого свежего скана целиком — уже снятые углы и предметы тоже подстраиваются
struct LivePlan {
    /// Стены: x1, y1, x2, y2
    var walls: [SIMD4<Double>] = []
    /// Мебель: четыре угла каждого предмета
    var items: [[SIMD2<Double>]] = []
    var angle = 0.0
    var isEmpty: Bool { walls.isEmpty }

    init() {}

    /// Стены — как в подгонке (копию «двоящейся» стены не рисуем), мебель — параллельно стенам, размеры — из скана
    init(_ rect: Rectify.Result, _ room: ScanParts) {
        angle = rect.angle
        let turn = -rect.angle
        let copies = rect.copies
        for (i, w) in rect.walls.enumerated() where copies[i] == nil && w.length > 0.02 {
            let a = Rectify.rot(w.a, turn), b = Rectify.rot(w.b, turn)
            walls.append(SIMD4(a.x, a.y, b.x, b.y))
        }
        let grid: Double? = rect.ok ? rect.angle : nil
        for o in room.objects {
            let c = SIMD2<Double>(Double(o.transform.columns.3.x), Double(o.transform.columns.3.z))
            let ang = RoomResult.objectAngle(o, grid: grid)
            let u = SIMD2<Double>(cos(ang), sin(ang))
            let x: SIMD2<Double> = u * (Double(o.dimensions.x) / 2)
            let z: SIMD2<Double> = SIMD2(-u.y, u.x) * (Double(o.dimensions.z) / 2)
            let p1: SIMD2<Double> = c + x + z
            let p2: SIMD2<Double> = c - x + z
            let p3: SIMD2<Double> = c - x - z
            let p4: SIMD2<Double> = c + x - z
            items.append([p1, p2, p3, p4].map { Rectify.rot($0, turn) })
        }
    }

    /// Точка мира (x, z) → на мини-план
    func local(_ p: SIMD2<Double>) -> SIMD2<Double> { Rectify.rot(p, -angle) }
}

/// Мини-план: тонкие белые стены, мебель контуром, голубая точка — вы
struct MiniPlanView: View {
    let plan: LivePlan
    /// x, z и куда смотрит телефон (угол по полу)
    let me: SIMD3<Double>?

    private static let you = Color(red: 0.35, green: 0.75, blue: 1.0)

    var body: some View {
        Canvas { ctx, size in
            var pts = plan.walls.flatMap { [SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)] } + plan.items.flatMap { $0 }
            var mePos: SIMD2<Double>?
            var meDir = SIMD2<Double>(1, 0)
            if let me {
                let p = plan.local(SIMD2(me.x, me.y))
                mePos = p
                meDir = plan.local(SIMD2(cos(me.z), sin(me.z)))
                pts.append(p)
            }
            guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
                  let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return }
            let center = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
            // не меньше 3 × 3 м, чтобы в начале скана план не был огромным
            let half = SIMD2(max((maxX - minX) / 2, 1.5), max((maxY - minY) / 2, 1.5))
            let pad: CGFloat = 10
            let k = min((size.width - 2 * pad) / CGFloat(2 * half.x), (size.height - 2 * pad) / CGFloat(2 * half.y))
            func pt(_ v: SIMD2<Double>) -> CGPoint {
                CGPoint(x: size.width / 2 + CGFloat(v.x - center.x) * k, y: size.height / 2 + CGFloat(v.y - center.y) * k)
            }
            var furniture = Path()
            for box in plan.items where box.count == 4 {
                furniture.move(to: pt(box[0]))
                for p in box.dropFirst() { furniture.addLine(to: pt(p)) }
                furniture.closeSubpath()
            }
            ctx.stroke(furniture, with: .color(Color.white.opacity(0.6)), lineWidth: 1)
            var walls = Path()
            for s in plan.walls {
                walls.move(to: pt(SIMD2(s.x, s.y)))
                walls.addLine(to: pt(SIMD2(s.z, s.w)))
            }
            ctx.stroke(walls, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            if let mePos {
                let c = pt(mePos)
                let d = simd_length(meDir) > 0 ? meDir / simd_length(meDir) : SIMD2(1, 0)
                var cone = Path()
                cone.move(to: c)
                for a in [-0.45, 0.45] {
                    let v = Rectify.rot(d, a)
                    cone.addLine(to: CGPoint(x: c.x + CGFloat(v.x) * 20, y: c.y + CGFloat(v.y) * 20))
                }
                cone.closeSubpath()
                ctx.fill(cone, with: .color(MiniPlanView.you.opacity(0.35)))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(MiniPlanView.you))
            }
        }
        .frame(width: 112, height: 112)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("План комнаты: стены, мебель и где вы")
    }
}
