import Foundation
import RealityKit
import AppKit

/// MaterialBatch → ModelEntity 変換（色ごとに 1 エンティティ = 1 ドローコール相当）
enum RKSceneBuilder {
    static func makeEntities(_ batches: [MaterialBatch]) -> [ModelEntity] {
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
            guard let mesh = try? MeshResource.generate(from: [desc]) else { return nil }

            var material = PhysicallyBasedMaterial()
            let c = batch.color
            material.baseColor = .init(tint: NSColor(red: CGFloat(c.x), green: CGFloat(c.y),
                                                     blue: CGFloat(c.z), alpha: 1.0))
            material.roughness = 0.8
            material.metallic = 0.0
            if c.w < 0.999 {
                // 半透明（ガラス等）: アルファブレンド
                material.blending = .transparent(opacity: .init(floatLiteral: c.w))
            }
            return ModelEntity(mesh: mesh, materials: [material])
        }
    }
}
