import XCTest

/// テストバンドル同梱 fixture の URL を返す
func fixtureURL(_ name: String, ext: String = "ifc") -> URL {
    Bundle(for: WebIFCBridgeTests.self).url(forResource: name, withExtension: ext)!
}

final class WebIFCBridgeTests: XCTestCase {

    /// 最小fixture: 壁1枚がメッシュとしてストリームされること
    func testMinimalWallStreamsTriangles() throws {
        var chunks: [IFCMeshChunk] = []
        let bridge = WebIFCBridge()
        let info = try bridge.streamMeshes(fromFileAtPath: fixtureURL("minimal_wall").path, memoryCapMB: 0, deadlineSeconds: 0) { chunks.append($0) }
        XCTAssertEqual(info.schemaVersion, "IFC4")
        XCTAssertEqual(info.elementCount, 1)
        let triangles = chunks.reduce(0) { $0 + Int($1.indexCount) / 3 }
        XCTAssertGreaterThanOrEqual(triangles, 12)
        // 頂点は 6 float インターリーブ
        XCTAssertEqual(chunks[0].vertexData.count, Int(chunks[0].vertexCount) * 6 * MemoryLayout<Float>.size)
    }

    /// 壊れたファイル → parseFailed で throw（Fail Fast）
    func testBrokenFileThrows() {
        let bridge = WebIFCBridge()
        XCTAssertThrowsError(try bridge.streamMeshes(fromFileAtPath: fixtureURL("broken").path, memoryCapMB: 0, deadlineSeconds: 0) { _ in }) { error in
            XCTAssertEqual((error as NSError).domain, IFCBridgeErrorDomain)
        }
    }

    /// 存在しないパス → cantOpen
    func testMissingFileThrows() {
        let bridge = WebIFCBridge()
        XCTAssertThrowsError(try bridge.streamMeshes(fromFileAtPath: "/nonexistent/x.ifc", memoryCapMB: 0, deadlineSeconds: 0) { _ in })
    }

    /// 非対応スキーマ → unsupportedSchema エラーで、メッセージにスキーマ名が入る
    func testUnsupportedSchemaThrows() {
        let bridge = WebIFCBridge()
        XCTAssertThrowsError(try bridge.streamMeshes(fromFileAtPath: fixtureURL("unsupported_schema").path, memoryCapMB: 0, deadlineSeconds: 0) { _ in }) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, IFCBridgeErrorDomain)
            XCTAssertEqual(ns.code, IFCBridgeError.unsupportedSchema.rawValue)
            XCTAssertTrue(ns.localizedDescription.contains("IFC2X2"))
        }
    }
}
