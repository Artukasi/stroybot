import SwiftUI

/// Документ для клиента: смета по вашим ценам, план, фото, дефекты и подпись клиента пальцем — одним PDF
struct ClientDocView: View {
    @EnvironmentObject var store: ScanStore
    let scanID: UUID
    let result: RoomResult
    @AppStorage("doc.client") private var client = ""
    @State private var address = ""
    @State private var withPlan = true
    @State private var withEstimate = true
    @State private var withPhoto = true
    @State private var withDefects = true
    @State private var strokes: [[CGPoint]] = []
    @State private var share: ShareFile?
    @State private var failed = false

    var body: some View {
        Form {
            Section("Заказчик") {
                TextField("Имя или организация", text: $client)
                TextField("Адрес объекта", text: $address)
            }
            Section("Что положить") {
                Toggle("Смета (ваши цены)", isOn: $withEstimate)
                Toggle("План с размерами", isOn: $withPlan)
                if result.photo != nil { Toggle("Фото комнаты", isOn: $withPhoto) }
                if !result.defects.isEmpty { Toggle("Дефекты с фото", isOn: $withDefects) }
            }
            Section {
                SignaturePad(strokes: $strokes)
                    .frame(height: 170)
                    .listRowInsets(EdgeInsets())
                if !strokes.isEmpty {
                    Button("Стереть подпись", role: .destructive) { withAnimation { strokes = [] } }
                }
            } header: {
                Text("Подпись заказчика")
            } footer: {
                Text("Дайте телефон клиенту — пусть распишется пальцем. Можно и без подписи: распечатать и подписать на бумаге.")
            }
            Section {
                Button { make() } label: {
                    Label("Собрать PDF", systemImage: "signature")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Документ для клиента")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if address.isEmpty { address = store.scan(scanID)?.place ?? "" }
        }
        .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
        .alert("Не получилось собрать PDF", isPresented: $failed) { Button("OK", role: .cancel) {} }
    }

    private func make() {
        let sig = strokes.isEmpty ? nil : SignaturePad.image(strokes)
        let id = scanID
        let s = store
        if let url = PlanPDF.clientDoc(result, client: client.trimmingCharacters(in: .whitespaces),
                                        address: address.trimmingCharacters(in: .whitespaces),
                                        withPlan: withPlan, withEstimate: withEstimate, withPhoto: withPhoto, withDefects: withDefects,
                                        signature: sig, photos: { s.defectPhoto(id, $0) }) {
            share = ShareFile(url: url)
        } else {
            failed = true
        }
    }
}

/// Поле для подписи пальцем
struct SignaturePad: View {
    @Binding var strokes: [[CGPoint]]
    @State private var current: [CGPoint] = []

    var body: some View {
        ZStack {
            Color.white
            Path { p in
                p.move(to: CGPoint(x: 20, y: 130))
                p.addLine(to: CGPoint(x: 1000, y: 130))
            }
            .stroke(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if strokes.isEmpty && current.isEmpty {
                Text("Распишитесь здесь").font(.subheadline).foregroundStyle(.gray.opacity(0.6))
            }
            Canvas { ctx, _ in
                for s in strokes + [current] where s.count > 1 {
                    ctx.stroke(Self.path(s), with: .color(Palette.ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in current.append(g.location) }
            .onEnded { _ in
                if current.count > 1 { strokes.append(current) }
                current = []
            })
    }

    /// Сглаженная линия через середины отрезков
    static func path(_ s: [CGPoint]) -> Path {
        var p = Path()
        guard let first = s.first else { return p }
        p.move(to: first)
        for i in 1..<s.count {
            let mid = CGPoint(x: (s[i - 1].x + s[i].x) / 2, y: (s[i - 1].y + s[i].y) / 2)
            p.addQuadCurve(to: mid, control: s[i - 1])
        }
        p.addLine(to: s[s.count - 1])
        return p
    }

    /// Подпись — картинка с прозрачным фоном, обрезанная по краям росчерка
    static func image(_ strokes: [[CGPoint]]) -> UIImage? {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return nil }
        let pad: CGFloat = 6
        let size = CGSize(width: max(maxX - minX, 10) + pad * 2, height: max(maxY - minY, 10) + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            let g = c.cgContext
            g.translateBy(x: pad - minX, y: pad - minY)
            g.setStrokeColor(UIColor(Palette.ink).cgColor)
            g.setLineWidth(2.6)
            g.setLineCap(.round)
            g.setLineJoin(.round)
            for s in strokes where s.count > 1 {
                g.addPath(path(s).cgPath)
                g.strokePath()
            }
        }
    }
}
