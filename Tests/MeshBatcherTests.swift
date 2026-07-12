import XCTest
import simd

/// テスト用チャンク生成: 1 三角形 (0,0,0)(1,0,0)(0,1,0)、法線+Z
func makeChunk(color: SIMD4<Float>, offset: Float = 0) -> IFCMeshChunk {
    let v: [Float] = [
        0 + offset, 0, 0, 0, 0, 1,
        1 + offset, 0, 0, 0, 0, 1,
        0 + offset, 1, 0, 0, 0, 1,
    ]
    let i: [UInt32] = [0, 1, 2]
    return IFCMeshChunk(
        vertexData: v.withUnsafeBufferPointer { Data(buffer: $0) },
        indexData: i.withUnsafeBufferPointer { Data(buffer: $0) },
        color: color)
}

final class MeshBatcherTests: XCTestCase {

    /// 同色チャンクは 1 バッチに統合され、インデックスがオフセットされる
    func testMergesSameColor() {
        let batcher = MeshBatcher(triangleLimit: 100)
        let red = SIMD4<Float>(1, 0, 0, 1)
        XCTAssertTrue(batcher.add(makeChunk(color: red)))
        XCTAssertTrue(batcher.add(makeChunk(color: red, offset: 5)))
        let batches = batcher.drain()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].vertices.count, 6 * 6)      // 6 頂点
        XCTAssertEqual(batches[0].indices, [0, 1, 2, 3, 4, 5]) // 2個目は +3 オフセット
        XCTAssertEqual(batcher.totalTriangles, 2)
    }

    /// 異なる色は別バッチ
    func testSplitsByColor() {
        let batcher = MeshBatcher(triangleLimit: 100)
        batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1)))
        batcher.add(makeChunk(color: SIMD4<Float>(0, 1, 0, 1)))
        XCTAssertEqual(batcher.drain().count, 2)
    }

    /// 三角形上限を超えるチャンクはスキップされ、skippedElements が増える（silent にしない）
    func testTriangleLimitSkips() {
        let batcher = MeshBatcher(triangleLimit: 1)
        XCTAssertTrue(batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1))))
        XCTAssertFalse(batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1))))
        XCTAssertEqual(batcher.skippedElements, 1)
        XCTAssertEqual(batcher.totalTriangles, 1)
    }

    /// AABB は drain を跨いで累積する
    func testBoundsAccumulateAcrossDrains() throws {
        let batcher = MeshBatcher(triangleLimit: 100)
        batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1)))
        _ = batcher.drain()
        batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1), offset: 9))
        _ = batcher.drain()
        let b = try XCTUnwrap(batcher.bounds)
        XCTAssertEqual(b.min, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(b.max, SIMD3<Float>(10, 1, 0))
    }
}
