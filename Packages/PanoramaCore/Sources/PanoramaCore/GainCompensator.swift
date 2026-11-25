import Foundation

/// Per-image, per-channel gain compensation (Brown & Lowe 2007, section 6).
///
/// Minimizes  sum_ij N_ij [ (g_i I_ij - g_j I_ji)^2 / sigmaN^2 + (1 - g_i)^2 / sigmaG^2 ]
/// where I_ij is the mean of image i inside its overlap with image j. Statistics are
/// gathered on a small equirectangular grid so the cost is negligible.
public struct GainCompensator: Sendable {
    public var gridWidth = 512
    public var sigmaN = 10.0 / 255.0
    public var sigmaG = 0.1

    public init() {}

    /// - Parameters:
    ///   - thumbs: small RGB versions of the photos.
    ///   - cameras: cameras matching the thumbnails' intrinsics, with final rotations.
    /// - Returns: gains[i] = (r, g, b).
    public func gains(thumbs: [FloatImage], cameras: [PanoCamera]) -> [[Float]] {
        compensate(thumbs: thumbs, cameras: cameras, estimateVignetting: false).gains
    }

    /// Jointly estimates lens vignetting (shared by all photos) and per-photo gains.
    public func compensate(thumbs: [FloatImage], cameras: [PanoCamera],
                           estimateVignetting: Bool) -> (gains: [[Float]], vignette: Vignette) {
        let n = thumbs.count
        let W = gridWidth, H = gridWidth / 2
        // Per grid cell, which images cover it and their colours.
        var samples = [[(Int, Float, Float, Float, Float)]](repeating: [], count: W * H)
        for k in 0..<n {
            let img = thumbs[k]
            let K = cameras[k].intrinsics
            let P = cameras[k].projector
            img.data.withUnsafeBufferPointer { src in
                var px = [Float](repeating: 0, count: 3)
                for y in 0..<H {
                    for x in 0..<W {
                        let d = Equirect.direction(x: Double(x), y: Double(y), width: W, height: H)
                        guard let p = P.project(d), p.u >= 0, p.v >= 0,
                              p.u <= Double(K.width - 1), p.v <= Double(K.height - 1) else { continue }
                        px.withUnsafeMutableBufferPointer { o in
                            FloatImage.sampleBilinear(src, width: img.width, height: img.height, channels: 3,
                                                      x: p.u, y: p.v, out: o.baseAddress!)
                        }
                        samples[y * W + x].append((k, px[0], px[1], px[2], Float(Vignette.radius2(u: p.u, v: p.v, K: K))))
                    }
                }
            }
        }
        // Vignetting: log I_a - log I_b = log V(r_a) - log V(r_b) + log g_b - log g_a.
        var vignette = Vignette()
        if estimateVignetting {
            vignette = Vignette.estimate(samples: samples, gridWidth: W, imageCount: n)
            for c in 0..<samples.count where !samples[c].isEmpty {
                for k in 0..<samples[c].count {
                    let v = Float(1 / vignette.factor(r2: Double(samples[c][k].4)))
                    samples[c][k].1 *= v; samples[c][k].2 *= v; samples[c][k].3 *= v
                }
            }
        }
        // Overlap statistics.
        var N = [Double](repeating: 0, count: n * n)
        var I = [[Double]](repeating: [Double](repeating: 0, count: n * n), count: 3) // sum of image i in overlap(i,j)
        for y in 0..<H {
            let wgt = cos((Double(y) + 0.5) / Double(H) * .pi - .pi / 2) // equal-area weighting
            for s in samples[y * W..<(y + 1) * W] where s.count > 1 {
                for a in s {
                    for b in s where b.0 != a.0 {
                        N[a.0 * n + b.0] += wgt
                        I[0][a.0 * n + b.0] += wgt * Double(a.1)
                        I[1][a.0 * n + b.0] += wgt * Double(a.2)
                        I[2][a.0 * n + b.0] += wgt * Double(a.3)
                    }
                }
            }
        }
        var result = [[Float]](repeating: [1, 1, 1], count: n)
        let isn = 1 / (sigmaN * sigmaN), isg = 1 / (sigmaG * sigmaG)
        for ch in 0..<3 {
            var A = [Double](repeating: 0, count: n * n)
            var b = [Double](repeating: 0, count: n)
            for i in 0..<n {
                A[i * n + i] += 1e-6 // keep isolated images at gain 1 numerically
                for j in 0..<n where j != i {
                    let nij = N[i * n + j]
                    if nij < 1 { continue }
                    let Iij = I[ch][i * n + j] / nij
                    let Iji = I[ch][j * n + i] / max(N[j * n + i], 1e-9)
                    A[i * n + i] += nij * (Iij * Iij * isn + isg)
                    A[i * n + j] -= nij * Iij * Iji * isn
                    b[i] += nij * isg
                }
                if A[i * n + i] <= 1e-6 { A[i * n + i] = 1; b[i] = 1 }
            }
            if let g = LinearSolver.solveSPD(A, b, n: n) {
                for i in 0..<n { result[i][ch] = Float(max(0.5, min(2.0, g[i]))) }
            }
        }
        return (result, vignette)
    }
}

/// Radial lens falloff V(r) = exp(a r² + b r⁴), r normalized to the half diagonal.
public struct Vignette: Sendable, Equatable {
    public var a: Double = 0
    public var b: Double = 0
    public init(a: Double = 0, b: Double = 0) { self.a = a; self.b = b }

    public var isIdentity: Bool { a == 0 && b == 0 }

    @inlinable public static func radius2(u: Double, v: Double, K: Intrinsics) -> Double {
        let hw = Double(K.width) / 2, hh = Double(K.height) / 2
        let dx = u - K.cx, dy = v - K.cy
        return (dx * dx + dy * dy) / (hw * hw + hh * hh)
    }

    @inlinable public func factor(r2: Double) -> Double {
        max(0.35, min(1.2, exp(a * r2 + b * r2 * r2)))
    }

    /// Divides out the vignetting from an image with intrinsics K.
    public func correct(_ img: inout FloatImage, K: Intrinsics) {
        if isIdentity { return }
        let sx = Double(K.width) / Double(img.width), sy = Double(K.height) / Double(img.height)
        let c = img.channels, w = img.width
        img.data.withUnsafeMutableBufferPointer { d in
            DispatchQueue.concurrentPerform(iterations: img.height) { y in
                for x in 0..<w {
                    let r2 = Vignette.radius2(u: (Double(x) + 0.5) * sx - 0.5, v: (Double(y) + 0.5) * sy - 0.5, K: K)
                    let f = Float(1 / self.factor(r2: r2))
                    let o = (y * w + x) * c
                    for ch in 0..<c { d[o + ch] *= f }
                }
            }
        }
    }

    /// Least-squares fit from overlapping samples (index, r, g, b, r²) per grid cell.
    static func estimate(samples: [[(Int, Float, Float, Float, Float)]], gridWidth W: Int, imageCount n: Int) -> Vignette {
        // Unknowns: [a, b, lg_0 ... lg_{n-1}]
        let dim = n + 2
        var A = [Double](repeating: 0, count: dim * dim)
        var rhs = [Double](repeating: 0, count: dim)
        var count = 0
        let H = samples.count / W
        for y in 0..<H {
            let wgt = cos((Double(y) + 0.5) / Double(H) * .pi - .pi / 2)
            for c in samples[(y * W)..<((y + 1) * W)] where c.count > 1 {
                for ia in 0..<c.count {
                    for ib in (ia + 1)..<c.count {
                        let p = c[ia], q = c[ib]
                        let la = Double(0.2126 * p.1 + 0.7152 * p.2 + 0.0722 * p.3)
                        let lb = Double(0.2126 * q.1 + 0.7152 * q.2 + 0.0722 * q.3)
                        if la < 0.04 || lb < 0.04 || la > 0.92 || lb > 0.92 { continue }
                        // Equation: a(ra2-rb2) + b(ra4-rb4) - lg_a + lg_b = log la - log lb
                        let ra2 = Double(p.4), rb2 = Double(q.4)
                        var row = [(Int, Double)]()
                        row.append((0, ra2 - rb2))
                        row.append((1, ra2 * ra2 - rb2 * rb2))
                        row.append((2 + p.0, -1))
                        row.append((2 + q.0, 1))
                        let y0 = log(la) - log(lb)
                        for (i, vi) in row {
                            rhs[i] += wgt * vi * y0
                            for (j, vj) in row { A[i * dim + j] += wgt * vi * vj }
                        }
                        count += 1
                    }
                }
            }
        }
        if count < 200 { return Vignette() }
        // Weak priors: gains near 1, vignetting near 0 (keeps the system well-posed).
        let lambda = Double(count) * 1e-4
        A[0] += lambda * 0.1
        A[dim + 1] += lambda * 0.1
        for k in 0..<n { A[(2 + k) * dim + 2 + k] += lambda }
        guard let x = LinearSolver.solveSPD(A, rhs, n: dim) else { return Vignette() }
        var v = Vignette(a: x[0], b: x[1])
        // Only accept physically plausible falloff (darker towards the corners).
        // iPhones already correct most lens shading in the ISP; a strong estimate usually
        // means the scene fooled the fit (bright sky, local tone mapping), so only mild
        // corrections are trusted.
        if v.factor(r2: 1) > 1.02 || v.factor(r2: 1) < 0.65 { v = Vignette() }
        return v
    }
}
