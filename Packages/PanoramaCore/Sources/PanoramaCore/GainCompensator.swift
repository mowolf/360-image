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
        let n = thumbs.count
        let W = gridWidth, H = gridWidth / 2
        // Per grid cell, which images cover it and their colours.
        var samples = [[(Int, Float, Float, Float)]](repeating: [], count: W * H)
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
                        samples[y * W + x].append((k, px[0], px[1], px[2]))
                    }
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
        return result
    }
}
