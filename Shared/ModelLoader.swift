import Foundation

enum LoadEvent {
    case batches([MaterialBatch])   // 途中経過（プログレッシブ描画用）
    case finished(LoadSummary)      // 完了サマリ
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

/// バックグラウンドでパースし、一定間隔でバッチを flush する。
/// 「最初のバッチが揃った時点で描画開始」を実現する心臓部。
final class ModelLoader {
    /// web-ifc の並走禁止ゲート。
    /// QL は同一プロセスで連続プレビューするため、ファイル切替時に複数のパースが
    /// 並走しうる。web-ifc（fuzzybools 等）はグローバル状態を持ちスレッドセーフでは
    /// ないため、プロセス内で同時に 1 パースに直列化する（データレースで SIGBUS した実績あり）。
    private static let gate = DispatchSemaphore(value: 1)

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
                Self.gate.wait()
                defer { Self.gate.signal() }
                // 待っている間にプレビューが閉じられていたら何もしない
                if cancelled.isCancelled {
                    continuation.finish()
                    return
                }
                let started = ContinuousClock.now
                let batcher = MeshBatcher(triangleLimit: triangleLimit)
                var lastFlush = started
                do {
                    let info = try WebIFCBridge().streamMeshes(fromFileAtPath: url.path) { chunk in
                        // キャンセル後はメッシュ統合・送出をスキップ（パース自体は中断不可のため最速で流し切る）
                        if cancelled.isCancelled { return }
                        batcher.add(chunk)
                        let now = ContinuousClock.now
                        if now - lastFlush > .milliseconds(Int(flushInterval * 1000)) {
                            let batches = batcher.drain()
                            if !batches.isEmpty { continuation.yield(.batches(batches)) }
                            lastFlush = now
                        }
                    }
                    if cancelled.isCancelled {
                        continuation.finish()
                        return
                    }
                    let rest = batcher.drain()
                    if !rest.isEmpty { continuation.yield(.batches(rest)) }
                    let seconds = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
                    continuation.yield(.finished(LoadSummary(
                        schema: info.schemaVersion,
                        elementCount: Int(info.elementCount),
                        triangleCount: batcher.totalTriangles,
                        skippedElements: batcher.skippedElements,
                        seconds: seconds,
                        bounds: batcher.bounds)))
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
