import Foundation
import simd

/// Preliminary takeoff from the LiDAR-derived drywall framing sketch.
/// Geometry is measured; fixings, sheet waste and safety factors are assumptions.
enum GKLTakeoff {
    struct Item: Identifiable {
        let title: String
        let quantity: String
        let explanation: String
        var id: String { title }
    }

    struct Summary {
        let area: Double
        let profileMeters: Double
        let profileCount: Int
        let sheets: Int
        let items: [Item]
    }

    static func plan(room: RoomResult, mode: GKLFrame.Mode, selectedWalls: Set<Int>,
                     partitionLength: Double, layout: GKLFrame.Layout,
                     layers: Int, sides: Int, stockLength: Double = 3) -> Summary {
        let geometry = Room3D(room)
        let h = Double(geometry.height)
        var netArea: Double = 0
        var linearGuides: Double = 0
        var studsLength: Double = 0
        var crossLength: Double = 0
        var openingCount = 0

        if mode == .wall {
            for index in geometry.walls.indices where selectedWalls.contains(index) {
                let wall = geometry.walls[index]
                let gross = Double(wall.length) * h
                let openings = geometry.openings[index]
                let cut = openings.reduce(0.0) { sum, opening in
                    sum + Double(opening.width * opening.height)
                }
                netArea += max(0, gross - cut)
                openingCount += openings.count
            }
        } else if mode == .partition {
            netArea = layout.beams.isEmpty ? 0 : max(0, partitionLength) * h
        } else {
            netArea = max(0, room.floorArea)
        }

        for beam in layout.beams {
            switch beam.label {
            case let label where label.contains("направляющая"):
                linearGuides += Double(beam.length)
            case let label where label.contains("Стойка") || label.contains("Край проёма"):
                studsLength += Double(beam.length)
            case let label where label.contains("Перемычка"):
                crossLength += Double(beam.length)
            default:
                crossLength += Double(beam.length)
            }
        }

        let profileTotal = linearGuides + studsLength + crossLength
        let faceCount = mode == .partition ? max(1, min(2, sides)) : 1
        let sheetLayers = max(1, min(3, layers))
        let coverage = netArea * Double(faceCount * sheetLayers)
        let sheets = Int(ceil(coverage * 1.12 / 3.0))
        let guides3m = Int(ceil(linearGuides * 1.15 / stockLength))
        let studs3m = Int(ceil((studsLength + crossLength) * 1.15 / stockLength))
        let totalStock = guides3m + studs3m

        // Screw and jointing estimates for a *planning* allowance only;
        // exact spacing and consumptions follow a selected tested system.
        let screws = Int(ceil(coverage * 25 * 1.10 / 100)) * 100
        let tape = Int(ceil(coverage * 1.3 * 1.10))
        let jointCompound = Int(ceil(coverage * 0.25 * 1.10))
        let finishCompound = Int(ceil(coverage * 1.0 * 1.10))
        let insulation = mode == .partition ? Int(ceil(netArea * 1.05)) : 0

        var items: [Item] = [
            Item(title: "Направляющие профили (заготовки \(format(stockLength)) м)",
                 quantity: "\(guides3m) шт. · \(format(linearGuides)) пог. м по схеме",
                 explanation: "Запас 15% условный; считать по раскрою, основанию и узлам примыкания."),
            Item(title: mode == .ceiling ? "Потолочные профили / перемычки" : "Стоечные профили / перемычки",
                 quantity: "\(studs3m) шт. · \(format(studsLength + crossLength)) пог. м по схеме",
                 explanation: "При потолке профили и подвесы требуют схемы выбранной системы; при стенах — проверки стоек и усилений."),
            Item(title: "Листы ГКЛ 1200×2500 мм",
                 quantity: "\(sheets) шт. · \(format(coverage)) м² без запаса",
                 explanation: "\(sheetLayers) сл. × \(faceCount) сторона(ы); запас 12%. При высоте больше 2,5 м будут горизонтальные стыки и возможен перерасход."),
            Item(title: "Саморезы для ГКЛ",
                 quantity: "≈ \(screws) шт.",
                 explanation: "Ориентир 25 шт./м² каждого слоя с запасом 10%; тип и шаг крепления — по системе производителя."),
            Item(title: "Лента для швов",
                 quantity: "≈ \(tape) пог. м",
                 explanation: "Предварительный ориентир 1,3 м на м² обшивки, уточняется по раскладке листов."),
            Item(title: "Шпаклёвка швов",
                 quantity: "≈ \(jointCompound) кг",
                 explanation: "Предварительно 0,25 кг/м² обшивки, расход зависит от швов и марки."),
            Item(title: "Финишная шпаклёвка (если требуется)",
                 quantity: "≈ \(finishCompound) кг на 1 мм",
                 explanation: "Ориентир 1 кг/м² при 1 мм; точный расход по смеси и уровню отделки."),
            Item(title: "Крепления / дюбели / подвесы / соединители",
                 quantity: "По монтажной системе",
                 explanation: "Нельзя посчитать безопасно без выбранной системы, основания, нагрузок и шагов креплений.")
        ]
        if insulation > 0 {
            items.append(Item(title: "Звукоизоляция для перегородки",
                              quantity: "≈ \(insulation) м²",
                              explanation: "По конструкции, плотности и толщине — после выбора системы."))
        }
        if openingCount > 0 {
            items.append(Item(title: "Проёмы", quantity: "\(openingCount) шт.",
                              explanation: "Учтены в чистой площади, но крепление и усиление проёмов требуют отдельного узла."))
        }

        return Summary(area: netArea, profileMeters: profileTotal,
                       profileCount: totalStock, sheets: sheets, items: items)
    }

    static func format(_ number: Double) -> String {
        String(format: "%.1f", number).replacingOccurrences(of: ".", with: ",")
    }
}
