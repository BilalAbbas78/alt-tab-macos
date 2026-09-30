import Cocoa

/// One panel per previewed window: the selected window's, plus its Split View partner's when it has one.
/// `shared` is the selected window's panel and is what `App` creates; `partner` is created on first use.
class PreviewPanel: NSPanel {
    private let previewView = LightImageView()
    private let borderView = BorderView()
    private var currentId: CGWindowID?
    static var shared: PreviewPanel!
    private static var partner: PreviewPanel?
    private static var panels: [PreviewPanel] { [shared, partner].compactMap { $0 } }

    /// this allows the window to be above the menubar when its origin.y is set to 0
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        applyFloatingPanelChrome()
        titlebarAppearsTransparent = true
        contentView = previewView
        borderView.autoresizingMask = [.width, .height]
        previewView.addSubview(borderView)
        if Self.shared == nil { Self.shared = self }
    }

    private static func partnerPanel() -> PreviewPanel {
        if let partner { return partner }
        let panel = PreviewPanel()
        partner = panel
        return panel
    }

    /// `partnerOf` is the Split View partner to preview next to the selected window, if any.
    static func show(_ id: CGWindowID, _ preview: CALayerContents, _ position: CGPoint, _ size: CGSize,
                     partner partnerOf: (id: CGWindowID, preview: CALayerContents, position: CGPoint, size: CGSize)? = nil) {
        shared.show(id, preview, position, size)
        if let partnerOf {
            partnerPanel().show(partnerOf.id, partnerOf.preview, partnerOf.position, partnerOf.size)
        } else {
            partner?.hide()
        }
    }

    private func show(_ id: CGWindowID, _ preview: CALayerContents, _ position: CGPoint, _ size: CGSize) {
        repositionAndResize(position, size)
        if id != currentId {
            previewView.updateContents(preview, size)
        }
        if id != currentId || !isVisible {
            if Preferences.previewFadeInAnimation {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    animator().alphaValue = 1
                }
            }
            currentId = id
            order(.below, relativeTo: TilesPanel.shared.windowNumber)
            // Despite using `previewPanel.order(.below)`, a z-ordering issue can occur in the following scenario:
            // 1. Show a preview of a window that is on a different monitor than the thumbnails panel
            // 2. Select a window in the switcher that is on the same monitor as the thumbnails panel, and whose position overlaps with the thumbnails panel
            // 3. For a single frame, the preview of the newly selected window can appear above the thumbnails panel before going back underneath it
            // Simply using order(.below) is not sufficient to prevent this brief flicker. We explicitly set the preview panel's window level to be one below the thumbnails panel
            level = NSWindow.Level(rawValue: TilesPanel.shared.level.rawValue - 1)
        }
    }

    static func updateIfShowing(_ id: CGWindowID?,  _ preview: CALayerContents, _ position: CGPoint, _ size: CGSize) {
        panels.forEach { panel in
            if panel.isVisible && id == panel.currentId {
                panel.repositionAndResize(position, size)
                panel.previewView.updateContents(preview, size)
            }
        }
    }

    /// Order out AND release the displayed frame: the layer would otherwise pin a full-resolution
    /// frame in this static view for the rest of the app's lifetime, defeating the session-scoped
    /// Preview-frame cache's release-on-hide (#5861).
    static func hide() {
        panels.forEach { $0.hide() }
    }

    private func hide() {
        orderOut(nil)
        previewView.releaseImage()
        currentId = nil
    }

    /// Called when a window is removed from `Windows.list`: if our preview was showing that
    /// window, drop the cached IOSurface in `previewView.contents` so it can deallocate.
    /// Without this, closing the previewed window in the background leaves its full-resolution
    /// screenshot pinned in the static `previewView` for the rest of the app's lifetime.
    static func clearIfShowing(_ wid: CGWindowID) {
        panels.filter { $0.currentId == wid }.forEach {
            $0.previewView.releaseImage()
            $0.currentId = nil
        }
    }

    private func repositionAndResize( _ position: CGPoint, _ size: CGSize) {
        var frame = NSRect(origin: position, size: size)
        // Flip Y coordinate from Quartz (0,0 at bottom-left) to Cocoa coordinates (0,0 at top-left)
        // Always use the primary screen as reference since all coordinates are relative to it
        frame.origin.y = NSScreen.screens.first!.frame.maxY - frame.maxY
        setFrame(frame, display: false)
    }
}

private class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 5, yRadius: 5).reversed)
        NSColor.systemAccentColor.withAlphaComponent(0.5).setFill()
        path.fill()
    }
}
