import RoomPlan
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var link: BotLink
    @State private var scanning = false
    @State private var showPair = false
    @State private var result: RoomResult?
    /// Новый скан — новый экран результата (сбрасываем отправку, фото и ремонт)
    @State private var resultID = UUID()
    /// Пересъёмка с экрана результата: он сам обновится новым сканом
    @State private var rescanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    if !RoomCaptureSession.isSupported {
                        card {
                            Text("На этом iPhone нет лидара").font(.headline)
                            Text("Сканер работает на iPhone 12 Pro и новее (модели Pro) и iPad Pro. Без лидара пришлите в бот фото плана или комнаты с рулеткой.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button { scanning = true } label: {
                            Label("Сканировать комнату", systemImage: "viewfinder")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(Palette.signal, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(Palette.ink)
                        }
                        tips
                    }
                    connection
                    if let result {
                        NavigationLink { ResultView(result: result, onRescan: rescan).id(resultID) } label: {
                            card {
                                Text("Последний скан").font(.subheadline).foregroundStyle(.secondary)
                                Text("\(result.room): пол \(fmt(result.floorArea)) м², стены \(fmt(result.wallArea)) м²").font(.headline)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(Palette.paper.opacity(0.6).ignoresSafeArea())
            .navigationTitle("СтройСкан")
            .navigationDestination(isPresented: Binding(get: { result != nil && justScanned }, set: { if !$0 { justScanned = false } })) {
                if let result { ResultView(result: result, onRescan: rescan).id(resultID) }
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            ScanScreen { r in
                result = r
                resultID = UUID()
                if !rescanning { justScanned = true }
                rescanning = false
            }
        }
        .onChange(of: scanning) { open in
            if !open { rescanning = false }
        }
        .sheet(isPresented: $showPair) { PairView() }
        .alert(link.message ?? "", isPresented: Binding(get: { link.message != nil }, set: { if !$0 { link.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @State private var justScanned = false

    private func rescan() {
        rescanning = true
        scanning = true
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Замер комнаты лидаром").font(.title2.bold())
            Text("Стены, окна и двери за минуту. Размеры сразу уходят в СтройБот: там посчитаются материалы и смета.")
                .foregroundStyle(.secondary)
        }
    }

    private var tips: some View {
        card {
            Text("Как снимать").font(.headline)
            Text("1. Включите свет или откройте шторы: в темноте лидар ошибается. Если темно — кнопка фонарика вверху экрана скана.")
            Text("2. Закройте дверцы шкафов, уберите лишнее с прохода.")
            Text("3. Встаньте у входа и медленно обведите камерой все стены. Держитесь в 1–3 метрах от стен.")
            Text("4. Захватите пол и углы. Двери и окна найдутся сами.")
            Text("5. Мебель обойдите с двух сторон, чтобы она измерилась целиком.")
            Text("6. В конце наведите камеру на самый красивый вид комнаты и нажмите «Готово» — этот кадр станет фото для ремонта.")
        }
        .font(.subheadline)
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

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

func fmt(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.maximumFractionDigits = 2
    f.minimumFractionDigits = 0
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}
