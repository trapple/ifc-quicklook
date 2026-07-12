import Foundation

enum LoadEvent {
    case batches([MaterialBatch])                          // 途中経過（プログレッシブ描画用）
    case finished(LoadSummary, consolidated: [MaterialBatch]) // 完了サマリ + 色単位に再統合した最終メッシュ
}

/// スレッド安全なキャンセルフラグ
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// バックグラウンドでパースし、バッチを flush する。
/// 「最初のバッチが揃った時点で描画開始」を実現する心臓部。
///
/// flush 戦略: 初回は flushInterval（既定0.25s）で早く出して体感を作り、
/// 以降は「50万三角形 or 1秒」ごと。中間エンティティは完了時に
/// 色単位の consolidated へ置き換えられるため、描画負荷は最終的に色数程度に収束する。
final class ModelLoader {
    /// web-ifc の並走禁止ゲート。
    /// QL は同一プロセスで連続プレビューするため、ファイル切替時に複数のパースが
    /// 並走しうる。web-ifc（fuzzybools 等）はグローバル状態を持ちスレッドセーフでは
    /// ないため、プロセス内で同時に 1 パースに直列化する（データレースで SIGBUS した実績あり）。
    private static let gate = DispatchSemaphore(value: 1)

    /// 2回目以降の flush 閾値
    private static let flushTriangles = 500_000
    private static let flushSeconds: Duration = .seconds(1)

    func events(for url: URL,
                triangleLimit: Int = 20_000_000,
                flushInterval: Double = 0.25) -> AsyncThrowingStream<LoadEvent, Error> {
        AsyncThrowingStream { continuation in
            let cancelled = CancelFlag()
            // 消費側の Task がキャンセルされたら（= プレビューが閉じられたら）フラグを立てる
            continuation.onTermination = { _ in cancelled.cancel() }

            // web-ifc の GetMesh() は IfcComposedMesh ツリーを深く再帰する。
            // GCD ワーカースレッドの既定スタック（512KB）では実ファイルで
            // スタックオーバーフロー（SIGBUS）するため、大スタックの専用スレッドで実行する。
            let thread = Thread {
                // QL 拡張プロセスはバックグラウンドロール（E-coreクランプ）で起動され
                // パースが約4倍遅くなる。beginActivity でクランプを解除して P-core で走らせる。
                let activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "IFC parsing")
                defer { ProcessInfo.processInfo.endActivity(activity) }

                Self.gate.wait()
                defer { Self.gate.signal() }
                // 待っている間にプレビューが閉じられていたら何もしない
                if cancelled.isCancelled {
                    continuation.finish()
                    return
                }
                let started = ContinuousClock.now
                // full: 全体を色単位に統合し続ける（上限管理と最終メッシュの正）
                // progress: 進捗表示用。flush ごとに drain して空になる
                let fullBatcher = MeshBatcher(triangleLimit: triangleLimit)
                let progressBatcher = MeshBatcher(triangleLimit: triangleLimit)
                var lastFlush = started
                var flushedOnce = false
                var trisSinceFlush = 0
                // QL 拡張プロセスはメモリ上限（実測 ~1.2GB）があり、超えると圧縮スワップで
                // 数倍遅くなる。appex 内では 900MB で打ち切り（省略分は ⚠ 表示される）。
                // 単体アプリ・CLI は無制限。
                let isAppex = Bundle.main.bundleURL.pathExtension == "appex"
                let memoryCapMB: UInt = isAppex ? 900 : 0
                do {
                    let info = try WebIFCBridge().streamMeshes(fromFileAtPath: url.path,
                                                               memoryCapMB: memoryCapMB) { chunk in
                        // キャンセル後はメッシュ統合・送出をスキップ（パース自体は中断不可のため最速で流し切る）
                        if cancelled.isCancelled { return }
                        // 上限判定は full 側に一元化（false ならスキップ済み要素として計上済み）
                        guard fullBatcher.add(chunk) else { return }
                        progressBatcher.add(chunk)
                        trisSinceFlush += Int(chunk.indexCount) / 3

                        let now = ContinuousClock.now
                        let interval: Duration = flushedOnce ? Self.flushSeconds
                                                             : .milliseconds(Int(flushInterval * 1000))
                        if trisSinceFlush >= Self.flushTriangles || now - lastFlush > interval {
                            let batches = progressBatcher.drain()
                            if !batches.isEmpty {
                                continuation.yield(.batches(batches))
                                flushedOnce = true
                            }
                            trisSinceFlush = 0
                            lastFlush = now
                        }
                    }
                    if cancelled.isCancelled {
                        continuation.finish()
                        return
                    }
                    // 残りは中間 flush せず、完了イベントの consolidated（色単位=最小ドローコール）に載せる
                    let seconds = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
                    let summary = LoadSummary(
                        schema: info.schemaVersion,
                        elementCount: Int(info.elementCount),
                        triangleCount: fullBatcher.totalTriangles,
                        skippedElements: fullBatcher.skippedElements + Int(info.omittedElements),
                        seconds: seconds,
                        bounds: fullBatcher.bounds)
                    continuation.yield(.finished(summary, consolidated: fullBatcher.drain()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.stackSize = 32 * 1024 * 1024 // 32MB（仮想確保のみ、実使用ページ分だけ消費）
            thread.qualityOfService = .userInitiated
            thread.name = "jp.trapple.IFCQuickLook.ModelLoader"
            thread.start()
        }
    }
}
