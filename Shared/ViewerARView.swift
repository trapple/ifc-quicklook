import AppKit
import RealityKit

/// マウス/スクロール/ピンチをオービットカメラ操作に変換する ARView（macOS・非AR）。
final class ViewerARView: ARView {
    var onOrbit: ((Float, Float) -> Void)?
    var onZoom: ((Float) -> Void)?
    var onPan: ((Float, Float) -> Void)?

    /// Finder のプレビューペイン等、ホストウィンドウが key にならない文脈では
    /// 最初のクリックが click-through 防止で捨てられ、mouseDown が届かないため
    /// ドラッグ回転が一切効かない（スクロールはカーソル下に届くのでズームだけ効く）。
    /// 最初のクリックから受け付けてドラッグを成立させる。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // QL のリモートビュー転送（ViewBridge）では NSEvent の deltaX/deltaY が常に 0 に
    // 潰される（locationInWindow は正しい）ため、ドラッグのデルタは位置の差分から
    // 自前で計算する。deltaX/deltaY 頼みだと QL プレビューで回転・パンが一切効かない。
    private var lastDragLocation: NSPoint?

    private func dragDelta(_ event: NSEvent) -> (Float, Float) {
        let loc = event.locationInWindow
        defer { lastDragLocation = loc }
        guard let last = lastDragLocation else { return (0, 0) }
        // AppKit 座標は Y 上向き。deltaY は「下に動かすと正」の慣習に合わせて反転
        return (Float(loc.x - last.x), Float(last.y - loc.y))
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
    }
    override func rightMouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
    }
    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
    }
    override func rightMouseUp(with event: NSEvent) {
        lastDragLocation = nil
    }
    override func mouseDragged(with event: NSEvent) {
        let (dx, dy) = dragDelta(event)
        if event.modifierFlags.contains(.shift) {
            onPan?(dx, dy)
        } else {
            onOrbit?(dx, dy)
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        let (dx, dy) = dragDelta(event)
        onPan?(dx, dy)
    }
    override func scrollWheel(with event: NSEvent) {
        onZoom?(Float(event.scrollingDeltaY) * 0.1)
    }
    override func magnify(with event: NSEvent) {
        onZoom?(Float(event.magnification) * 10)
    }
}
