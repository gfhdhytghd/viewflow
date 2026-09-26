import Foundation

struct SnapScreen: Codable {
    var id: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
struct SnapGuide: Codable { var x1: Double; var y1: Double; var x2: Double; var y2: Double }
struct SnapResult: Codable { var x: Double; var y: Double; var guides: [SnapGuide] }

enum DisplaySnap {
    static func overlaps(_ a: SnapScreen, _ b: SnapScreen) -> Bool {
        a.x < b.x+b.width && a.x+a.width > b.x && a.y < b.y+b.height && a.y+a.height > b.y
    }
    static func snap(_ moving: SnapScreen, screens: [SnapScreen], x: Double, y: Double, zoom: Double, settle: Bool) -> SnapResult {
        let tolerance = 14 / max(zoom, 0.001)
        let others = screens.filter { $0.id != moving.id }
        var best: SnapResult?, bestScore = Double.infinity, bestKey = ""
        func candidate(_ d: SnapScreen, _ axis: String, _ edge: Double, _ initialX: Double, _ initialY: Double) {
            let force = settle
            if !force && abs((axis == "x" ? x : y)-edge) > tolerance { return }
            var px = initialX, py = initialY
            if axis == "x" {
                py = y
                if force { py = max(d.y-moving.height+min(64,moving.height,d.height), min(py, d.y+d.height-min(64,moving.height,d.height))) }
                if py >= d.y+d.height || py+moving.height <= d.y { return }
            } else {
                px = x
                if force { px = max(d.x-moving.width+min(64,moving.width,d.width), min(px, d.x+d.width-min(64,moving.width,d.width))) }
                if px >= d.x+d.width || px+moving.width <= d.x { return }
            }
            px = floor(px+0.5); py = floor(py+0.5)
            let placed = SnapScreen(id: moving.id, x: px, y: py, width: moving.width, height: moving.height)
            if others.contains(where: { overlaps(placed, $0) }) { return }
            let score = (px-x)*(px-x)+(py-y)*(py-y)
            let edgeKey = edge == floor(edge) ? String(Int(edge)) : String(edge)
            let key = d.id+axis+edgeKey
            if best != nil && (score > bestScore || (score == bestScore && key >= bestKey)) { return }
            var guides: [SnapGuide] = []
            if axis == "x" {
                let contact = px == d.x+d.width ? px : d.x
                guides.append(SnapGuide(x1: contact, y1: min(py,d.y), x2: contact, y2: max(py+moving.height,d.y+d.height)))
                for k in 0..<3 {
                    let line = py+moving.height*Double(k)/2
                    if abs(line-(d.y+d.height*Double(k)/2)) < 0.51 {
                        guides.append(SnapGuide(x1: min(px,d.x), y1: line, x2: max(px+moving.width,d.x+d.width), y2: line))
                    }
                }
            } else {
                let contact = py == d.y+d.height ? py : d.y
                guides.append(SnapGuide(x1: min(px,d.x), y1: contact, x2: max(px+moving.width,d.x+d.width), y2: contact))
                for k in 0..<3 {
                    let line = px+moving.width*Double(k)/2
                    if abs(line-(d.x+d.width*Double(k)/2)) < 0.51 {
                        guides.append(SnapGuide(x1: line, y1: min(py,d.y), x2: line, y2: max(py+moving.height,d.y+d.height)))
                    }
                }
            }
            best = SnapResult(x: px, y: py, guides: guides); bestScore = score; bestKey = key
        }
        for d in others {
            candidate(d,"x",d.x+d.width,d.x+d.width,y)
            candidate(d,"x",d.x-moving.width,d.x-moving.width,y)
            candidate(d,"y",d.y+d.height,x,d.y+d.height)
            candidate(d,"y",d.y-moving.height,x,d.y-moving.height)
        }
        return best ?? SnapResult(x: floor(x+0.5), y: floor(y+0.5), guides: [])
    }
}
