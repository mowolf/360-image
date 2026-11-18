import CoreGraphics
import PanoramaCore
import RealityKit
import UIKit

/// Builds a curved, textured patch for a captured photo: the photo is projected onto a
/// sphere around the capture position, exactly where it was taken. Each new photo uses a
/// slightly smaller radius so it draws in front of earlier ones without z-fighting, which
/// gives the "sphere filling up" look of classic photo-sphere capture apps.
enum ShotPreviewMesh {
    @MainActor
    static func makeAnchor(shot: CapturedShot, preview: CGImage, cameraPosition: SIMD3<Float>, radius: Float) async -> AnchorEntity? {
        let K = shot.intrinsics
        let R = shot.rotation
        let cols = 16, rows = 12
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity((cols + 1) * (rows + 1))
        for r in 0...rows {
            for c in 0...cols {
                let u = Double(c) / Double(cols), v = Double(r) / Double(rows)
                let ray = K.ray(u: u * Double(K.width - 1), v: v * Double(K.height - 1)).normalized
                let world = (R * ray).float3 * radius + cameraPosition
                positions.append(world)
                uvs.append(SIMD2<Float>(Float(u), Float(1 - v)))
            }
        }
        var indices: [UInt32] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let i00 = UInt32(r * (cols + 1) + c), i01 = i00 + 1
                let i10 = i00 + UInt32(cols + 1), i11 = i10 + 1
                // Counter-clockwise as seen from the sphere centre.
                indices += [i00, i10, i01, i01, i10, i11]
            }
        }
        var desc = MeshDescriptor(name: "shot")
        desc.positions = MeshBuffers.Positions(positions)
        desc.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        desc.primitives = .triangles(indices)

        do {
            let mesh = try MeshResource.generate(from: [desc])
            let texture = try await TextureResource(image: preview, options: .init(semantic: .color))
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            material.faceCulling = .none
            let model = ModelEntity(mesh: mesh, materials: [material])
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(model)
            return anchor
        } catch {
            return nil
        }
    }
}
