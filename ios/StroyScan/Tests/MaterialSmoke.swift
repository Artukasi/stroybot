import Foundation

@main
enum MaterialSmoke {
    static func main() {
        func almost(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
        precondition(almost(ConstructionCalculator.puttyKg(10, reserve: 0), 12))
        precondition(almost(ConstructionCalculator.paintLiters(10, coats: 2, reserve: 0), 2.4))
        precondition(almost(ConstructionCalculator.plasterKg(10, reserve: 0), 99))
        precondition(almost(ConstructionCalculator.tileArea(12, reserve: 0.1), 13.2))
        precondition(ConstructionCalculator.packages(quantity: 31, packageSize: 20) == 2)
        precondition(ConstructionCalculator.packages(quantity: -10, packageSize: 20) == 0)
        precondition(ConstructionCalculator.packages(quantity: 10, packageSize: 0) == 0)
        print("StroyScan 2.0: material formula smoke checks passed")
    }
}
