import RoomPlan
import SwiftUI

/// Куда ведёт главный экран
enum Route: Hashable {
    case room(UUID)
    case flat(UUID)
}

/// Запуск съёмки: что снимаем и какую запись обновить (пересъёмка и досъёмка)
struct ScanRequest: Identifiable {
    let id = UUID()
    let mode: ScanMode
    var target: UUID?
}

struct ContentView: View {
    @EnvironmentObject var link: BotLink
    @EnvironmentObject var store: ScanStore
    @EnvironmentObject var hub: ScanHub
    @Environment(\.scenePhase) private var phase
    @State private var path = NavigationPath()
    @State private var request: ScanRequest?
    @State private var showPair = false
    @State private var measuring = false
    @State private var showTips = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeroCard()
                    if !RoomCaptureSession.isSupported {
                        card {
                            Text("На этом iPhone нет лидара").font(.headline)
                            Text("Сканер работает на iPhone 12 Pro и новее (модели Pro) и iPad Pro. Без лидара пришлите в бот фото плана или комнаты с рулеткой.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        actions
                    }
                    queueCard
                    connection
                    history
                    tips
                }
                .padding()
            }
            .background(Palette.paper.opacity(0.6).ignoresSafeArea())
            .navigationTitle("СтройСкан")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .room(let id):
                    SavedRoomView(id: id) { rescan(id) }
                        .id("\(id)-\(store.scan(id)?.revision ?? 0)")
                case .flat(let id):
                    FlatView(id: id) { path.append(Route.room($0)) }
                }
            }
        }
        .fullScreenCover(item: $request) { req in
            ScanScreen(mode: req.mode, arSession: hub.session()) { outcome in
                done(outcome, req)
            }
            .onDisappear { hub.scanClosed() }
        }
        .fullScreenCover(isPresented: $measuring) { MeasureView() }
        .sheet(isPresented: $showPair) { PairView() }
        .alert(link.message ?? "", isPresented: Binding(get: { link.message != nil }, set: { if !$0 { link.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onAppear { store.startQueue(link) }
        .onChange(of: link.connected) { on in
            if on { Task { await store.flush(link) } }
        }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.flush(link) } }
        }
    }

    // MARK: - Съёмка

    private func rescan(_ id: UUID) {
        if let old = hub.rooms(for: id) {
            request = ScanRequest(mode: .more(old), target: id)
        } else {
            request = ScanRequest(mode: .room, target: id)
        }
    }

    private func done(_ o: ScanOutcome, _ req: ScanRequest) {
        if o.flat {
            let rooms = o.rooms.enumerated().map { i, r in (r, o.outlines.map { $0[i] }) }
            let f = store.addFlat(name: "Квартира", rooms: rooms)
            for (i, id) in f.rooms.enumerated() where i < o.captured.count { hub.keep(o.captured[i], for: id) }
            exportFlatModel(f)
            path.append(Route.flat(f.id))
        } else if let r = o.rooms.first {
            if let target = req.target, let old = store.scan(target) {
                var r = r
                r.room = old.room
                // досъёмка с другого места — фото комнаты оставляем прежнее
                if case .more = req.mode, let photo = store.result(target)?.photo { r.photo = photo }
                store.update(target, result: r, resend: true)
                hub.keep(o.captured.first ?? [], for: target)
            } else {
                let s = store.add(r)
                hub.keep(o.captured.first ?? [], for: s.id)
                path.append(Route.room(s.id))
            }
        }
        if let note = o.note { link.message = note }
    }

    /// Квартира, снятая за один раз: общая 3D-модель от Apple (iOS 17)
    private func exportFlatModel(_ f: SavedFlat) {
        guard #available(iOS 17.0, *), !f.outlines.isEmpty else { return }
        let rooms = hub.rooms(f.rooms)
        guard rooms.count > 1 else { return }
        let url = store.flatModelURL(f.id)
        Task.detached {
            do {
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                try structure.export(to: url)
            } catch {
                // без общей модели обойдёмся: план и цифры есть
            }
        }
    }

    // MARK: - Кнопки

    private var actions: some View {
        VStack(spacing: 10) {
            Button { request = ScanRequest(mode: .room) } label: {
                Label("Сканировать комнату", systemImage: "viewfinder")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(PressStyle())
            HStack(spacing: 10) {
                tile("Квартира целиком", "square.split.2x2", "комнаты подряд, общий план") {
                    request = ScanRequest(mode: .flat)
                }
                tile("Рулетка", "ruler", "замер одной линией") {
                    hub.pause()
                    measuring = true
                }
            }
        }
    }

    private func tile(_ title: String, _ icon: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.title2).foregroundStyle(Palette.signal)
                Text(title).font(.headline).foregroundStyle(.white)
                Text(sub).font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(PressStyle())
    }

    // MARK: - Очередь

    @ViewBuilder private var queueCard: some View {
        let n = store.pendingCount
        if n > 0 {
            HStack(spacing: 12) {
                if store.flushing { ProgressView() } else {
                    Image(systemName: "tray.and.arrow.up.fill").font(.title2).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(n == 1 ? "1 скан ждёт отправки" : "Сканов ждут отправки: \(n)").font(.headline)
                    Text(link.connected ? "Уйдут сами, когда бот будет доступен." : "Уйдут сами, когда подключите бота.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if link.connected && !store.flushing {
                    Button("Сейчас") { Task { await store.flush(link) } }.font(.subheadline.bold())
                }
            }
            .padding()
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - Мои комнаты

    @ViewBuilder private var history: some View {
        if !store.flats.isEmpty || !store.singles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Мои комнаты").font(.title3.bold())
                ForEach(store.flats.sorted { $0.created > $1.created }) { f in
                    NavigationLink(value: Route.flat(f.id)) { flatRow(f) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { store.deleteFlat(f.id) } label: { Label("Удалить квартиру", systemImage: "trash") }
                        }
                }
                ForEach(store.singles) { s in
                    NavigationLink(value: Route.room(s.id)) { ScanRow(scan: s) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { hub.forget(s.id); store.delete(s.id) } label: { Label("Удалить", systemImage: "trash") }
                        }
                }
                Text("Удалить — долгое нажатие на карточку.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func flatRow(_ f: SavedFlat) -> some View {
        let rooms = store.rooms(of: f)
        let area = rooms.reduce(0) { $0 + $1.floorArea }
        return HStack(spacing: 12) {
            Image(systemName: "building.2.fill").font(.title2)
                .frame(width: 56, height: 56)
                .background(Palette.draft, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.name).font(.headline)
                Text("\(rooms.count) \(plural(rooms.count, "комната", "комнаты", "комнат")) · \(fmt((area * 10).rounded() / 10)) м²")
                    .font(.subheadline).foregroundStyle(.secondary)
                if rooms.contains(where: \.pending) { Badge(text: "ждёт отправки", color: .orange) }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var connection: some View {
        card {
            HStack {
                Circle().fill(link.connected ? Color.green : Color.orange).frame(width: 10, height: 10)
                Text(link.connected ? "Подключено к боту" : "Не подключено к боту").font(.headline)
                Spacer()
                Button(link.connected ? "Переподключить" : "Подключить") { showPair = true }
            }
            if !link.connected {
                Text("Напишите боту /scanner и нажмите «Подключить iPhone», или введите код вручную.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var tips: some View {
        card {
            DisclosureGroup(isExpanded: $showTips) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Включите свет или откройте шторы: в темноте лидар ошибается. Если темно — кнопка фонарика вверху экрана скана.")
                    Text("2. Закройте дверцы шкафов, уберите лишнее с прохода.")
                    Text("3. Встаньте у входа и медленно обведите камерой все стены. Держитесь в 1–3 метрах от стен.")
                    Text("4. Захватите пол и углы. Двери и окна найдутся сами.")
                    Text("5. Мебель обойдите с двух сторон, чтобы она измерилась целиком.")
                    Text("6. В конце наведите камеру на самый красивый вид комнаты и нажмите «Готово» — этот кадр станет фото для ремонта.")
                    Text("7. Квартира: снимите комнату, нажмите «Следующая комната», пройдите в неё через дверь, не выключая камеру. Так комнаты лягут на общий план.")
                }
                .padding(.top, 6)
            } label: {
                Text("Как снимать").font(.headline)
            }
        }
        .font(.subheadline)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Карточка комнаты в истории
struct ScanRow: View {
    @EnvironmentObject var store: ScanStore
    @EnvironmentObject var link: BotLink
    let scan: SavedScan

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = store.photo(scan.id) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "square.dashed").font(.title2).foregroundStyle(Palette.draft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.paper)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(scan.room).font(.headline)
                Text("пол \(fmt(scan.floorArea)) м² · стены \(fmt(scan.wallArea)) м²")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(scan.updated.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if scan.pending {
                        Badge(text: "ждёт отправки", color: .orange)
                    } else if scan.botScanId != nil && scan.botServer == link.server {
                        Badge(text: "в боте", color: .green)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Кнопка чуть проседает под пальцем
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Шапка: чертёж, по которому бежит луч лидара
struct HeroCard: View {
    @State private var sweep = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Canvas { ctx, size in
                var grid = Path()
                let step: CGFloat = 18
                var x: CGFloat = 0
                while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                ctx.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                // контур комнаты
                let w = size.width, h = size.height
                var room = Path()
                room.move(to: CGPoint(x: w * 0.55, y: h * 0.18))
                room.addLine(to: CGPoint(x: w * 0.93, y: h * 0.18))
                room.addLine(to: CGPoint(x: w * 0.93, y: h * 0.62))
                room.addLine(to: CGPoint(x: w * 0.78, y: h * 0.62))
                room.addLine(to: CGPoint(x: w * 0.78, y: h * 0.86))
                room.addLine(to: CGPoint(x: w * 0.55, y: h * 0.86))
                room.closeSubpath()
                ctx.stroke(room, with: .color(Palette.signal), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
            GeometryReader { geo in
                LinearGradient(colors: [Palette.signal.opacity(0), Palette.signal.opacity(0.35), Palette.signal.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 60)
                    .offset(x: sweep ? geo.size.width : -60)
            }
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 6) {
                Text("Замер лидаром").font(.title.bold()).foregroundStyle(.white)
                Text("Комната или вся квартира за пару минут. Размеры сразу уходят в СтройБот: материалы и смета.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: 230, alignment: .leading)
            }
            .padding(18)
        }
        .frame(height: 190)
        .background(Palette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

func fmt(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.maximumFractionDigits = 2
    f.minimumFractionDigits = 0
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

/// 1 комната, 2 комнаты, 5 комнат
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}
