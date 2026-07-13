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

    // ドラッグは NSPanGestureRecognizer で受ける。理由:
    // - QL のリモートビュー転送（ViewBridge）は生の mouseDown/mouseDragged を
    //   ホスト側（Finderプレビュー欄のファイルドラッグ判定等）が消費してしまい、
    //   ビューの override にはほぼ届かない（プロセスまでは届く）。レコグナイザは
    //   ホストとのイベント調停に乗るため、欄・パネルの両方でドラッグを主張できる
    //   （Apple 純正 usdz プレビューが欄で回るのも同じ仕組みと推定）。
    // - さらに ViewBridge は NSEvent の deltaX/deltaY を 0 に潰すため、生イベントでは
    //   デルタ計算も自前で必要だった。translation(in:) はその問題も回避する。
    private var gesturesInstalled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !gesturesInstalled, window != nil else { return }
        gesturesInstalled = true
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        // 注意: 右ボタンを buttonMask=0x2 のレコグナイザで受ける構成は QL パネルでは
        // 一切発火しない（実測）。右ドラッグは生イベント＋位置差分で処理する（下記）。
    }

    /// 差分を取り出してリセット（AppKit 座標は Y 上向き → 下向き正へ反転）
    private func consumeTranslation(_ g: NSPanGestureRecognizer) -> (Float, Float) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        return (Float(t.x), Float(-t.y))
    }

    @objc private func handlePan(_ g: NSPanGestureRecognizer) {
        let (dx, dy) = consumeTranslation(g)
        if NSEvent.modifierFlags.contains(.shift) {
            onPan?(dx, dy)
        } else {
            onOrbit?(dx, dy)
        }
    }

    // 右（2本指クリック）ドラッグのパン。
    // レコグナイザ（buttonMask=0x2）は QL パネルで発火しないため生イベントで受ける。
    // 生イベントの右ボタン系はパネルでもビューまで届く（左と違いホストに食われない）が、
    // deltaX/deltaY は例によって 0 に潰されるため位置差分で計算する。
    // Finder プレビュー欄では右イベント自体が届かないため、欄でのパンは Shift+ドラッグを使う。
    private var lastRightDragLocation: NSPoint?

    override func rightMouseDown(with event: NSEvent) {
        lastRightDragLocation = event.locationInWindow
    }
    override func rightMouseDragged(with event: NSEvent) {
        let loc = event.locationInWindow
        if let last = lastRightDragLocation {
            onPan?(Float(loc.x - last.x), Float(last.y - loc.y))
        }
        lastRightDragLocation = loc
    }
    override func rightMouseUp(with event: NSEvent) {
        lastRightDragLocation = nil
    }
    override func scrollWheel(with event: NSEvent) {
        onZoom?(Float(event.scrollingDeltaY) * 0.1)
    }
    override func magnify(with event: NSEvent) {
        onZoom?(Float(event.magnification) * 10)
    }
}
