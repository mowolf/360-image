import Foundation

/// A correspondence between two photos, expressed as unit rays in each camera's frame.
/// For the true rotations: R_i * rayI == R_j * rayJ.
public struct RayMatch: Sendable {
    public var i: Int
    public var j: Int
    public var rayI: Vec3
    public var rayJ: Vec3
}

public struct PairAlignment: Sendable {
    public var i: Int
    public var j: Int
    public var matches: [RayMatch]
    /// Residual rotation found relative to the sensor estimate (radians).
    public var correction: Double
}

/// Sensor-guided pairwise registration.
///
/// Instead of matching scale/rotation-invariant features across the whole image (as
/// Brown & Lowe do when nothing is known about the camera poses), we exploit that the
/// capture UI gives us a good rotation estimate for every photo (ARKit visual-inertial
/// tracking, typically better than one degree). For each overlapping pair we:
///
/// 1. Re-project both photos into a common rectilinear view centred between them,
///    using the sensor rotations, so the overlap is already nearly aligned and free of
///    the perspective distortion between the two views.
/// 2. Estimate the remaining global offset with a coarse-to-fine NCC search.
/// 3. Detect Shi-Tomasi corners on a grid and match them by normalized
///    cross-correlation with sub-pixel refinement (gain/exposure invariant).
/// 4. Robustly fit a 3D rotation to the ray pairs (exhaustive 2-point RANSAC + Gauss-
///    Newton refinement) and iterate once more with the improved alignment.
///
/// The surviving correspondences feed the global rotation bundle adjustment.
public struct PairwiseAligner: Sendable {
    public struct Config: Sendable {
        public var viewFOV: Double = 70.radians
        public var maxSensorErrorDegrees: Double = 8
        public var patchRadius: Int = 5
        public var gridCells: Int = 16
        public var minNCC: Float = 0.82
        public var minInliers: Int = 8
        public var minOverlapFraction: Double = 0.06
        public init() {}
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    /// Pairs of photos whose footprints overlap noticeably according to the sensor poses.
    public func candidatePairs(cameras: [PanoCamera]) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for i in 0..<cameras.count {
            for j in (i + 1)..<cameras.count {
                let a = cameras[i], b = cameras[j]
                let maxAngle = (a.intrinsics.horizontalFOV + a.intrinsics.verticalFOV) * 0.5 * 1.2
                if a.axis.angle(to: b.axis) > maxAngle { continue }
                let f = max(overlapFraction(a, b), overlapFraction(b, a))
                if f >= config.minOverlapFraction { pairs.append((i, j)) }
            }
        }
        return pairs
    }

    func overlapFraction(_ a: PanoCamera, _ b: PanoCamera) -> Double {
        let n = 12
        var inside = 0
        let M = b.rotation.transposed * a.rotation
        for gy in 0..<n {
            for gx in 0..<n {
                let u = (Double(gx) + 0.5) / Double(n) * Double(a.intrinsics.width)
                let v = (Double(gy) + 0.5) / Double(n) * Double(a.intrinsics.height)
                let c = M * a.intrinsics.ray(u: u, v: v)
                if let p = b.intrinsics.project(c),
                   p.u >= 0, p.v >= 0, p.u < Double(b.intrinsics.width), p.v < Double(b.intrinsics.height) {
                    inside += 1
                }
            }
        }
        return Double(inside) / Double(n * n)
    }

    /// Aligns all candidate pairs. `gray` are single-channel images matching `cameras`' intrinsics.
    public func alignAll(gray: [FloatImage], cameras: [PanoCamera],
                         progress: ((Double) -> Void)? = nil) -> [PairAlignment] {
        let pairs = candidatePairs(cameras: cameras)
        var results = [PairAlignment?](repeating: nil, count: pairs.count)
        let lock = NSLock()
        var done = 0
        results.withUnsafeMutableBufferPointer { res in
            DispatchQueue.concurrentPerform(iterations: pairs.count) { k in
                let (i, j) = pairs[k]
                let r = align(i: i, j: j, grayI: gray[i], grayJ: gray[j], camI: cameras[i], camJ: cameras[j])
                res[k] = r
                lock.lock()
                done += 1
                let d = done
                lock.unlock()
                progress?(Double(d) / Double(max(1, pairs.count)))
            }
        }
        return results.compactMap { $0 }
    }

    // MARK: - Single pair

    struct LocalView {
        let size: Int
        let focal: Double
        var center: Double { Double(size - 1) / 2 }
        func ray(_ x: Double, _ y: Double) -> Vec3 {
            Vec3((x - center) / focal, -(y - center) / focal, -1).normalized
        }
        func project(_ r: Vec3) -> (Double, Double)? {
            if r.z > -1e-6 { return nil }
            let iz = -1 / r.z
            return (center + focal * r.x * iz, center - focal * r.y * iz)
        }
    }

    /// Renders `img` (camera with intrinsics K) into the local view; `M` maps local rays to camera rays.
    func render(_ img: FloatImage, K: Intrinsics, M: Mat3, view: LocalView) -> (FloatImage, [Bool]) {
        let s = view.size
        var out = FloatImage(width: s, height: s, channels: 1)
        var mask = [Bool](repeating: false, count: s * s)
        let maxU = Double(img.width) - 1.5, maxV = Double(img.height) - 1.5
        img.data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                mask.withUnsafeMutableBufferPointer { m in
                    DispatchQueue.concurrentPerform(iterations: s) { y in
                        var v: Float = 0
                        for x in 0..<s {
                            let r = Vec3((Double(x) - view.center) / view.focal, -(Double(y) - view.center) / view.focal, -1)
                            let c = M * r
                            guard let p = K.project(c), p.u >= 0.5, p.v >= 0.5, p.u <= maxU, p.v <= maxV else { continue }
                            FloatImage.sampleBilinear(src, width: img.width, height: img.height, channels: 1,
                                                      x: p.u, y: p.v, out: &v)
                            dst[y * s + x] = v
                            m[y * s + x] = true
                        }
                    }
                }
            }
        }
        return (out, mask)
    }

    func align(i: Int, j: Int, grayI: FloatImage, grayJ: FloatImage, camI: PanoCamera, camJ: PanoCamera) -> PairAlignment? {
        // Local view resolution roughly matching the source resolution.
        let srcPxPerRad = camI.intrinsics.fx
        let size = max(256, min(1024, Int(srcPxPerRad * config.viewFOV)))
        let view = LocalView(size: size, focal: Double(size) / 2 / tan(config.viewFOV / 2))
        let Rmid = Mat3.slerp(camI.rotation, camJ.rotation, 0.5)
        let Mi = camI.rotation.transposed * Rmid
        let Mj = camJ.rotation.transposed * Rmid

        let (A, maskA) = render(grayI, K: camI.intrinsics, M: Mi, view: view)

        // Stage 1: coarse global shift.
        var dR = Mat3.identity
        do {
            let (B, maskB) = render(grayJ, K: camJ.intrinsics, M: Mj, view: view)
            let maxShift = config.maxSensorErrorDegrees.radians * view.focal
            guard let t = coarseShift(A, maskA, B, maskB, maxShift: maxShift) else { debug("coarse fail"); return nil }
            debug("coarse \(t)")
            let c = view.center
            let a = view.ray(c, c), b = view.ray(c + t.0, c + t.1)
            let axis = a.cross(b)
            if axis.length > 1e-12 { dR = Mat3.rotation(axis.normalized * a.angle(to: b)) }
        }

        // Stage 2: feature matching + robust rotation, twice.
        var inlierRays: [(Vec3, Vec3)] = []
        let passes: [(search: Int, threshold: Double)] = [(7, 3.0), (3, 1.25)]
        for pass in passes {
            let (B, maskB) = render(grayJ, K: camJ.intrinsics, M: Mj * dR, view: view)
            let matches = matchFeatures(A, maskA, B, maskB, size: size, searchRadius: pass.search)
            debug("matches \(matches.count)")
            if matches.count < config.minInliers { return nil }
            // Rays in the local frame: a (view A), b = dR * ray(q) (view B before correction).
            let pairs = matches.map { (view.ray($0.0, $0.1), dR * view.ray($0.2, $0.3)) }
            guard let (rot, inliers) = robustRotation(pairs, threshold: pass.threshold / view.focal) else { return nil }
            debug("inliers \(inliers.count)")
            if inliers.count < config.minInliers { return nil }
            dR = rot
            inlierRays = inliers.map { pairs[$0] }
        }

        let correction = dR.rotationVector.length
        if correction > config.maxSensorErrorDegrees.radians { return nil }

        let rm = inlierRays.map { (a, b) in
            RayMatch(i: i, j: j, rayI: (Mi * a).normalized, rayJ: (Mj * b).normalized)
        }
        return PairAlignment(i: i, j: j, matches: rm, correction: correction)
    }

    func debug(_ s: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["PANO_DEBUG"] != nil { print("[align] " + s()) }
    }

    // MARK: - Coarse shift

    func coarseShift(_ A: FloatImage, _ maskA: [Bool], _ B: FloatImage, _ maskB: [Bool], maxShift: Double) -> (Double, Double)? {
        // Masks as float channels so they reduce alongside the image.
        func withMask(_ img: FloatImage, _ m: [Bool]) -> FloatImage {
            var o = FloatImage(width: img.width, height: img.height, channels: 2)
            for k in 0..<(img.width * img.height) {
                o.data[2 * k] = img.data[k]
                o.data[2 * k + 1] = m[k] ? 1 : 0
            }
            return o
        }
        let levels = 3
        let pa = Pyramid.gaussian(withMask(A, maskA), levels: levels)
        let pb = Pyramid.gaussian(withMask(B, maskB), levels: levels)
        var best = (0, 0)
        for l in stride(from: levels, through: 0, by: -1) {
            let r = l == levels ? Int(ceil(maxShift / Double(1 << l))) : 2
            let center = l == levels ? (0, 0) : (best.0 * 2, best.1 * 2)
            let step = l == 0 ? 2 : 1 // subsample pixels on the finest level for speed
            var bestScore = -Float.infinity
            var bestShift = center
            for dy in -r...r {
                for dx in -r...r {
                    let s = (center.0 + dx, center.1 + dy)
                    if let score = ncc(pa[l], pb[l], shift: s, step: step), score > bestScore {
                        bestScore = score
                        bestShift = s
                    }
                }
            }
            if bestScore == -Float.infinity { return nil }
            best = bestShift
            if l == 0 && bestScore < 0.3 { return nil }
        }
        return (Double(best.0), Double(best.1))
    }

    /// NCC between a (2-channel: value, mask) and b shifted by s, over jointly valid pixels.
    func ncc(_ a: FloatImage, _ b: FloatImage, shift s: (Int, Int), step: Int) -> Float? {
        let w = a.width, h = a.height
        var n: Float = 0, sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
        a.data.withUnsafeBufferPointer { pa in
            b.data.withUnsafeBufferPointer { pb in
                var y = max(0, -s.1)
                let yEnd = min(h, h - s.1)
                while y < yEnd {
                    var x = max(0, -s.0)
                    let xEnd = min(w, w - s.0)
                    while x < xEnd {
                        let ia = 2 * (y * w + x)
                        let ib = 2 * ((y + s.1) * w + x + s.0)
                        if pa[ia + 1] > 0.99 && pb[ib + 1] > 0.99 {
                            let va = pa[ia], vb = pb[ib]
                            n += 1; sa += va; sb += vb
                            saa += va * va; sbb += vb * vb; sab += va * vb
                        }
                        x += step
                    }
                    y += step
                }
            }
        }
        if n < 50 { return nil }
        let cov = sab - sa * sb / n
        let va = saa - sa * sa / n, vb = sbb - sb * sb / n
        if va <= 1e-8 || vb <= 1e-8 { return nil }
        return cov / (va * vb).squareRoot()
    }

    // MARK: - Features

    /// Returns matches (xA, yA, xB, yB) in local view pixels.
    func matchFeatures(_ A: FloatImage, _ maskA: [Bool], _ B: FloatImage, _ maskB: [Bool],
                       size s: Int, searchRadius sr: Int) -> [(Double, Double, Double, Double)] {
        let pr = config.patchRadius
        let border = pr + sr + 2
        // Valid region for a feature: patch fully inside A and search window fully inside B.
        // Use an integral image of the joint mask to test windows quickly.
        var joint = [Int32](repeating: 0, count: (s + 1) * (s + 1))
        for y in 0..<s {
            var rowSum: Int32 = 0
            for x in 0..<s {
                if maskA[y * s + x] && maskB[y * s + x] { rowSum += 1 }
                joint[(y + 1) * (s + 1) + x + 1] = joint[y * (s + 1) + x + 1] + rowSum
            }
        }
        func windowFull(_ x: Int, _ y: Int, _ r: Int) -> Bool {
            let x0 = x - r, y0 = y - r, x1 = x + r + 1, y1 = y + r + 1
            if x0 < 0 || y0 < 0 || x1 > s || y1 > s { return false }
            let sum = joint[y1 * (s + 1) + x1] - joint[y0 * (s + 1) + x1] - joint[y1 * (s + 1) + x0] + joint[y0 * (s + 1) + x0]
            return Int(sum) == (2 * r + 1) * (2 * r + 1)
        }

        // Shi-Tomasi response on a grid of cells, best corner per cell.
        let cells = config.gridCells
        let cellSize = max(1, (s - 2 * border) / cells)
        var candidates: [(Int, Int, Float)] = []
        A.data.withUnsafeBufferPointer { a in
            for cy in 0..<cells {
                for cx in 0..<cells {
                    var best: (Int, Int, Float) = (0, 0, 0)
                    let y0 = border + cy * cellSize, x0 = border + cx * cellSize
                    var y = y0
                    while y < min(y0 + cellSize, s - border) {
                        var x = x0
                        while x < min(x0 + cellSize, s - border) {
                            if maskA[y * s + x] && windowFull(x, y, pr + sr + 1) {
                                let r = shiTomasi(a, s, x, y)
                                if r > best.2 { best = (x, y, r) }
                            }
                            x += 2
                        }
                        y += 2
                    }
                    if best.2 > 0 { candidates.append(best) }
                }
            }
        }
        guard let maxResp = candidates.map({ $0.2 }).max(), maxResp > 0 else { return [] }
        let minResp = max(1e-5, maxResp * 0.01)

        var out: [(Double, Double, Double, Double)] = []
        A.data.withUnsafeBufferPointer { a in
            B.data.withUnsafeBufferPointer { b in
                for (x, y, r) in candidates where r >= minResp {
                    if let m = matchPatch(a, b, s, x, y, pr, sr) {
                        out.append((Double(x), Double(y), m.0, m.1))
                    }
                }
            }
        }
        return out
    }

    func shiTomasi(_ a: UnsafeBufferPointer<Float>, _ s: Int, _ x: Int, _ y: Int) -> Float {
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
        for dy in -2...2 {
            for dx in -2...2 {
                let i = (y + dy) * s + x + dx
                let gx = (a[i + 1] - a[i - 1]) * 0.5
                let gy = (a[i + s] - a[i - s]) * 0.5
                sxx += gx * gx; syy += gy * gy; sxy += gx * gy
            }
        }
        let tr = sxx + syy
        let det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        return tr / 2 - disc
    }

    func matchPatch(_ a: UnsafeBufferPointer<Float>, _ b: UnsafeBufferPointer<Float>, _ s: Int,
                    _ x: Int, _ y: Int, _ pr: Int, _ sr: Int) -> (Double, Double)? {
        let n = Float((2 * pr + 1) * (2 * pr + 1))
        var patch = [Float]()
        patch.reserveCapacity(Int(n))
        var mean: Float = 0
        for dy in -pr...pr { for dx in -pr...pr { let v = a[(y + dy) * s + x + dx]; patch.append(v); mean += v } }
        mean /= n
        var varA: Float = 0
        for k in 0..<patch.count { patch[k] -= mean; varA += patch[k] * patch[k] }
        if varA < 1e-6 { return nil }

        let dim = 2 * sr + 1
        var scores = [Float](repeating: -2, count: dim * dim)
        var bestScore: Float = -2
        var bestIdx = (0, 0)
        for oy in -sr...sr {
            for ox in -sr...sr {
                var sb: Float = 0, sbb: Float = 0, sab: Float = 0
                var k = 0
                for dy in -pr...pr {
                    let row = (y + oy + dy) * s + x + ox
                    for dx in -pr...pr {
                        let v = b[row + dx]
                        sb += v; sbb += v * v; sab += patch[k] * v
                        k += 1
                    }
                }
                let varB = sbb - sb * sb / n
                if varB < 1e-6 { continue }
                let score = sab / (varA * varB).squareRoot()
                scores[(oy + sr) * dim + ox + sr] = score
                if score > bestScore { bestScore = score; bestIdx = (ox, oy) }
            }
        }
        if bestScore < config.minNCC { return nil }
        // Peak must not be on the border of the search window.
        if abs(bestIdx.0) == sr || abs(bestIdx.1) == sr { return nil }
        // Sub-pixel refinement by fitting parabolas through the NCC peak.
        func sc(_ ox: Int, _ oy: Int) -> Float { scores[(oy + sr) * dim + ox + sr] }
        let c = sc(bestIdx.0, bestIdx.1)
        let l = sc(bestIdx.0 - 1, bestIdx.1), r = sc(bestIdx.0 + 1, bestIdx.1)
        let u = sc(bestIdx.0, bestIdx.1 - 1), d = sc(bestIdx.0, bestIdx.1 + 1)
        var sx = 0.0, sy = 0.0
        let denX = l - 2 * c + r, denY = u - 2 * c + d
        if denX < 0 { sx = Double(max(-0.5, min(0.5, 0.5 * (l - r) / denX))) }
        if denY < 0 { sy = Double(max(-0.5, min(0.5, 0.5 * (u - d) / denY))) }
        return (Double(x + bestIdx.0) + sx, Double(y + bestIdx.1) + sy)
    }

    // MARK: - Robust rotation between ray sets: b ≈ R a

    func robustRotation(_ pairs: [(Vec3, Vec3)], threshold: Double) -> (Mat3, [Int])? {
        let n = pairs.count
        if n < 2 { return nil }
        var bestInliers: [Int] = []
        var bestR = Mat3.identity
        // Exhaustive over a bounded number of 2-point samples (deterministic).
        let maxSamples = 1500
        var samples: [(Int, Int)] = []
        let total = n * (n - 1) / 2
        let stride = max(1, total / maxSamples)
        var counter = 0
        for p in 0..<n { for q in (p + 1)..<n { if counter % stride == 0 { samples.append((p, q)) }; counter += 1 } }
        for (p, q) in samples {
            guard let R = Self.triad(pairs[p].0, pairs[q].0, pairs[p].1, pairs[q].1) else { continue }
            var inl: [Int] = []
            for k in 0..<n where (R * pairs[k].0 - pairs[k].1).length < threshold { inl.append(k) }
            if inl.count > bestInliers.count { bestInliers = inl; bestR = R }
        }
        if bestInliers.count < 2 { return nil }
        // Refine on inliers, then re-collect inliers.
        var R = Self.refineRotation(bestR, bestInliers.map { pairs[$0] })
        var inl: [Int] = []
        for k in 0..<n where (R * pairs[k].0 - pairs[k].1).length < threshold { inl.append(k) }
        if inl.count >= 3 { R = Self.refineRotation(R, inl.map { pairs[$0] }) }
        return (R, inl)
    }

    /// Rotation mapping a1->b1 exactly and a2 into the plane of (b1, b2).
    static func triad(_ a1: Vec3, _ a2: Vec3, _ b1: Vec3, _ b2: Vec3) -> Mat3? {
        let ta2 = a1.cross(a2), tb2 = b1.cross(b2)
        if ta2.length < 1e-6 || tb2.length < 1e-6 { return nil }
        let A = Mat3(columns: a1.normalized, ta2.normalized, a1.normalized.cross(ta2.normalized))
        let B = Mat3(columns: b1.normalized, tb2.normalized, b1.normalized.cross(tb2.normalized))
        return B * A.transposed
    }

    /// Gauss-Newton refinement of R minimizing sum |R a - b|^2.
    static func refineRotation(_ R0: Mat3, _ pairs: [(Vec3, Vec3)]) -> Mat3 {
        var R = R0
        for _ in 0..<5 {
            var H = [Double](repeating: 0, count: 9)
            var g = [Double](repeating: 0, count: 3)
            for (a, b) in pairs {
                let ra = R * a
                let e = ra - b
                // d(exp(w) R a)/dw = -[Ra]x
                let J = Mat3.skew(ra) * -1.0
                for r in 0..<3 {
                    for c in 0..<3 {
                        var s = 0.0
                        for k in 0..<3 { s += J[k, r] * J[k, c] }
                        H[r * 3 + c] += s
                    }
                    var s = 0.0
                    for k in 0..<3 { s += J[k, r] * e[k] }
                    g[r] += s
                }
            }
            for d in 0..<3 { H[d * 3 + d] += 1e-12 }
            guard let dx = LinearSolver.solveSPD(H, g.map { -$0 }, n: 3) else { break }
            R = (Mat3.rotation(Vec3(dx[0], dx[1], dx[2])) * R).orthonormalized
            if abs(dx[0]) + abs(dx[1]) + abs(dx[2]) < 1e-10 { break }
        }
        return R
    }
}
