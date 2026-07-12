import AppKit
import RealityKit

/// マウス/スクロール/ピンチをオービットカメラ操作に変換する ARView（macOS・非AR）。
final class ViewerARView: ARView {
    var onOrbit: ((Float, Float) -> Void)?
    var onZoom: ((Float) -> Void)?
    var onPan: ((Float, Float) -> Void)?

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            onPan?(Float(event.deltaX), Float(event.deltaY))
        } else {
            onOrbit?(Float(event.deltaX), Float(event.deltaY))
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        onPan?(Float(event.deltaX), Float(event.deltaY))
    }
    override func scrollWheel(with event: NSEvent) {
        onZoom?(Float(event.scrollingDeltaY) * 0.1)
    }
    override func magnify(with event: NSEvent) {
        onZoom?(Float(event.magnification) * 10)
    }
}
