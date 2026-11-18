import Foundation

/// A metric depth measurement for one photo: pixel (in the photo's intrinsics) and z-depth.
public struct DepthSample: Sendable {
    public var u: Double
    public var v: Double
    public var z: Double
    public var weight: Double
    public init(u: Double, v: Double, z: Double, weight: Double = 1) {
        self.u = u; self.v = v; self.z = z; self.weight = weight
    }
}

/// Relative (affine-invariant) inverse depth from a monocular network such as
/// Depth Anything V2: larger values are closer, unknown scale and shift.
public struct RelativeDepth: Sendable {
    public let width: Int
    public let height: Int
    public let values: [Float]
    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width; self.height = height; self.values = values
    }

    @inlinable public func sample(nu: Double, nv: Double) -> Double {
        let x = max(0, min(Double(width - 1), nu * Double(width) - 0.5))
        let y = max(0, min(Double(height - 1), nv * Double(height) - 0.5))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        let a = Double(values[y0 * width + x0]), b = Double(values[y0 * width + x1])
        let c = Double(values[y1 * width + x0]), d = Double(values[y1 * width + x1])
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }
}

/// Builds a metric depth map for a photo from whatever is available:
/// - LiDAR depth (Pro iPhones): used directly where valid.
/// - Sparse metric samples: ARKit's tracked 3D feature points and points triangulated
///   from feature matches between photos taken from slightly different positions.
/// - Monocular relative depth: dense and detailed but with unknown scale/shift; it is
///   fitted to the sparse samples (1/z = s·d + t, robust RANSAC + reweighted least squares).
public enum DepthFusion {
    public static let outputWidth = 96
    public static let outputHeight = 72

    /// Robust fit of 1/z = s * d + t. Returns nil if the samples do not support a fit.
    public static func fitInverseAffine(relative: RelativeDepth, samples: [DepthSample],
                                        imageWidth: Int, imageHeight: Int) -> (s: Double, t: Double)? {
        let pts: [(d: Double, inv: Double, w: Double)] = samples.compactMap { smp in
            guard smp.z > 0.1, smp.z < 80 else { return nil }
            let d = relative.sample(nu: (smp.u + 0.5) / Double(imageWidth), nv: (smp.v + 0.5) / Double(imageHeight))
            return (d, 1 / smp.z, smp.weight)
        }
        if pts.count < 6 { return nil }
        let dRange = (pts.map(\.d).max() ?? 0) - (pts.map(\.d).min() ?? 0)
        if dRange <= 1e-9 { return nil }

        // Residual in inverse depth, relative to the sample's inverse depth (≈ relative depth error).
        func residual(_ p: (d: Double, inv: Double, w: Double), _ s: Double, _ t: Double) -> Double {
            abs(s * p.d + t - p.inv) / max(p.inv, 0.02)
        }
        // Deterministic 2-point RANSAC.
        var best: (Double, Double, Double) = (0, 0, -1)
        let n = pts.count
        let stride = max(1, n * (n - 1) / 2 / 2000)
        var counter = 0
        for a in 0..<n {
            for b in (a + 1)..<n {
                counter += 1
                if counter % stride != 0 { continue }
                let dd = pts[b].d - pts[a].d
                if abs(dd) < dRange * 0.05 { continue }
                let s = (pts[b].inv - pts[a].inv) / dd
                if s <= 0 { continue }
                let t = pts[a].inv - s * pts[a].d
                var score = 0.0
                for p in pts where residual(p, s, t) < 0.15 { score += p.w }
                if score > best.2 { best = (s, t, score) }
            }
        }
        if best.2 <= 0 { return nil }
        var (s, t) = (best.0, best.1)
        // IRLS refinement with a Cauchy-like weight.
        for _ in 0..<8 {
            var sww = 0.0, swd = 0.0, swdd = 0.0, swy = 0.0, swdy = 0.0
            for p in pts {
                let r = residual(p, s, t)
                let w = p.w / (1 + (r / 0.1) * (r / 0.1)) / max(p.inv, 0.02) // relative error weighting
                sww += w; swd += w * p.d; swdd += w * p.d * p.d
                swy += w * p.inv; swdy += w * p.d * p.inv
            }
            let det = sww * swdd - swd * swd
            if abs(det) < 1e-12 { break }
            let ns = (sww * swdy - swd * swy) / det
            let nt = (swy - ns * swd) / sww
            if ns <= 0 { break }
            s = ns; t = nt
        }
        let inliers = pts.filter { residual($0, s, t) < 0.2 }.count
        if inliers < max(5, pts.count / 4) { return nil }
        return (s, t)
    }

    /// Fused metric depth map, or nil if there is nothing to build it from.
    public static func fuse(imageWidth: Int, imageHeight: Int, lidar: DepthMap?, relative: RelativeDepth?,
                            samples: [DepthSample]) -> DepthMap? {
        let W = outputWidth, H = outputHeight
        var out = [Float](repeating: 0, count: W * H)

        // Samples restricted to the visible front-most surface: keep the nearest per cell.
        let cleaned = zBufferFilter(samples, imageWidth: imageWidth, imageHeight: imageHeight)

        // LiDAR samples also constrain the monocular fit (they are the best metric data).
        var fitSamples = cleaned
        if let lidar {
            for gy in Swift.stride(from: 0, to: H, by: 3) {
                for gx in Swift.stride(from: 0, to: W, by: 3) {
                    let nu = (Double(gx) + 0.5) / Double(W), nv = (Double(gy) + 0.5) / Double(H)
                    let z = lidar.sample(nu: nu, nv: nv)
                    if z < 4.5 {
                        fitSamples.append(DepthSample(u: nu * Double(imageWidth) - 0.5, v: nv * Double(imageHeight) - 0.5,
                                                      z: z, weight: 0.5))
                    }
                }
            }
        }

        var monoFit: (s: Double, t: Double)?
        if let relative {
            monoFit = fitInverseAffine(relative: relative, samples: fitSamples, imageWidth: imageWidth, imageHeight: imageHeight)
        }

        for gy in 0..<H {
            for gx in 0..<W {
                let nu = (Double(gx) + 0.5) / Double(W), nv = (Double(gy) + 0.5) / Double(H)
                var z: Double = 0
                if let lidar {
                    let lz = lidar.sample(nu: nu, nv: nv)
                    if lz < 4.5 { z = lz }
                }
                if z == 0, let relative, let fit = monoFit {
                    let inv = fit.s * relative.sample(nu: nu, nv: nv) + fit.t
                    z = inv > 1 / Double(DepthMap.far) ? 1 / inv : Double(DepthMap.far)
                }
                if z == 0, let lidar { z = lidar.sample(nu: nu, nv: nv) }
                out[gy * W + gx] = Float(z)
            }
        }
        if lidar == nil && monoFit == nil {
            // Sparse samples only: splat them and let DepthMap's push-pull interpolate.
            if cleaned.count < 12 { return nil }
            for s in cleaned {
                let gx = Int((s.u + 0.5) / Double(imageWidth) * Double(W))
                let gy = Int((s.v + 0.5) / Double(imageHeight) * Double(H))
                if gx >= 0, gy >= 0, gx < W, gy < H { out[gy * W + gx] = Float(s.z) }
            }
        }
        return DepthMap(width: W, height: H, depth: out)
    }

    /// Keeps only samples on the front-most surface of each coarse cell: points that are
    /// occluded from this viewpoint (seen by ARKit from elsewhere) would otherwise pull
    /// near objects far away.
    static func zBufferFilter(_ samples: [DepthSample], imageWidth: Int, imageHeight: Int) -> [DepthSample] {
        let cw = 24, ch = 18
        var nearest = [Double](repeating: .infinity, count: cw * ch)
        func cell(_ s: DepthSample) -> Int? {
            let x = Int((s.u + 0.5) / Double(imageWidth) * Double(cw))
            let y = Int((s.v + 0.5) / Double(imageHeight) * Double(ch))
            return (x >= 0 && y >= 0 && x < cw && y < ch) ? y * cw + x : nil
        }
        for s in samples { if let c = cell(s) { nearest[c] = min(nearest[c], s.z) } }
        return samples.filter { s in
            guard let c = cell(s) else { return false }
            return s.z <= nearest[c] * 1.25
        }
    }

    /// Triangulates the closest point between two rays (origins o, unit directions d).
    /// Returns nil for near-parallel rays or points behind either camera.
    public static func triangulate(o1: Vec3, d1: Vec3, o2: Vec3, d2: Vec3, minAngle: Double = 0.4.radians) -> Vec3? {
        if d1.angle(to: d2) < minAngle { return nil }
        let w0 = o1 - o2
        let a = d1.dot(d1), b = d1.dot(d2), c = d2.dot(d2), d = d1.dot(w0), e = d2.dot(w0)
        let den = a * c - b * b
        if abs(den) < 1e-12 { return nil }
        let s = (b * e - c * d) / den
        let t = (a * e - b * d) / den
        if s <= 0.05 || t <= 0.05 { return nil }
        let p1 = o1 + d1 * s, p2 = o2 + d2 * t
        // Reject if the rays do not come close (relative to the distance).
        if (p1 - p2).length > 0.05 * max(s, t) { return nil }
        return (p1 + p2) * 0.5
    }
}
