import RoomPlan
import SwiftUI

/// StroyScan 2.0: task-led navigation without removing any old workflow.
struct StroyScanShell: View {
    @State private var selected = 0
    var body: some View {
        TabView(selection: $selected) {
            ContentView()
                .tabItem { Label("Главная", systemImage: "house.fill") }
                .tag(0)
            ObjectsHubView()
                .tabItem { Label("Объекты", systemImage: "square.stack.3d.up") }
                .tag(1)
            ScanToolsHubView()
                .tabItem { Label("Сканер", systemImage: "viewfinder") }
                .tag(2)
            AssistantHubView()
                .tabItem { Label("Помощник", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .tag(3)
        }
    }
}

private struct HubRow: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2).foregroundStyle(Palette.signal)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
    }
}

struct ObjectsHubView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var hub: ScanHub
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        WorkProjectsHubView()
                    } label: {
                        HubRow(title: "Проекты ремонта", detail: "Работы, материалы, закупки и клиентские отчёты",
                               symbol: "building.2.crop.circle")
                    }
                    NavigationLink {
                        PetrovichPurchaseView()
                    } label: {
                        HubRow(title: "Общая закупка", detail: "Материалы для нескольких видов работ",
                               symbol: "cart")
                    }
                }
                if store.flats.isEmpty && store.scans.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Сканов пока нет", systemImage: "viewfinder").font(.headline)
                            Text("Открой вкладку «Сканер», чтобы снять первую комнату.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                if !store.flats.isEmpty {
                    Section("Квартиры") {
                        ForEach(store.flats) { flat in
                            NavigationLink {
                                FlatView(id: flat.id) { _ in }
                            } label: {
                                HubRow(title: flat.name, detail: "\(flat.rooms.count) комнат",
                                       symbol: "building.2")
                            }
                        }
                    }
                }
                if !store.scans.isEmpty {
                    Section("Комнаты") {
                        ForEach(store.scans) { scan in
                            NavigationLink {
                                SavedRoomView(id: scan.id) {}
                            } label: {
                                HubRow(title: scan.room,
                                       detail: String(format: "%.1f м² · %@", scan.floorArea, scan.place ?? "Без объекта"),
                                       symbol: "square.dashed")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Мои объекты")
        }
    }
}

struct ScanToolsHubView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var hub: ScanHub
    @State private var request: ScanRequest?
    @State private var wallScan = false
    @State private var measure = false
    @State private var flatness = false
    @State private var lastScanID: UUID?
    @State private var lastFlatID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if RoomCaptureSession.isSupported {
                        Button {
                            hub.pause()
                            request = ScanRequest(mode: .room)
                        } label: {
                            HubRow(title: "Сканировать комнату",
                                   detail: "LiDAR · площадь, стены, окна, двери, 3D",
                                   symbol: "viewfinder")
                        }
                        Button {
                            hub.pause()
                            wallScan = true
                        } label: {
                            HubRow(title: "Сканировать одну стену",
                                   detail: "Сразу получить материалы для ГКЛ",
                                   symbol: "rectangle.dashed")
                        }
                        Button {
                            hub.pause()
                            request = ScanRequest(mode: .flat)
                        } label: {
                            HubRow(title: "Сканировать квартиру",
                                   detail: "Несколько комнат в одной съёмке",
                                   symbol: "building.2")
                        }
                    } else {
                        Label("RoomPlan недоступен на этом устройстве. Можно пользоваться ручными замерами и расчётами.",
                              systemImage: "info.circle")
                            .font(.subheadline)
                    }
                } header: { Text("LiDAR") }
                Section("Измерительные инструменты") {
                    Button { hub.pause(); measure = true } label: {
                        HubRow(title: "Рулетка", detail: "Быстрые размеры и фото", symbol: "ruler")
                    }
                    Button { hub.pause(); flatness = true } label: {
                        HubRow(title: "Проверка ровности", detail: "Пол и стены", symbol: "level")
                    }
                    NavigationLink {
                        PetrovichPurchaseView()
                    } label: {
                        HubRow(title: "Смета без сканирования",
                               detail: "Ручной ввод площадей и материалов", symbol: "calculator")
                    }
                }
                if let lastScanID {
                    Section("Последний результат") {
                        NavigationLink {
                            SavedRoomView(id: lastScanID) {}
                        } label: {
                            HubRow(title: "Открыть отсканированную комнату",
                                   detail: "3D, работы, смета, закупка", symbol: "cube")
                        }
                    }
                }
                if let lastFlatID {
                    Section("Последняя квартира") {
                        NavigationLink {
                            FlatView(id: lastFlatID) { _ in }
                        } label: { HubRow(title: "Открыть квартиру", detail: "Комнаты и общий план", symbol: "square.stack") }
                    }
                }
            }
            .navigationTitle("Сканер")
        }
        .fullScreenCover(item: $request) { req in
            ScanScreen(mode: req.mode, arSession: hub.session()) { outcome in
                if outcome.flat {
                    let data = outcome.rooms.enumerated().map { index, room in
                        (room, outcome.outlines.flatMap { $0.indices.contains(index) ? $0[index] : nil })
                    }
                    let flat = store.addFlat(name: "Квартира", rooms: data)
                    lastFlatID = flat.id
                    for (index, id) in flat.rooms.enumerated() where index < outcome.captured.count {
                        hub.keep(outcome.captured[index], for: id)
                    }
                } else if let room = outcome.rooms.first {
                    let saved = store.add(room)
                    lastScanID = saved.id
                    if let captured = outcome.captured.first {
                        hub.keep(captured, for: saved.id)
                    }
                }
                request = nil
            }
            .onDisappear { hub.scanClosed() }
        }
        .fullScreenCover(isPresented: $wallScan) { LiveWallScanView() }
        .fullScreenCover(isPresented: $measure) { MeasureView() }
        .fullScreenCover(isPresented: $flatness) { FlatnessView() }
    }
}

struct AssistantHubView: View {
    @State private var selected = 0
    var body: some View {
        NavigationStack {
            List {
                Section("Как помочь?") {
                    NavigationLink {
                        ForemanGuideView()
                    } label: {
                        HubRow(title: "Пошаговый план работ",
                               detail: "15 направлений: шпаклёвка, плитка, ГКЛ, сантехника и другие",
                               symbol: "hammer.fill")
                    }
                    NavigationLink {
                        AIView()
                    } label: {
                        HubRow(title: "Умный ИИ-помощник",
                               detail: "Разобрать задачу, фото, смету или отчёт",
                               symbol: "sparkles")
                    }
                    NavigationLink {
                        PetrovichPurchaseView()
                    } label: {
                        HubRow(title: "Рассчитать материалы",
                               detail: "По площадям и технологическим допущениям",
                               symbol: "shippingbox.fill")
                    }
                }
                Section {
                    Label("Офлайн-планы доступны без интернета. Ответы нейросети требуют ключа kie.ai и могут содержать ошибки — ответственные монтажные решения нужно проверять.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Помощник")
        }
    }
}
