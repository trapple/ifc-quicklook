import Foundation
import simd

/// 軸並行バウンディングボックス
struct AABB {
    var min: SIMD3<Float>
    var max: SIMD3<Float>
    mutating func union(_ p: SIMD3<Float>) {
        min = simd.min(min, p)
        max = simd.max(max, p)
    }
    var center: SIMD3<Float> { (min + max) * 0.5 }
    var size: SIMD3<Float> { max - min }
}

/// 色ごとに統合されたメッシュ（RKSceneBuilder が MeshResource 化する単位）
struct MaterialBatch {
    let color: SIMD4<Float>
    var vertices: [Float]    // position+normal 6 float インターリーブ
    var indices: [UInt32]
    var vertexCount: Int { vertices.count / 6 }
}

/// IFCMeshChunk を色別に統合し、三角形上限と AABB を管理する。
/// スレッド非対応（呼び出し側が単一スレッドで使う）。
final class MeshBatcher {
    let triangleLimit: Int
    private var open: [UInt32: MaterialBatch] = [:] // RGBA8 量子化キー
    private(set) var totalTriangles = 0
    private(set) var skippedElements = 0
    private(set) var bounds: AABB?

    init(triangleLimit: Int = 20_000_000) {
        self.triangleLimit = triangleLimit
    }

    /// 追加できたら true。上限超過はスキップして false（skippedElements に計上）。
    @discardableResult
    func add(_ chunk: IFCMeshChunk) -> Bool {
        let tris = Int(chunk.indexCount) / 3
        guard totalTriangles + tris <= triangleLimit else {
            skippedElements += 1
            return false
        }
        let key = Self.quantize(chunk.color)
        var batch = open[key] ?? MaterialBatch(color: chunk.color, vertices: [], indices: [])
        let base = UInt32(batch.vertexCount)

        chunk.vertexData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            batch.vertices.append(contentsOf: floats)
            // AABB 更新（position のみ）
            var b = bounds
            var v = 0
            while v < floats.count {
                let p = SIMD3<Float>(floats[v], floats[v + 1], floats[v + 2])
                if b == nil { b = AABB(min: p, max: p) } else { b!.union(p) }
                v += 6
            }
            bounds = b
        }
        chunk.indexData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let idx = raw.bindMemory(to: UInt32.self)
            batch.indices.reserveCapacity(batch.indices.count + idx.count)
            for i in idx { batch.indices.append(i + base) }
        }
        open[key] = batch
        totalTriangles += tris
        return true
    }

    /// 溜まったバッチを取り出して内部状態をリセット（プログレッシブ表示用）。
    /// bounds / totalTriangles / skippedElements は累積のまま。
    func drain() -> [MaterialBatch] {
        let result = Array(open.values)
        open.removeAll(keepingCapacity: true)
        return result
    }

    /// RGBA を 8bit 量子化してキー化（微小な色差は同一マテリアル扱い）
    private static func quantize(_ c: SIMD4<Float>) -> UInt32 {
        let r = UInt32(simd_clamp(c.x, 0, 1) * 255)
        let g = UInt32(simd_clamp(c.y, 0, 1) * 255)
        let b = UInt32(simd_clamp(c.z, 0, 1) * 255)
        let a = UInt32(simd_clamp(c.w, 0, 1) * 255)
        return (r << 24) | (g << 16) | (b << 8) | a
    }
}
