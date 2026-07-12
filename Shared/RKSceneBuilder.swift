import Foundation
import RealityKit
import AppKit

/// MaterialBatch → メッシュ記述子/マテリアル/エンティティ変換。
/// 重い CPU 処理（頂点配列の組み立て）は makeDescriptors としてバックグラウンドで実行できるよう分離し、
/// シーングラフ操作（ModelEntity 追加）だけをメインスレッドで行う。
enum RKSceneBuilder {

    /// 記述子と色のペア（MeshResource 化前の中間表現）
    struct MeshItem {
        let descriptor: MeshDescriptor
        let color: SIMD4<Float>
    }

    /// 頂点配列 → MeshDescriptor（純CPU処理。バックグラウンドスレッドで呼んでよい）
    static func makeDescriptors(_ batches: [MaterialBatch]) -> [MeshItem] {
        batches.compactMap { batch in
            guard batch.vertexCount > 0 else { return nil }
            var positions = [SIMD3<Float>](); positions.reserveCapacity(batch.vertexCount)
            var normals = [SIMD3<Float>](); normals.reserveCapacity(batch.vertexCount)
            var v = 0
            while v < batch.vertices.count {
                positions.append(SIMD3(batch.vertices[v], batch.vertices[v+1], batch.vertices[v+2]))
                normals.append(SIMD3(batch.vertices[v+3], batch.vertices[v+4], batch.vertices[v+5]))
                v += 6
            }
            var desc = MeshDescriptor()
            desc.positions = MeshBuffer(positions)
            desc.normals = MeshBuffer(normals)
            desc.primitives = .triangles(batch.indices)
            return MeshItem(descriptor: desc, color: batch.color)
        }
    }

    static func makeMaterial(_ c: SIMD4<Float>) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(red: CGFloat(c.x), green: CGFloat(c.y),
                                                 blue: CGFloat(c.z), alpha: 1.0))
        material.roughness = 0.8
        material.metallic = 0.0
        if c.w < 0.999 {
            // 半透明（ガラス等）: アルファブレンド
            material.blending = .transparent(opacity: .init(floatLiteral: c.w))
        }
        return material
    }

    /// MeshItem → ModelEntity（MeshResource 生成は async 版でメインスレッドをブロックしない）
    @MainActor
    static func makeEntities(items: [MeshItem]) async -> [ModelEntity] {
        var entities: [ModelEntity] = []
        entities.reserveCapacity(items.count)
        for item in items {
            guard let mesh = try? await MeshResource(from: [item.descriptor]) else { continue }
            entities.append(ModelEntity(mesh: mesh, materials: [makeMaterial(item.color)]))
        }
        return entities
    }
}
