// web-ifc ネイティブ API の疎通確認。fixture を読み三角形数を出力する。
// ここで確定した API 呼び出しパターンが WebIFCBridge.mm の正となる。
//
// upstream 0.77 で確認済みの API:
// - IfcLoader(tapeSize, memoryLimit, lineWriterBuffer, schemaManager)
// - LoadFile(std::function<uint32_t(char*, size_t, size_t)>)
// - IfcGeometryProcessor(loader, schemas, circleSegments, coordinateToOrigin, 許容誤差×7)
// - IfcPlacedGeometry: color(dvec4) / transformation(dmat4) / geometryExpressID
// - IfcGeometry::GetVertexData() は float 配列（WebGL用に変換済み）、6 float/頂点
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <algorithm>
#include "web-ifc/parsing/IfcLoader.h"
#include "web-ifc/schema/IfcSchemaManager.h"
#include "web-ifc/geometry/IfcGeometryProcessor.h"

int main(int argc, char **argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s file.ifc\n", argv[0]); return 2; }
    std::ifstream ifs(argv[1], std::ios::binary);
    std::stringstream ss; ss << ifs.rdbuf();
    const std::string content = ss.str();

    webifc::schema::IfcSchemaManager schemas;
    // 既定値は ModelManager.h の LoaderSettings に準拠
    webifc::parsing::IfcLoader loader(67108864, 2147483648u, 10000, schemas);
    loader.LoadFile([&](char *dest, size_t sourceOffset, size_t destSize) -> uint32_t {
        if (sourceOffset >= content.size()) return 0;
        size_t n = std::min(destSize, content.size() - sourceOffset);
        std::memcpy(dest, content.data() + sourceOffset, n);
        return static_cast<uint32_t>(n);
    });

    // circleSegments=12, coordinateToOrigin=true（巨大座標を原点に寄せ float 精度を守る）
    // 許容誤差は ModelManager.h の既定値
    webifc::geometry::IfcGeometryProcessor processor(
        loader, schemas, 12, true,
        1.0E-04, 1.0E-04, 1.0E-04, 1.0E-10, 1.0E-04, 1, 150);

    size_t triangles = 0, elements = 0;
    for (auto type : schemas.GetIfcElementList()) {
        for (auto eid : loader.GetExpressIDsWithType(type)) {
            auto flat = processor.GetFlatMesh(eid);
            bool hasGeom = false;
            for (auto &pg : flat.geometries) {
                auto &geom = processor.GetGeometry(pg.geometryExpressID);
                triangles += geom.GetIndexDataSize() / 3;
                hasGeom = hasGeom || geom.GetIndexDataSize() > 0;
            }
            if (hasGeom) elements++;
        }
    }
    std::printf("elements=%zu triangles=%zu\n", elements, triangles);
    return triangles > 0 ? 0 : 1;
}
