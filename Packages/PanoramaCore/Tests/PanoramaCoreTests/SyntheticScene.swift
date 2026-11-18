import Foundation
@testable import PanoramaCore

/// Deterministic procedural "world" around the camera, used to render synthetic
/// photos with exactly known rotations.
struct SyntheticScene {
    struct Wave { var k: Vec3; var phase: Double; var amp: Vec3 }
    var waves: [Wave] = []

    init(seed: UInt64 = 42) {
        var rng = SplitMix(seed: seed)
        // Multi-scale band-limited texture with lots of 2D structure.
        for (count, freq, amp) in [(6, 3.0, 0.18), (10, 9.0, 0.10), (16, 24.0, 0.07), (20, 55.0, 0.05)] {
            for _ in 0..<count {
                let k = Vec3(rng.normal(), rng.normal(), rng.normal()).normalized * freq
                waves.append(Wave(k: k, phase: rng.uniform() * 2 * .pi,
                                  amp: Vec3(rng.uniform(), rng.uniform(), rng.uniform()) * amp))
            }
        }
    }

    func color(_ d: Vec3) -> Vec3 {
        var c = Vec3(0.45, 0.45, 0.45)
        for w in waves {
            let s = sin(w.k.dot(d) + w.phase)
            c += w.amp * s
        }
        // Brighter "sky" towards the zenith, darker "ground" towards the nadir.
        c += Vec3(0.05, 0.08, 0.12) * d.y
        return Vec3(max(0, min(1, c.x)), max(0, min(1, c.y)), max(0, min(1, c.z)))
    }

    func render(intrinsics K: Intrinsics, rotation R: Mat3, gain: Double = 1, noise: Double = 0, seed: UInt64 = 1) -> FloatImage {
        var img = FloatImage(width: K.width, height: K.height, channels: 3)
        var rng = SplitMix(seed: seed)
        for v in 0..<K.height {
            for u in 0..<K.width {
                // 2x2 supersampling to approximate a real sensor's pixel integration.
                var c = Vec3.zero
                for (du, dv) in [(-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)] {
                    c += color((R * K.ray(u: Double(u) + du, v: Double(v) + dv)).normalized)
                }
                c = c * (0.25 * gain)
                let o = (v * K.width + u) * 3
                img.data[o] = Float(c.x + noise * rng.normal())
                img.data[o + 1] = Float(c.y + noise * rng.normal())
                img.data[o + 2] = Float(c.z + noise * rng.normal())
            }
        }
        return img
    }

    func equirect(width: Int, gauge: Mat3) -> FloatImage {
        let h = width / 2
        var img = FloatImage(width: width, height: h, channels: 3)
        let gt = gauge.transposed
        for y in 0..<h {
            for x in 0..<width {
                let d = gt * Equirect.direction(x: Double(x), y: Double(y), width: width, height: h)
                let c = color(d)
                let o = (y * width + x) * 3
                img.data[o] = Float(c.x); img.data[o + 1] = Float(c.y); img.data[o + 2] = Float(c.z)
            }
        }
        return img
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func normal() -> Double {
        let u1 = max(1e-12, uniform()), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

enum TestImageIO {
    /// Writes a binary PPM (for eyeballing results during development).
    static func writePPM(_ img: FloatImage, to path: String) {
        var data = Data("P6\n\(img.width) \(img.height)\n255\n".utf8)
        let rgba = img.rgba8()
        var rgb = [UInt8](); rgb.reserveCapacity(img.width * img.height * 3)
        for i in 0..<(img.width * img.height) { rgb.append(rgba[i * 4]); rgb.append(rgba[i * 4 + 1]); rgb.append(rgba[i * 4 + 2]) }
        data.append(contentsOf: rgb)
        FileManager.default.createFile(atPath: path, contents: data)
    }

    static func psnr(_ a: FloatImage, _ b: FloatImage, rowWeights: Bool = true) -> Double {
        var se = 0.0, wsum = 0.0
        for y in 0..<a.height {
            let w = rowWeights ? cos((Double(y) + 0.5) / Double(a.height) * .pi - .pi / 2) : 1
            for x in 0..<a.width {
                for c in 0..<3 {
                    let i = (y * a.width + x) * 3 + c
                    let d = Double(a.data[i] - b.data[i])
                    se += w * d * d
                }
                wsum += 3 * w
            }
        }
        return 10 * log10(1 / max(se / wsum, 1e-12))
    }
}
