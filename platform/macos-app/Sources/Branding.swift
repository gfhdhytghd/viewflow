import AppKit

/// All representations are exported from platform/branding/viewflow.svg.
@MainActor enum Branding {
    static let applicationIcon: NSImage = {
        guard let url = Bundle.main.url(forResource: "viewflow", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Viewflow brand asset is missing from the application bundle")
        }
        return image
    }()

    static let menuIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        for name in ["viewflow-menu", "viewflow-menu@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else {
                preconditionFailure("Viewflow menu icon is missing from the application bundle")
            }
            representation.size = NSSize(width: 20, height: 20)
            image.addRepresentation(representation)
        }
        image.isTemplate = false
        return image
    }()
}
