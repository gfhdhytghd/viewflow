import SwiftUI

struct DisplayLayoutView: View {
    @ObservedObject var controller: PairingController
    @State private var guides: [SnapGuide] = []
    private var editable: Bool { controller.role == "host" && !controller.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editable ? "拖动屏幕排列位置，或输入坐标微调。主机屏幕固定在原点，位置自动同步到从机。" : "显示器位置由主机统一设置。")
                .foregroundStyle(.secondary)
            if controller.displays.isEmpty { Text("配对后可设置显示器位置。").foregroundStyle(.secondary) }
            else {
                GeometryReader { geometry in
                    let displays = controller.displays
                    let left = min(0, displays.map(\.x).min() ?? 0)
                    let top = min(0, displays.map(\.y).min() ?? 0)
                    let right = max(1, displays.map { $0.x + $0.width }.max() ?? 1)
                    let bottom = max(1, displays.map { $0.y + $0.height }.max() ?? 1)
                    let zoom = min((geometry.size.width - 64) / CGFloat(right - left), 194 / CGFloat(bottom - top))
                    let dx = (geometry.size.width - CGFloat(right-left)*zoom)/2
                    let dy = (250 - CGFloat(bottom-top)*zoom)/2
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.08))
                        ForEach(displays) { display in
                            DisplayTile(display: display, screens: displays, zoom: zoom, editable: editable && !display.host, guides: $guides) { x, y in
                                controller.send("setDisplayPosition", id: display.id, x: x, y: y)
                            }
                            .offset(x: dx + CGFloat(display.x-left)*zoom, y: dy + CGFloat(display.y-top)*zoom)
                        }
                        Path { path in
                            for line in guides {
                                path.move(to: CGPoint(x: dx+CGFloat(line.x1-Double(left))*zoom, y: dy+CGFloat(line.y1-Double(top))*zoom))
                                path.addLine(to: CGPoint(x: dx+CGFloat(line.x2-Double(left))*zoom, y: dy+CGFloat(line.y2-Double(top))*zoom))
                            }
                        }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .allowsHitTesting(false)
                    }.coordinateSpace(name: "displayCanvas").clipped()
                }.frame(height: 250)
                ForEach(controller.displays) { display in
                    DisplayPositionRow(display: display, controller: controller, editable: editable && !display.host)
                }
            }
            Text("坐标以逻辑像素计，X 向右、Y 向下。屏幕始终保持贴边，不能孤立或重叠。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DisplayTile: View {
    let display: GroupDisplay
    let screens: [GroupDisplay]
    let zoom: CGFloat
    let editable: Bool
    @Binding var guides: [SnapGuide]
    let save: (Int, Int) -> Void
    @State private var preview: SnapResult?
    @GestureState private var dragging = false
    private func result(_ translation: CGSize, settle: Bool) -> SnapResult {
        let rectangles = screens.map { SnapScreen(id: $0.id, x: Double($0.x), y: Double($0.y), width: Double($0.width), height: Double($0.height)) }
        let moving = SnapScreen(id: display.id, x: Double(display.x), y: Double(display.y), width: Double(display.width), height: Double(display.height))
        return DisplaySnap.snap(moving, screens: rectangles, x: Double(display.x)+Double(translation.width/zoom), y: Double(display.y)+Double(translation.height/zoom), zoom: Double(zoom), settle: settle)
    }
    var body: some View {
        VStack(spacing: 4) {
            Text(display.name).lineLimit(1).font(.caption)
            Text("\(display.width) × \(display.height)").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: CGFloat(display.width)*zoom, height: CGFloat(display.height)*zoom)
        .background(display.host ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.6), lineWidth: 2))
        .offset(x: CGFloat((preview?.x ?? Double(display.x))-Double(display.x))*zoom,
                y: CGFloat((preview?.y ?? Double(display.y))-Double(display.y))*zoom)
        .gesture(DragGesture(coordinateSpace: .named("displayCanvas")).updating($dragging) { _, state, _ in
            state = editable
        }.onChanged { value in
            guard editable else { return }
            let snapped = result(value.translation, settle: true)
            preview = snapped; guides = snapped.guides
        }.onEnded { value in
            guard editable else { return }
            let snapped = result(value.translation, settle: true)
            if Int(snapped.x) != display.x || Int(snapped.y) != display.y { save(Int(snapped.x), Int(snapped.y)) }
            preview = nil; guides = []
        })
        .onChange(of: dragging) { active in if !active { preview = nil; guides = [] } }
    }
}

private struct DisplayPositionRow: View {
    let display: GroupDisplay
    @ObservedObject var controller: PairingController
    let editable: Bool
    @State private var x = ""
    @State private var y = ""
    var body: some View {
        HStack {
            Text(display.name).lineLimit(1)
            Spacer()
            Text("X").foregroundStyle(.secondary)
            TextField("X", text: $x).frame(width: 80).disabled(!editable)
            Text("Y").foregroundStyle(.secondary)
            TextField("Y", text: $y).frame(width: 80).disabled(!editable)
            if editable {
                Button {
                    if let x = Int(x), let y = Int(y) { controller.send("setDisplayPosition", id: display.id, x: x, y: y) }
                } label: { Image(systemName: "checkmark") }
                .help("应用位置").accessibilityLabel("应用位置").disabled(Int(x) == nil || Int(y) == nil)
            }
        }
        .onAppear { x = String(display.x); y = String(display.y) }
        .onChange(of: display.x) { x = String($0) }
        .onChange(of: display.y) { y = String($0) }
    }
}
