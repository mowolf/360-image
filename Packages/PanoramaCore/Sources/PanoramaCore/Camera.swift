import Foundation

/// Pinhole intrinsics in pixels, for an image of `width` x `height`.
///
/// Camera coordinate convention (identical to ARKit): +x right, +y up, -z forward
/// (viewing direction). Pixel coordinates have their origin at the top-left pixel
/// center and +v pointing down.
public struct Intrinsics: Equatable, Sendable, Codable {
    public var fx: Double, fy: Double, cx: Double, cy: Double
    public var width: Int, height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.width = width; self.height = height
    }

    /// Intrinsics after resizing the image to `newWidth` x `newHeight`.
    public func scaled(toWidth newWidth: Int, height newHeight: Int) -> Intrinsics {
        let sx = Double(newWidth) / Double(width), sy = Double(newHeight) / Double(height)
        return Intrinsics(fx: fx * sx, fy: fy * sy,
                          cx: (cx + 0.5) * sx - 0.5, cy: (cy + 0.5) * sy - 0.5,
                          width: newWidth, height: newHeight)
    }

    public var horizontalFOV: Double { 2 * atan(Double(width) / (2 * fx)) }
    public var verticalFOV: Double { 2 * atan(Double(height) / (2 * fy)) }

    /// Unnormalized camera-space ray through pixel (u, v).
    @inlinable public func ray(u: Double, v: Double) -> Vec3 {
        Vec3((u - cx) / fx, -(v - cy) / fy, -1)
    }

    /// Projects a camera-space direction to pixel coordinates; nil if behind the camera.
    @inlinable public func project(_ c: Vec3) -> (u: Double, v: Double)? {
        if c.z > -1e-6 { return nil }
        let iz = -1 / c.z
        return (cx + fx * c.x * iz, cy - fy * c.y * iz)
    }
}

/// A camera with intrinsics and a camera-to-world rotation.
public struct PanoCamera: Sendable {
    public var intrinsics: Intrinsics
    /// Camera-to-world rotation (world: +y up, gravity aligned).
    public var rotation: Mat3

    public init(intrinsics: Intrinsics, rotation: Mat3) {
        self.intrinsics = intrinsics
        self.rotation = rotation
    }

    /// World-space viewing direction.
    public var axis: Vec3 { rotation * Vec3(0, 0, -1) }
}

/// Equirectangular mapping. Longitude 0 looks down -z, +longitude turns right (+x),
/// latitude +90 degrees is straight up (+y).
public enum Equirect {
    @inlinable public static func direction(lon: Double, lat: Double) -> Vec3 {
        let cl = cos(lat)
        return Vec3(cl * sin(lon), sin(lat), -cl * cos(lon))
    }

    @inlinable public static func lonLat(_ d: Vec3) -> (lon: Double, lat: Double) {
        let n = d.length
        return (atan2(d.x, -d.z), asin(max(-1, min(1, d.y / n))))
    }

    @inlinable public static func direction(x: Double, y: Double, width: Int, height: Int) -> Vec3 {
        let lon = (x + 0.5) / Double(width) * 2 * .pi - .pi
        let lat = .pi / 2 - (y + 0.5) / Double(height) * .pi
        return direction(lon: lon, lat: lat)
    }
}
