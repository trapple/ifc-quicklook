import AppKit
import RealityKit

/// 読み込み結果サマリ
struct LoadSummary {
    let schema: String
    let elementCount: Int
    let triangleCount: Int
    let skippedElements: Int
    let seconds: Double
    let bounds: AABB?
}

/// 3D ビューア本体。App の単体ビューアと QL 拡張の両方から使う。
final class ViewerViewController: NSViewController {
    private let arView = ViewerARView(frame: .zero)
    private let cameraEntity = PerspectiveCamera()
    private let cameraController = OrbitCameraController()
    private let modelRoot = Entity()
    private let overlayLabel = NSTextField(labelWithString: "読み込み中…")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        arView.frame = view.bounds
        arView.autoresizingMask = [.width, .height]
        arView.environment.background = .color(.underPageBackgroundColor)
        view.addSubview(arView)

        // シーングラフ: モデルルート + カメラ + 平行光源
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(modelRoot)
        let light = DirectionalLight()
        light.light.intensity = 5_000
        light.orientation = simd_quatf(angle: -.pi / 3, axis: simd_normalize(SIMD3<Float>(1, 0.3, 0)))
        anchor.addChild(light)
        anchor.addChild(cameraEntity)
        arView.scene.addAnchor(anchor)
        cameraController.apply(to: cameraEntity)

        // カメラ操作をバインド
        arView.onOrbit = { [weak self] dx, dy in self?.updateCamera { $0.orbit(dx: dx, dy: dy) } }
        arView.onZoom = { [weak self] d in self?.updateCamera { $0.zoom(delta: d) } }
        arView.onPan = { [weak self] dx, dy in self?.updateCamera { $0.pan(dx: dx, dy: dy) } }

        // HUD オーバーレイ（左下）
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayLabel)
        // エラービュー（中央・初期非表示）
        errorLabel.textColor = .labelColor
        errorLabel.font = .systemFont(ofSize: 14)
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            overlayLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            overlayLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    private func updateCamera(_ mutate: (OrbitCameraController) -> Void) {
        mutate(cameraController)
        cameraController.apply(to: cameraEntity)
    }

    /// エラー表示（Fail Fast: 理由を明示し 3D ビューを隠す）
    func show(message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        overlayLabel.isHidden = true
        arView.isHidden = true
    }

    /// バッチをシーンに追加
    func append(batches: [MaterialBatch]) {
        for entity in RKSceneBuilder.makeEntities(batches) {
            modelRoot.addChild(entity)
        }
    }

    /// 読み込み完了: カメラフレーミングとサマリ表示
    func finish(summary: LoadSummary) {
        if let bounds = summary.bounds {
            cameraController.frame(bounds)
            cameraController.apply(to: cameraEntity)
        }
        var text = "\(summary.schema)  要素 \(summary.elementCount)  三角形 \(summary.triangleCount)  " +
                   String(format: "%.1fs", summary.seconds)
        if summary.skippedElements > 0 {
            text = "⚠︎ \(summary.skippedElements)要素を省略（上限超過）  " + text
        }
        overlayLabel.stringValue = text
    }

    /// ロード開始（Task 8 で ModelLoader によるプログレッシブ版に差し替える。ここは仮の一括版）
    func start(url: URL) {
        let started = ContinuousClock.now
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let batcher = MeshBatcher()
            do {
                let info = try WebIFCBridge().streamMeshes(fromFileAtPath: url.path) { batcher.add($0) }
                let batches = batcher.drain()
                let seconds = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
                let summary = LoadSummary(schema: info.schemaVersion, elementCount: Int(info.elementCount),
                                          triangleCount: batcher.totalTriangles,
                                          skippedElements: batcher.skippedElements,
                                          seconds: seconds, bounds: batcher.bounds)
                DispatchQueue.main.async {
                    self?.append(batches: batches)
                    self?.finish(summary: summary)
                }
            } catch {
                DispatchQueue.main.async { self?.show(message: error.localizedDescription) }
            }
        }
    }
}
