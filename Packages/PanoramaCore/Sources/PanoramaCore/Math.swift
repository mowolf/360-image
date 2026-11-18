import Foundation

// Small, dependency-free linear algebra so the stitching core builds and is
// testable on every platform (iOS, macOS, Linux CI).

public struct Vec3: Equatable, Sendable {
    public var x: Double, y: Double, z: Double
    @inlinable public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = Vec3(0, 0, 0)

    @inlinable public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    @inlinable public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    @inlinable public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    @inlinable public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func * (s: Double, a: Vec3) -> Vec3 { a * s }
    @inlinable public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    @inlinable public static func += (a: inout Vec3, b: Vec3) { a = a + b }

    @inlinable public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    @inlinable public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    @inlinable public var length: Double { (x * x + y * y + z * z).squareRoot() }
    @inlinable public var normalized: Vec3 { let l = length; return l > 0 ? self / l : self }
    @inlinable public subscript(i: Int) -> Double {
        get { i == 0 ? x : (i == 1 ? y : z) }
        set { if i == 0 { x = newValue } else if i == 1 { y = newValue } else { z = newValue } }
    }

    /// Angle in radians between two (not necessarily unit) vectors.
    public func angle(to b: Vec3) -> Double {
        atan2(cross(b).length, dot(b))
    }
}

/// Row-major 3x3 matrix.
public struct Mat3: Equatable, Sendable {
    public var m: (Double, Double, Double, Double, Double, Double, Double, Double, Double)

    @inlinable public init(_ m00: Double, _ m01: Double, _ m02: Double,
                           _ m10: Double, _ m11: Double, _ m12: Double,
                           _ m20: Double, _ m21: Double, _ m22: Double) {
        m = (m00, m01, m02, m10, m11, m12, m20, m21, m22)
    }

    /// Build from three column vectors.
    public init(columns c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        self.init(c0.x, c1.x, c2.x, c0.y, c1.y, c2.y, c0.z, c1.z, c2.z)
    }

    public static let identity = Mat3(1, 0, 0, 0, 1, 0, 0, 0, 1)

    public static func == (a: Mat3, b: Mat3) -> Bool {
        for r in 0..<3 { for c in 0..<3 where a[r, c] != b[r, c] { return false } }
        return true
    }

    @inlinable public subscript(r: Int, c: Int) -> Double {
        get {
            switch r * 3 + c {
            case 0: return m.0; case 1: return m.1; case 2: return m.2
            case 3: return m.3; case 4: return m.4; case 5: return m.5
            case 6: return m.6; case 7: return m.7; default: return m.8
            }
        }
        set {
            switch r * 3 + c {
            case 0: m.0 = newValue; case 1: m.1 = newValue; case 2: m.2 = newValue
            case 3: m.3 = newValue; case 4: m.4 = newValue; case 5: m.5 = newValue
            case 6: m.6 = newValue; case 7: m.7 = newValue; default: m.8 = newValue
            }
        }
    }

    public func column(_ c: Int) -> Vec3 { Vec3(self[0, c], self[1, c], self[2, c]) }

    @inlinable public var transposed: Mat3 {
        Mat3(m.0, m.3, m.6, m.1, m.4, m.7, m.2, m.5, m.8)
    }

    @inlinable public static func * (a: Mat3, v: Vec3) -> Vec3 {
        Vec3(a.m.0 * v.x + a.m.1 * v.y + a.m.2 * v.z,
             a.m.3 * v.x + a.m.4 * v.y + a.m.5 * v.z,
             a.m.6 * v.x + a.m.7 * v.y + a.m.8 * v.z)
    }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        var r = Mat3.identity
        for i in 0..<3 {
            for j in 0..<3 {
                r[i, j] = a[i, 0] * b[0, j] + a[i, 1] * b[1, j] + a[i, 2] * b[2, j]
            }
        }
        return r
    }

    public static func * (a: Mat3, s: Double) -> Mat3 {
        var r = a
        for i in 0..<3 { for j in 0..<3 { r[i, j] *= s } }
        return r
    }

    public static func + (a: Mat3, b: Mat3) -> Mat3 {
        var r = a
        for i in 0..<3 { for j in 0..<3 { r[i, j] += b[i, j] } }
        return r
    }

    /// Skew-symmetric cross-product matrix [v]x.
    public static func skew(_ v: Vec3) -> Mat3 {
        Mat3(0, -v.z, v.y, v.z, 0, -v.x, -v.y, v.x, 0)
    }

    /// Rodrigues: rotation matrix from an axis-angle vector (radians).
    public static func rotation(_ w: Vec3) -> Mat3 {
        let theta = w.length
        if theta < 1e-12 { return identity + skew(w) }
        let k = w / theta
        let K = skew(k)
        let s = sin(theta), c = cos(theta)
        return identity + K * s + (K * K) * (1 - c)
    }

    public static func rotation(axis: Vec3, angle: Double) -> Mat3 {
        rotation(axis.normalized * angle)
    }

    /// Inverse Rodrigues: axis-angle vector of a rotation matrix (via a robust
    /// quaternion conversion, valid for all angles).
    public var rotationVector: Vec3 {
        let q = quaternion
        var (w, v) = (q.w, Vec3(q.x, q.y, q.z))
        if w < 0 { w = -w; v = -v }
        let s = v.length
        if s < 1e-12 { return v * 2 }
        let theta = 2 * atan2(s, w)
        return v * (theta / s)
    }

    /// Unit quaternion (w, x, y, z) for this rotation matrix (Shepperd's method).
    public var quaternion: (w: Double, x: Double, y: Double, z: Double) {
        let tr = self[0, 0] + self[1, 1] + self[2, 2]
        var w, x, y, z: Double
        if tr > 0 {
            let s = (tr + 1).squareRoot() * 2
            w = 0.25 * s
            x = (self[2, 1] - self[1, 2]) / s
            y = (self[0, 2] - self[2, 0]) / s
            z = (self[1, 0] - self[0, 1]) / s
        } else if self[0, 0] > self[1, 1] && self[0, 0] > self[2, 2] {
            let s = (1 + self[0, 0] - self[1, 1] - self[2, 2]).squareRoot() * 2
            w = (self[2, 1] - self[1, 2]) / s
            x = 0.25 * s
            y = (self[0, 1] + self[1, 0]) / s
            z = (self[0, 2] + self[2, 0]) / s
        } else if self[1, 1] > self[2, 2] {
            let s = (1 + self[1, 1] - self[0, 0] - self[2, 2]).squareRoot() * 2
            w = (self[0, 2] - self[2, 0]) / s
            x = (self[0, 1] + self[1, 0]) / s
            y = 0.25 * s
            z = (self[1, 2] + self[2, 1]) / s
        } else {
            let s = (1 + self[2, 2] - self[0, 0] - self[1, 1]).squareRoot() * 2
            w = (self[1, 0] - self[0, 1]) / s
            x = (self[0, 2] + self[2, 0]) / s
            y = (self[1, 2] + self[2, 1]) / s
            z = 0.25 * s
        }
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return (w / n, x / n, y / n, z / n)
    }

    /// Rotation matrix from a unit quaternion.
    public static func fromQuaternion(w: Double, x: Double, y: Double, z: Double) -> Mat3 {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        let (w, x, y, z) = (w / n, x / n, y / n, z / n)
        return Mat3(1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
                    2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
                    2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y))
    }

    /// Re-orthonormalize (Gram-Schmidt on columns) to remove numeric drift.
    public var orthonormalized: Mat3 {
        let c0 = column(0).normalized
        var c1 = column(1)
        c1 = (c1 - c0 * c0.dot(c1)).normalized
        let c2 = c0.cross(c1)
        return Mat3(columns: c0, c1, c2)
    }

    /// Spherical interpolation between two rotations.
    public static func slerp(_ a: Mat3, _ b: Mat3, _ t: Double) -> Mat3 {
        a * rotation((a.transposed * b).rotationVector * t)
    }
}

public extension Double {
    var degrees: Double { self * 180 / .pi }
    var radians: Double { self * .pi / 180 }
}

// MARK: - Dense linear solvers (small systems: bundle adjustment, gain compensation)

enum LinearSolver {
    /// Solves A x = b for symmetric positive definite A (row-major n x n) using Cholesky.
    /// Returns nil if A is not positive definite.
    static func solveSPD(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i * n + j]
                for k in 0..<j { sum -= L[i * n + k] * L[j * n + k] }
                if i == j {
                    if sum <= 0 { return nil }
                    L[i * n + i] = sum.squareRoot()
                } else {
                    L[i * n + j] = sum / L[j * n + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            for k in 0..<i { sum -= L[i * n + k] * y[k] }
            y[i] = sum / L[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for k in (i + 1)..<n { sum -= L[k * n + i] * x[k] }
            x[i] = sum / L[i * n + i]
        }
        return x
    }
}
