import Foundation

enum LoadEvent {
    case batches([MaterialBatch])   // 途中経過（プログレッシブ描画用）
    case finished(LoadSummary)      // 完了サマリ
}

/// バックグラウンドでパースし、一定間隔でバッチを flush する。
/// 「最初のバッチが揃った時点で描画開始」を実現する心臓部。
final class ModelLoader {
    func events(for url: URL,
                triangleLimit: Int = 20_000_000,
                flushInterval: Double = 0.25) -> AsyncThrowingStream<LoadEvent, Error> {
        AsyncThrowingStream { continuation in
            // web-ifc の GetMesh() は IfcComposedMesh ツリーを深く再帰する。
            // GCD ワーカースレッドの既定スタック（512KB）では実ファイルで
            // スタックオーバーフロー（SIGBUS）するため、大スタックの専用スレッドで実行する。
            let thread = Thread {
                let started = ContinuousClock.now
                let batcher = MeshBatcher(triangleLimit: triangleLimit)
                var lastFlush = started
                do {
                    let info = try WebIFCBridge().streamMeshes(fromFileAtPath: url.path) { chunk in
                        batcher.add(chunk)
                        let now = ContinuousClock.now
                        if now - lastFlush > .milliseconds(Int(flushInterval * 1000)) {
                            let batches = batcher.drain()
                            if !batches.isEmpty { continuation.yield(.batches(batches)) }
                            lastFlush = now
                        }
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
