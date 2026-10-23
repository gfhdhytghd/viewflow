import Foundation
struct SnapCase: Decodable {
    var name: String
    var moving: SnapScreen
    var screens: [SnapScreen]
    var x: Double
    var y: Double
    var zoom: Double
    var settle: Bool
    var expected: [Double]
}
@main struct DisplaySnapTests {
    static func main() throws {
        let cases = try JSONDecoder().decode([SnapCase].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for c in cases {
            let actual = DisplaySnap.snap(c.moving, screens: c.screens, x: c.x, y: c.y, zoom: c.zoom, settle: c.settle)
            precondition([actual.x, actual.y] == c.expected, "\(c.name): \(actual)")
        }
        print("Display snap cases passed: \(cases.count); no input posted")
    }
}
