import Foundation

/// Global rotation-only bundle adjustment (Brown & Lowe 2007, section 4), solved with
/// Levenberg-Marquardt and a Huber robust kernel.
///
/// Unknowns: one rotation per photo (parameterized as an incremental rotation vector).
/// Residuals:
/// - for every ray correspondence: `f * (R_i u_i - R_j u_j)` (≈ reprojection error in pixels),
/// - for every photo a weak prior pulling it towards its sensor rotation, which fixes the
///   gauge freedom and keeps photos without texture (sky, ceilings) where the sensor put them.
public struct BundleAdjuster: Sendable {
    public var focal: Double
    public var priorSigma: Double = 3.0.radians
    public var huberPixels: Double = 2.0
    public var iterations: Int = 30

    public init(focal: Double) { self.focal = focal }

    public struct Result: Sendable {
        public var rotations: [Mat3]
        public var initialRMS: Double
        public var finalRMS: Double
    }

    public func optimize(initial: [Mat3], matches: [RayMatch]) -> Result {
        let n = initial.count
        var R = initial
        let dim = 3 * n

        func cost(_ R: [Mat3]) -> (Double, Double) {
            var c = 0.0, sq = 0.0
            for m in matches {
                let e = (R[m.i] * m.rayI - R[m.j] * m.rayJ).length * focal
                sq += e * e
                c += huber(e)
            }
            for k in 0..<n {
                let p = (initial[k].transposed * R[k]).rotationVector.length / priorSigma
                c += p * p
            }
            return (c, matches.isEmpty ? 0 : (sq / Double(matches.count)).squareRoot())
        }

        func huber(_ e: Double) -> Double {
            e <= huberPixels ? e * e : 2 * huberPixels * e - huberPixels * huberPixels
        }

        var (currentCost, initialRMS) = cost(R)
        var lambda = 1e-3
        for _ in 0..<iterations {
            var H = [Double](repeating: 0, count: dim * dim)
            var g = [Double](repeating: 0, count: dim)

            for m in matches {
                let a = R[m.i] * m.rayI, b = R[m.j] * m.rayJ
                let e = (a - b) * focal
                let en = e.length
                let w = en <= huberPixels ? 1.0 : huberPixels / en
                // R <- R exp([w]x)  =>  d(R exp(w) u)/dw = -R [u]x
                let Ri: Mat3 = R[m.i], Rj: Mat3 = R[m.j]
                let Si: Mat3 = Mat3.skew(m.rayI), Sj: Mat3 = Mat3.skew(m.rayJ)
                let Ji: Mat3 = (Ri * Si) * (-focal)
                let Jj: Mat3 = (Rj * Sj) * focal
                accumulate(&H, &g, dim, m.i, Ji, m.j, Jj, e, w)
            }
            let ip = 1 / (priorSigma * priorSigma)
            for k in 0..<n {
                // Prior residual r = log(R0^T R) ; with R <- R exp(w): r' ≈ r + w
                let r = (initial[k].transposed * R[k]).rotationVector
                for d in 0..<3 {
                    H[(3 * k + d) * dim + 3 * k + d] += ip
                    g[3 * k + d] += ip * r[d]
                }
            }

            var improved = false
            for _ in 0..<8 {
                var A = H
                for d in 0..<dim { A[d * dim + d] *= (1 + lambda); A[d * dim + d] += 1e-9 }
                guard let dx = LinearSolver.solveSPD(A, g.map { -$0 }, n: dim) else { lambda *= 10; continue }
                var Rn = R
                for k in 0..<n {
                    Rn[k] = (R[k] * Mat3.rotation(Vec3(dx[3 * k], dx[3 * k + 1], dx[3 * k + 2]))).orthonormalized
                }
                let (c, _) = cost(Rn)
                if c < currentCost {
                    let rel = (currentCost - c) / max(currentCost, 1e-12)
                    R = Rn
                    currentCost = c
                    lambda = max(1e-7, lambda * 0.3)
                    improved = rel > 1e-7
                    break
                } else {
                    lambda *= 10
                }
            }
            if !improved { break }
        }
        let (_, finalRMS) = cost(R)
        return Result(rotations: R, initialRMS: initialRMS, finalRMS: finalRMS)
    }

    private func accumulate(_ H: inout [Double], _ g: inout [Double], _ dim: Int,
                            _ i: Int, _ Ji: Mat3, _ j: Int, _ Jj: Mat3, _ e: Vec3, _ w: Double) {
        let blocks = [(i, Ji), (j, Jj)]
        for (bi, Ja) in blocks {
            for (bj, Jb) in blocks {
                for r in 0..<3 {
                    for c in 0..<3 {
                        let s = Ja[0, r] * Jb[0, c] + Ja[1, r] * Jb[1, c] + Ja[2, r] * Jb[2, c]
                        H[(3 * bi + r) * dim + 3 * bj + c] += w * s
                    }
                }
            }
            for r in 0..<3 {
                g[3 * bi + r] += w * (Ja[0, r] * e.x + Ja[1, r] * e.y + Ja[2, r] * e.z)
            }
        }
    }
}
