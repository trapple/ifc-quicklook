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

    /// バッチをシーンに追加。
    /// 頂点配列の組み立て（重いCPU処理）はバックグラウンド、MeshResource 生成は async 版で
    /// メインスレッドをブロックしない。追加したエンティティ群を返す（置き換え用）。
    @discardableResult
    func append(batches: [MaterialBatch]) async -> [ModelEntity] {
        let items = await Task.detached(priority: .userInitiated) {
            RKSceneBuilder.makeDescriptors(batches)
        }.value
        let entities = await RKSceneBuilder.makeEntities(items: items)
        entities.forEach { modelRoot.addChild($0) }
        return entities
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
            text = "⚠︎ \(summary.skippedElements)要素を省略（上限超過・全体表示は IFCQuickLook.app で開く）  " + text
        }
        overlayLabel.stringValue = text
    }

    private var loadTask: Task<Void, Never>?

    /// ビューが外れたらロードをキャンセルし、シーンのメッシュを即解放する。
    /// QL は appex プロセスを使い回すため、解放しないと前のプレビューの
    /// メッシュがメモリに残留し、次のファイルのメモリ上限を圧迫する。
    override func viewDidDisappear() {
        super.viewDidDisappear()
        loadTask?.cancel()
        modelRoot.children.removeAll()
    }

    /// ロード開始（プログレッシブ: バッチが届くたびに描画へ追加）
    func start(url: URL) {
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var framedOnce = false
            var loadedTriangles = 0
            let started = ContinuousClock.now
            do {
                for try await event in ModelLoader().events(for: url) {
                    switch event {
                    case .batches(let batches):
                        await self.append(batches: batches)
                        // 進捗を可視化（大型ファイルで「固まった」と誤解されないように）
                        loadedTriangles += batches.reduce(0) { $0 + $1.indices.count / 3 }
                        let elapsed = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
                        self.overlayLabel.stringValue = String(
                            format: "読み込み中… 三角形 %d  %.0fs", loadedTriangles, elapsed)
                        // 最初のバッチで即フレーミング（初回描画1秒以内の体感を作る）
                        if !framedOnce, let bounds = Self.bounds(of: batches) {
                            self.cameraController.frame(bounds)
                            self.cameraController.apply(to: self.cameraEntity)
                            framedOnce = true
                        }
                    case .finished(let summary, let consolidated):
                        // consolidated が全メッシュの正（高速ロード時は progressive が一度も
                        // 走らないため、ここで必ず描画する）。細切れエンティティは
                        // 新エンティティ構築後に一括置き換え（構築中に画面を空にしない）。
                        let old = Array(self.modelRoot.children)
                        let new = await self.append(batches: consolidated)
                        if !new.isEmpty {
                            old.forEach { $0.removeFromParent() }
                        }
                        self.finish(summary: summary)
                    }
                }
            } catch is CancellationError {
                // プレビューが閉じられただけ。エラー表示しない
            } catch {
                self.show(message: error.localizedDescription)
            }
        }
    }

    /// 初回フレーミング用: 受信済みバッチから暫定 AABB を計算
    private static func bounds(of batches: [MaterialBatch]) -> AABB? {
        var bounds: AABB?
        for batch in batches {
            var v = 0
            while v < batch.vertices.count {
                let p = SIMD3<Float>(batch.vertices[v], batch.vertices[v+1], batch.vertices[v+2])
                if bounds == nil { bounds = AABB(min: p, max: p) } else { bounds!.union(p) }
                v += 6
            }
        }
        return bounds
    }
}
