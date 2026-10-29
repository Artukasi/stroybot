import RoomPlan
import SwiftUI

/// Scan one wall with live RoomPlan measurements and estimate GKL takeoff.
struct LiveWallScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = ScanController()
    @StateObject private var aiState = AIState()
    @State private var selectedID: String?
    @State private var spacing = 0.6
    @State private var layers = 1
    @State private var showingResults = false

    private var selectedWall: LiveWallMeasurement? {
        if let selectedID, let match = scanner.wallMeasurements.first(where: { $0.id == selectedID }) {
            return match
        }
        return scanner.wallMeasurements.max(by: { $0.length < $1.length })
    }
    private var selection: GKLTakeoff.Summary? {
        guard let wall = selectedWall else { return nil }
        return GKLTakeoff.liveWall(length: wall.length, height: wall.height, step: spacing, layers: layers)
    }
    private var report: String {
        guard let wall = selectedWall, let summary = selection else { return "Стену ещё не распознали." }
        var rows = ["СТРОЙСКАН · LiDAR-ЗАМЕР ОДНОЙ СТЕНЫ",
                    "Длина: \(GKLTakeoff.format(wall.length)) м",
                    "Высота: \(GKLTakeoff.format(wall.height)) м",
                    "Площадь БЕЗ вычета проёмов: \(GKLTakeoff.format(summary.area)) м²",
                    "Шаг стоек: \(Int((spacing * 100).rounded())) см",
                    "Слоёв ГКЛ: \(layers)",
                    "", "ЗАКУПКА (ЧЕРНОВАЯ):"]
        rows += summary.items.map { "• \($0.title): \($0.quantity). \($0.explanation)" }
        rows += ["", "ВНИМАНИЕ: дверные и оконные проёмы из экспресс-замера не вычтены.",
                 "Отсканируйте углы, подтвердите рулеткой ключевые размеры.",
                 "Монтаж каркаса и креплений — по конкретной системе производителя."]
        return rows.joined(separator: "\n")
    }

    private var aiBrief: String {
        guard let wall = selectedWall, let summary = selection else {
            return "Помоги спланировать облицовку стены гипсокартоном: задай вопросы по основанию, помещению и нагрузкам."
        }
        return """
        Я начинающий строитель. Помоги спланировать облицовку ОДНОЙ стены гипсокартоном.
        Данные LiDAR/RoomPlan, предварительные и не подтверждены рулеткой:
        длина \(GKLTakeoff.format(wall.length)) м, высота \(GKLTakeoff.format(wall.height)) м,
        площадь прямоугольника \(GKLTakeoff.format(summary.area)) м².
        Шаг стоек в ЭСКИЗЕ: \(Int((spacing * 100).rounded())) см.
        Листов ГКЛ: \(summary.sheets) шт., слоёв: \(layers).
        Общая геометрическая длина профилей: \(GKLTakeoff.format(summary.profileMeters)) пог. м.
        Предварительный список материалов:
        \(summary.items.map { "• \($0.title): \($0.quantity)" }.joined(separator: "\n"))

        Проёмы не вычитались! Окна, двери, трубы, качество основания и опасные зоны пока неизвестны.
        Объясни простым языком:
        1. Что мне надо дополнительно измерить и спросить заказчика.
        2. Какие профили подходят для облицовки и как выбирать систему по производителю;
           не выдумывай прочность, шаг креплений, анкеры и необходимость подвесов.
        3. Как уточнить количество листов, раскрой, перемычки, армирование, грунт, шпаклёвку и финиш.
        4. Пошаговый план с инструментами, проверками качества, этапами закупки и ошибками новичка.
        5. Какие решения обязан подтвердить специалист перед монтажом.
        Отдельно назови допущения и НЕ выдавай оценку скана за точный монтажный проект.
        """
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoomScanner(controller: scanner)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                HStack {
                    Button {
                        scanner.cancel()
                        dismiss()
                    } label: {
                        Label("Закрыть", systemImage: "xmark")
                    }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    Spacer()
                    Text("LiDAR · одна стена")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(.horizontal)
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Наведи камеру на всю стену и её углы")
                        .font(.headline)
                    Text("RoomPlan уточняет размеры по мере движения. Если видит несколько стен, выбери нужную ниже.")
                        .font(.caption).foregroundStyle(.secondary)
                    if scanner.wallMeasurements.isEmpty {
                        ProgressView("Ищу стену…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(scanner.wallMeasurements.indices, id: \.self) { index in
                                    let wall = scanner.wallMeasurements[index]
                                    let active = selectedWall?.id == wall.id
                                    Button {
                                        selectedID = wall.id
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Стена \(index + 1)").font(.caption.bold())
                                            Text("\(GKLTakeoff.format(wall.length)) × \(GKLTakeoff.format(wall.height)) м")
                                                .font(.caption2)
                                            if wall.lowConfidence {
                                                Text("Уточнить замер").font(.caption2)
                                            }
                                        }
                                        .padding(8)
                                        .foregroundStyle(active ? Palette.ink : Color.primary)
                                        .background(active ? Palette.signal : Color(.tertiarySystemGroupedBackground),
                                                    in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if let wall = selectedWall, let selection {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(GKLTakeoff.format(wall.length)) × \(GKLTakeoff.format(wall.height)) м")
                                        .font(.title3.bold())
                                    Text("≈ \(GKLTakeoff.format(selection.area)) м² · без вычета проёмов")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(selection.sheets) листов ГКЛ").font(.subheadline.bold())
                                    Text("\(selection.profileCount) профилей по 3 м")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if wall.lowConfidence {
                                Label("RoomPlan пока недостаточно уверен в стене. Пройди вдоль углов ещё раз.",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Button {
                                scanner.cancel()
                                showingResults = true
                            } label: {
                                Label("Расчёт материалов", systemImage: "list.bullet.clipboard")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.signal)
                        }
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showingResults, onDismiss: { dismiss() }) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let wall = selectedWall, let result = selection {
                            Text("Рассчитано по одной стене")
                                .font(.title2.bold())
                            Text("LiDAR: \(GKLTakeoff.format(wall.length)) × \(GKLTakeoff.format(wall.height)) м")
                                .font(.headline)
                            Text("Площадь без вычета дверей и окон — \(GKLTakeoff.format(result.area)) м²")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("Настроить раскладку").font(.headline)
                            Picker("Шаг стоек", selection: $spacing) {
                                Text("40 см").tag(0.4)
                                Text("60 см").tag(0.6)
                            }.pickerStyle(.segmented)
                            Picker("Слоёв ГКЛ", selection: $layers) {
                                Text("1 слой").tag(1)
                                Text("2 слоя").tag(2)
                                Text("3 слоя").tag(3)
                            }.pickerStyle(.segmented)
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(result.items) { item in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.subheadline.bold())
                                        Text(item.quantity).font(.subheadline).foregroundStyle(Palette.signal)
                                        Text(item.explanation).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Divider()
                                }
                            }
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            NavigationLink {
                                AITextView(kind: .foreman, state: aiState,
                                           prefill: aiBrief,
                                           placeholder: "Добавь материал стен, нагрузки, влажность и требования к звукоизоляции")
                            } label: {
                                Label("ИИ: разобрать стену и монтаж", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.signal)
                            if !aiState.ready {
                                Text("Для ИИ нужен интернет и ключ kie.ai. Офлайн-расчёт выше продолжает работать без него.")
                                    .font(.caption).foregroundStyle(.secondary)
                                NavigationLink {
                                    AIView()
                                } label: {
                                    Label("Подключить нейросеть", systemImage: "gearshape")
                                }
                            }
                            ShareLink(item: report) {
                                Label("Отправить список материалов", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.signal)
                            Text("Это экспресс-расчёт прямоугольной стены. Проёмы, перемычки и усиления, тип креплений, раскрой и специфика системы проверяются перед закупкой. LiDAR не заменяет контрольные измерения.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Размеры стены не сохранились. Повтори сканирование.")
                        }
                    }.padding()
                }
                .navigationTitle("Материалы для стены")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Готово") { showingResults = false; dismiss() }
                    }
                }
            }
        }
        .onDisappear { scanner.cancel() }
        .alert(scanner.failed ?? "", isPresented: Binding(
            get: { scanner.failed != nil },
            set: { if !$0 { scanner.failed = nil } }
        )) {
            Button("OK", role: .cancel) { scanner.failed = nil }
        }
    }
}
