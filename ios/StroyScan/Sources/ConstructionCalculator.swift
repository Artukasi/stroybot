import Foundation

/// Single calculation source for approximate finish material consumption.
/// Rates are default assumptions, not a brand's technical data sheet.
enum ConstructionCalculator {
    static func kilograms(area: Double, thicknessMM: Double, kgPerM2PerMM: Double,
                          reserve: Double = 0.10) -> Double {
        max(0, area) * max(0, thicknessMM) * max(0, kgPerM2PerMM) * (1 + max(0, reserve))
    }

    static func liters(area: Double, coats: Int, litersPerM2Coat: Double,
                       reserve: Double = 0.10) -> Double {
        max(0, area) * Double(max(1, coats)) * max(0, litersPerM2Coat) * (1 + max(0, reserve))
    }

    static func tileArea(_ area: Double, reserve: Double = 0.10) -> Double {
        max(0, area) * (1 + max(0, reserve))
    }

    static func packages(quantity: Double, packageSize: Double) -> Int {
        guard quantity.isFinite, packageSize.isFinite, packageSize > 0 else { return 0 }
        return Int(ceil(max(0, min(1_000_000, quantity)) / packageSize))
    }

    // Notes: gypsum plaster (0.9 kg/m²/mm), finish putty (1.2 kg/m²/mm),
    // typical paint coat (0.12 l/m²), tile adhesive (~5 kg/m²) are placeholders.
    static func plasterKg(_ area: Double, mm: Double = 10, reserve: Double = 0.10) -> Double {
        kilograms(area: area, thicknessMM: mm, kgPerM2PerMM: 0.9, reserve: reserve)
    }
    static func puttyKg(_ area: Double, mm: Double = 1, reserve: Double = 0.10) -> Double {
        kilograms(area: area, thicknessMM: mm, kgPerM2PerMM: 1.2, reserve: reserve)
    }
    static func paintLiters(_ area: Double, coats: Int = 2, reserve: Double = 0.10) -> Double {
        liters(area: area, coats: coats, litersPerM2Coat: 0.12, reserve: reserve)
    }
    static func tileGlueKg(_ area: Double, reserve: Double = 0.10) -> Double {
        max(0, area) * 5 * (1 + max(0, reserve))
    }
    static func primerLiters(_ area: Double, coats: Int = 1) -> Double {
        liters(area: area, coats: coats, litersPerM2Coat: 0.12, reserve: 0)
    }
}
