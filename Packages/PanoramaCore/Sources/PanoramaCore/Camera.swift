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

/// A camera with intrinsics, a camera-to-world rotation and (optionally) its position
/// relative to the panorama centre plus a depth map for parallax compensation.
public struct PanoCamera: Sendable {
    public var intrinsics: Intrinsics
    /// Camera-to-world rotation (world: +y up, gravity aligned).
    public var rotation: Mat3
    /// Camera position minus panorama centre, in world coordinates (metres).
    public var offset: Vec3
    /// Scene depth for this photo (z-depth in metres), e.g. from the LiDAR scanner.
    public var depth: DepthMap?

    public init(intrinsics: Intrinsics, rotation: Mat3, offset: Vec3 = .zero, depth: DepthMap? = nil) {
        self.intrinsics = intrinsics
        self.rotation = rotation
        self.offset = offset
        self.depth = depth
    }

    /// World-space viewing direction.
    public var axis: Vec3 { rotation * Vec3(0, 0, -1) }

    public var projector: Projector { Projector(self) }
}

/// Low-resolution depth map aligned with a photo (covers the whole image).
/// Values are z-depth in metres; invalid samples are filled from their neighbours.
public struct DepthMap: Sendable {
    public let width: Int
    public let height: Int
    public private(set) var data: [Float]
    public static let far: Float = 50

    /// - Parameter depth: row-major metres; values <= 0 or non-finite are treated as missing.
    public init(width: Int, height: Int, depth: [Float]) {
        precondition(depth.count == width * height)
        self.width = width
        self.height = height
        var img = FloatImage(width: width, height: height, channels: 1)
        var valid = [Bool](repeating: false, count: depth.count)
        for i in 0..<depth.count {
            let d = depth[i]
            if d.isFinite && d > 0.05 {
                img.data[i] = min(Self.far, max(0.15, d))
                valid[i] = true
            }
        }
        if valid.contains(true) {
            Pyramid.pushPullFill(&img, valid: valid)
        } else {
            img.data = [Float](repeating: Self.far, count: depth.count)
        }
        data = img.data
    }

    /// Bilinear sample at normalized image coordinates (0...1 across the photo).
    @inlinable public func sample(nu: Double, nv: Double) -> Double {
        let x = max(0, min(Double(width - 1), nu * Double(width) - 0.5))
        let y = max(0, min(Double(height - 1), nv * Double(height) - 0.5))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        let a = Double(data[y0 * width + x0]), b = Double(data[y0 * width + x1])
        let c = Double(data[y1 * width + x0]), d = Double(data[y1 * width + x1])
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }
}

/// Maps between photo pixels and world directions *as seen from the panorama centre*.
///
/// Without depth (or without camera translation) this is the classic rotation-only
/// model. With depth, a pixel is lifted to its 3D point and re-projected from the
/// panorama centre, which removes the parallax caused by the phone moving between
/// shots (the main cause of ghosting on nearby objects).
public struct Projector: Sendable {
    public let K: Intrinsics
    public let R: Mat3
    public let Rt: Mat3
    public let offset: Vec3
    public let depth: DepthMap?
    public let parallax: Bool

    public init(_ cam: PanoCamera) {
        K = cam.intrinsics
        R = cam.rotation
        Rt = cam.rotation.transposed
        offset = cam.offset
        depth = cam.depth
        parallax = cam.depth != nil && cam.offset.length > 1e-4
    }

    /// z-depth at a pixel (infinite if no depth map).
    @inlinable public func depthAt(u: Double, v: Double) -> Double? {
        guard let depth else { return nil }
        return depth.sample(nu: (u + 0.5) / Double(K.width), nv: (v + 0.5) / Double(K.height))
    }

    /// 3D point (camera frame) for a pixel, if depth is known.
    @inlinable public func cameraPoint(u: Double, v: Double) -> Vec3? {
        guard let z = depthAt(u: u, v: v) else { return nil }
        return K.ray(u: u, v: v) * z
    }

    /// Direction from the panorama centre (unnormalized) of the scene point at pixel (u, v).
    @inlinable public func unproject(u: Double, v: Double) -> Vec3 {
        if parallax, let z = depthAt(u: u, v: v) {
            return R * (K.ray(u: u, v: v) * z) + offset
        }
        return R * K.ray(u: u, v: v)
    }

    /// Pixel showing the scene point that lies in world direction `d` (unit) from the
    /// panorama centre. Solved by fixed-point iteration on the depth map.
    @inlinable public func project(_ d: Vec3) -> (u: Double, v: Double)? {
        guard var p = K.project(Rt * d) else { return nil }
        if !parallax { return p }
        for _ in 0..<6 {
            let z = depthAt(u: p.u, v: p.v)!
            let X = R * (K.ray(u: p.u, v: p.v) * z) + offset
            let s = X.length
            guard let q = K.project(Rt * (d * s - offset)) else { return nil }
            let delta = abs(q.u - p.u) + abs(q.v - p.v)
            p = q
            if delta < 0.05 { break }
        }
        return p
    }

    @inlinable public func inside(_ p: (u: Double, v: Double), margin: Double = 0) -> Bool {
        p.u >= margin && p.v >= margin && p.u <= Double(K.width - 1) - margin && p.v <= Double(K.height - 1) - margin
    }
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
