import Foundation
import RealityKit
import simd

/// 球面座標オービットカメラ。yaw/pitch/distance/target を保持し Entity に適用する。
final class OrbitCameraController {
    var yaw: Float = .pi / 4          // 斜め 45°
    var pitch: Float = .pi / 6        // 見下ろし 30°
    var distance: Float = 10
    var target = SIMD3<Float>(0, 0, 0)

    private var minDistance: Float = 0.1
    private var maxDistance: Float = 10_000

    /// bbox 全体が収まるよう注視点と距離を設定（初期視点: 斜め上 45° の等角風）
    func frame(_ bbox: AABB) {
        target = bbox.center
        let radius = simd_length(bbox.size) * 0.5
        distance = max(radius * 2.2, 0.5)
        minDistance = max(radius * 0.01, 0.01)
        maxDistance = max(radius * 20, 10)
    }

    func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = simd_clamp(pitch + dy * 0.008, -.pi / 2 + 0.05, .pi / 2 - 0.05)
    }

    func zoom(delta: Float) {
        distance = simd_clamp(distance * exp(-delta * 0.1), minDistance, maxDistance)
    }

    func pan(dx: Float, dy: Float) {
        let rot = rotation
        let right = rot.act(SIMD3<Float>(1, 0, 0))
        let up = rot.act(SIMD3<Float>(0, 1, 0))
        let k = distance * 0.0015
        target += right * (-dx * k) + up * (dy * k)
    }

    private var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
    }

    /// カメラエンティティへ適用。カメラの -Z が target を向く。
    func apply(to entity: Entity) {
        let rot = rotation
        let position = target + rot.act(SIMD3<Float>(0, 0, distance))
        entity.transform = Transform(scale: .one, rotation: rot, translation: position)
    }
}
