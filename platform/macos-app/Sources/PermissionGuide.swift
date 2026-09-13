import AppKit
import SwiftUI

@MainActor final class PermissionGuide {
    private var panel: NSPanel?

    func show(title: String, appURL: URL, refresh: @escaping () -> Void) {
        let window = panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 430),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "添加 Viewflow 权限"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PermissionGuideView(title: title, appURL: appURL,
            refresh: refresh, close: { [weak window] in window?.close() }))
        if panel == nil, let frame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.maxX - 370, y: frame.midY - 215))
        }
        panel = window
        window.orderFrontRegardless()
    }
}

private struct PermissionGuideView: View {
    let title: String
    let appURL: URL
    let refresh: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            AppDragIcon(appURL: appURL).frame(width: 76, height: 76)
            Text("将上方 Viewflow 图标拖入权限列表").font(.subheadline).bold()
            Text("添加后打开 Viewflow 旁的开关。如果列表不接受拖放，请点击「＋」选择这个应用。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("在 Finder 中显示应用") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
            Button("已添加，返回检查") { refresh(); close() }
                .buttonStyle(.borderedProminent)
        }.padding(20).frame(width: 350, height: 430)
    }
}

private struct AppDragIcon: NSViewRepresentable {
    let appURL: URL
    func makeNSView(context: Context) -> AppDragView { AppDragView(appURL: appURL) }
    func updateNSView(_ view: AppDragView, context: Context) { view.appURL = appURL; view.needsDisplay = true }
}

private final class AppDragView: NSView, NSDraggingSource {
    var appURL: URL
    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: NSRect(x: 0, y: 0, width: 76, height: 76))
        toolTip = "拖动 Viewflow.app 到系统设置"
        setAccessibilityLabel("Viewflow 应用，拖到系统设置权限列表")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSWorkspace.shared.icon(forFile: appURL.path).draw(in: bounds.insetBy(dx: 4, dy: 4))
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: appURL.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
