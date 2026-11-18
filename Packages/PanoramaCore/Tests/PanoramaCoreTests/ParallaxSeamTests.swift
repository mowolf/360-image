import XCTest
@testable import PanoramaCore

final class MaxFlowTests: XCTestCase {
    /// Compares the graph-cut minimum with brute force on random small binary energies.
    func testMatchesBruteForce() {
        var rng = SplitMix(seed: 11)
        for trial in 0..<200 {
            let n = 2 + Int(rng.uniform() * 9)
            var unary: [(Double, Double)] = []
            var pairs: [(Int, Int, Double, Double, Double, Double)] = []
            for _ in 0..<n { unary.append((rng.uniform() * 5, rng.uniform() * 5)) }
            for i in 0..<n {
                for j in (i + 1)..<n where rng.uniform() < 0.5 {
                    // Submodular pairwise term.
                    let a = rng.uniform() * 3, d = rng.uniform() * 3
                    let b = rng.uniform() * 3 + a / 2 + d / 2, c = rng.uniform() * 3 + a / 2 + d / 2
                    pairs.append((i, j, a, b, c, d))
                }
            }
            func energy(_ x: [Int]) -> Double {
                var e = 0.0
                for i in 0..<n { e += x[i] == 0 ? unary[i].0 : unary[i].1 }
                for (i, j, a, b, c, d) in pairs {
                    e += [[a, b], [c, d]][x[i]][x[j]]
                }
                return e
            }
            var best = Double.infinity
            for mask in 0..<(1 << n) {
                best = min(best, energy((0..<n).map { (mask >> $0) & 1 }))
            }
            let g = MaxFlowGraph()
            g.addNodes(n)
            for i in 0..<n { g.addUnary(i, e0: unary[i].0, e1: unary[i].1) }
            for (i, j, a, b, c, d) in pairs { g.addPairwise(i, j, A: a, B: b, C: c, D: d) }
            _ = g.maxflow()
            let x = (0..<n).map { g.isSink($0) ? 1 : 0 }
            XCTAssertEqual(energy(x), best, accuracy: 1e-9, "trial \(trial)")
        }
    }
}

/// A room with nearby objects, captured by a phone that moves between shots.
struct ParallaxScene {
    let texture = SyntheticScene(seed: 5)
    let ballTexture = SyntheticScene(seed: 77)
    let roomRadius = 4.0
    let balls: [(center: Vec3, radius: Double)] = [
        (Vec3(0.15, -0.25, -1.1), 0.3),
        (Vec3(1.0, 0.1, 0.4), 0.25),
        (Vec3(-0.8, -0.6, -0.5), 0.3),
        (Vec3(-0.3, 0.5, 0.9), 0.2),
    ]

    /// Returns colour and distance along the (unit) ray.
    func cast(_ o: Vec3, _ d: Vec3) -> (Vec3, Double) {
        var bestT = Double.infinity
        var color = Vec3.zero
        for (k, b) in balls.enumerated() {
            let oc = o - b.center
            let bq = oc.dot(d)
            let c = oc.dot(oc) - b.radius * b.radius
            let disc = bq * bq - c
            if disc < 0 { continue }
            let t = -bq - disc.squareRoot()
            if t > 1e-6 && t < bestT {
                bestT = t
                let nrm = (o + d * t - b.center).normalized
                let tint = [Vec3(1.2, 0.8, 0.7), Vec3(0.7, 1.1, 0.8), Vec3(0.8, 0.8, 1.2), Vec3(1.1, 1.1, 0.6)][k]
                let c0 = ballTexture.color(nrm)
                color = Vec3(min(1, c0.x * tint.x), min(1, c0.y * tint.y), min(1, c0.z * tint.z))
            }
        }
        if bestT.isFinite { return (color, bestT) }
        // Room: sphere around the origin, we are inside.
        let bq = o.dot(d)
        let c = o.dot(o) - roomRadius * roomRadius
        let t = -bq + (bq * bq - c).squareRoot()
        return (texture.color((o + d * t).normalized), t)
    }

    func render(K: Intrinsics, R: Mat3, position: Vec3) -> (FloatImage, DepthMap) {
        var img = FloatImage(width: K.width, height: K.height, channels: 3)
        for v in 0..<K.height {
            for u in 0..<K.width {
                var c = Vec3.zero
                for (du, dv) in [(-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)] {
                    c += cast(position, (R * K.ray(u: Double(u) + du, v: Double(v) + dv)).normalized).0
                }
                c = c * 0.25
                let o = (v * K.width + u) * 3
                img.data[o] = Float(c.x); img.data[o + 1] = Float(c.y); img.data[o + 2] = Float(c.z)
            }
        }
        // LiDAR-like low resolution z-depth.
        let dw = 64, dh = 48
        var depth = [Float](repeating: 0, count: dw * dh)
        for y in 0..<dh {
            for x in 0..<dw {
                let u = (Double(x) + 0.5) / Double(dw) * Double(K.width) - 0.5
                let v = (Double(y) + 0.5) / Double(dh) * Double(K.height) - 0.5
                let ray = K.ray(u: u, v: v)
                let t = cast(position, (R * ray).normalized).1
                depth[y * dw + x] = Float(t / ray.length) // z-depth (ray has z = -1)
            }
        }
        return (img, DepthMap(width: dw, height: dh, depth: depth))
    }

    func equirect(width: Int, center: Vec3, gauge: Mat3) -> FloatImage {
        let h = width / 2
        var img = FloatImage(width: width, height: h, channels: 3)
        let gt = gauge.transposed
        for y in 0..<h {
            for x in 0..<width {
                let d = gt * Equirect.direction(x: Double(x), y: Double(y), width: width, height: h)
                let c = cast(center, d.normalized).0
                let o = (y * width + x) * 3
                img.data[o] = Float(c.x); img.data[o + 1] = Float(c.y); img.data[o + 2] = Float(c.z)
            }
        }
        return img
    }
}

final class ParallaxStitchTests: XCTestCase {
    func testDepthProjectorRoundTrip() {
        let scene = ParallaxScene()
        let K = SyntheticRig.intrinsics()
        let R = SyntheticRig.portraitRotation(yaw: 0.2, pitch: -0.1)
        let pos = Vec3(0.05, -0.02, -0.12)
        let (_, depth) = scene.render(K: K, R: R, position: pos)
        let P = PanoCamera(intrinsics: K, rotation: R, offset: pos, depth: depth).projector
        var maxErr = 0.0
        // Points away from depth discontinuities (at silhouettes the low-res depth is ambiguous).
        for (u, v) in [(240.0, 180.0), (440.0, 40.0), (400.0, 300.0), (30.0, 330.0)] {
            let d = P.unproject(u: u, v: v).normalized
            guard let p = P.project(d) else { XCTFail("no projection"); continue }
            maxErr = max(maxErr, abs(p.u - u) + abs(p.v - v))
        }
        XCTAssertLessThan(maxErr, 0.5)
    }

    func testParallaxCompensationAndGraphCutSeams() throws {
        let scene = ParallaxScene()
        let K = SyntheticRig.intrinsics()
        let plan = CapturePlan(horizontalFOV: 2 * atan(Double(K.height) / 2 / K.fy),
                               verticalFOV: 2 * atan(Double(K.width) / 2 / K.fx))
        var rng = SplitMix(seed: 21)
        var truth: [Mat3] = [], positions: [Vec3] = []
        var sources: [StitchSource] = []
        for t in plan.targets {
            let R = SyntheticRig.portraitRotation(yaw: t.yaw + 1.5.radians * rng.normal(),
                                                  pitch: t.pitch + 1.5.radians * rng.normal(),
                                                  roll: 2.radians * rng.normal())
            // The phone sits ~12 cm in front of the user's turning axis and wobbles.
            let pos = R * Vec3(0, 0, -0.12) + Vec3(rng.normal(), rng.normal(), rng.normal()) * 0.015
            let (img, depth) = scene.render(K: K, R: R, position: pos)
            truth.append(R); positions.append(pos)
            let noise = Vec3(rng.normal(), rng.normal(), rng.normal()) * 0.7.radians
            sources.append(StitchSource(intrinsics: K, rotation: R * Mat3.rotation(noise),
                                        position: pos, depth: depth, load: { img }))
        }
        let center = positions.reduce(Vec3.zero, +) / Double(positions.count)

        func run(parallax: Bool, seams: Bool, name: String) throws -> Double {
            var o = StitchOptions()
            o.outputWidth = 2048
            o.compensateParallax = parallax
            o.graphCutSeams = seams
            o.seamGridWidth = 1024
            let res = try Stitcher().stitch(sources, options: o)
            let G = res.report.rotations[0] * truth[0].transposed
            let gt = scene.equirect(width: res.panorama.width, center: center, gauge: G)
            let psnr = TestImageIO.psnr(res.panorama, gt)
            var errs: [Double] = []
            for k in 0..<truth.count {
                errs.append((G.transposed * res.report.rotations[k] * truth[k].transposed).rotationVector.length.degrees)
            }
            print("\(name): PSNR \(String(format: "%.2f", psnr)) dB, rot err mean \(String(format: "%.3f", errs.reduce(0, +) / Double(errs.count)))°, pairs \(res.report.pairsAligned)/\(res.report.pairsTried), \(String(format: "%.1f", res.report.seconds))s")
            if let dir = ProcessInfo.processInfo.environment["PANO_TEST_OUTPUT"] {
                TestImageIO.writePPM(res.panorama, to: "\(dir)/parallax_\(name).ppm")
                TestImageIO.writePPM(gt, to: "\(dir)/parallax_truth.ppm")
            }
            return psnr
        }
        let baseline = try run(parallax: false, seams: false, name: "baseline")
        let seamsOnly = try run(parallax: false, seams: true, name: "graphcut")
        let full = try run(parallax: true, seams: true, name: "depth+graphcut")
        XCTAssertGreaterThan(seamsOnly, baseline)
        XCTAssertGreaterThan(full, baseline + 2)
    }
}

final class DepthFusionTests: XCTestCase {
    func testInverseAffineFitRecoversScale() {
        // Relative depth d = (1/z - t) / s with s = 0.37, t = 0.05 plus noise and outliers.
        var rng = SplitMix(seed: 4)
        let W = 32, H = 24
        var z = [Double](repeating: 0, count: W * H)
        var rel = [Float](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W {
            let zz = 0.6 + 4 * Double(x) / Double(W) + Double(y) / Double(H)
            z[y * W + x] = zz
            rel[y * W + x] = Float((1 / zz - 0.05) / 0.37 + 0.01 * rng.normal())
        } }
        let relative = RelativeDepth(width: W, height: H, values: rel)
        var samples: [DepthSample] = []
        for _ in 0..<60 {
            let x = Int(rng.uniform() * Double(W)), y = Int(rng.uniform() * Double(H))
            var zz = z[y * W + x] * (1 + 0.03 * rng.normal())
            if rng.uniform() < 0.2 { zz = 0.3 + rng.uniform() * 10 } // outliers
            samples.append(DepthSample(u: Double(x), v: Double(y), z: zz))
        }
        let fit = DepthFusion.fitInverseAffine(relative: relative, samples: samples, imageWidth: W, imageHeight: H)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit?.s ?? 0, 0.37, accuracy: 0.03)
        XCTAssertEqual(fit?.t ?? 0, 0.05, accuracy: 0.02)
    }

    func testTriangulate() {
        let X = Vec3(0.3, -0.2, -1.5)
        let o1 = Vec3(0, 0, 0), o2 = Vec3(0.1, 0.02, 0)
        let p = DepthFusion.triangulate(o1: o1, d1: (X - o1).normalized, o2: o2, d2: (X - o2).normalized)
        XCTAssertEqual(((p ?? .zero) - X).length, 0, accuracy: 1e-9)
    }
}

final class NoLidarParallaxTests: XCTestCase {
    /// iPhone without LiDAR: only ARKit feature points + monocular relative depth.
    func testMonocularPlusSparseDepth() throws {
        let scene = ParallaxScene()
        let K = SyntheticRig.intrinsics()
        let plan = CapturePlan(horizontalFOV: 2 * atan(Double(K.height) / 2 / K.fy),
                               verticalFOV: 2 * atan(Double(K.width) / 2 / K.fx))
        var rng = SplitMix(seed: 21)
        var truth: [Mat3] = [], positions: [Vec3] = []
        var plain: [StitchSource] = [], mono: [StitchSource] = []
        for t in plan.targets {
            let R = SyntheticRig.portraitRotation(yaw: t.yaw + 1.5.radians * rng.normal(),
                                                  pitch: t.pitch + 1.5.radians * rng.normal(),
                                                  roll: 2.radians * rng.normal())
            let pos = R * Vec3(0, 0, -0.12) + Vec3(rng.normal(), rng.normal(), rng.normal()) * 0.015
            let (img, depth) = scene.render(K: K, R: R, position: pos)
            truth.append(R); positions.append(pos)
            // Monocular network output: affine in inverse depth, unknown s/t per photo, noisy.
            let s = 0.5 + rng.uniform(), tt = 0.2 * rng.uniform()
            let rel = depth.data.map { Float((1 / Double($0) - tt * 0.1) / s + 0.01 * rng.normal()) }
            let relative = RelativeDepth(width: depth.width, height: depth.height, values: rel)
            let noise = Vec3(rng.normal(), rng.normal(), rng.normal()) * 0.7.radians
            plain.append(StitchSource(intrinsics: K, rotation: R * Mat3.rotation(noise), position: pos, load: { img }))
            mono.append(StitchSource(intrinsics: K, rotation: R * Mat3.rotation(noise), position: pos,
                                     relativeDepth: relative, load: { img }))
        }
        // ARKit-like sparse cloud: surface points seen from near the centre, with ~2% depth noise.
        var cloud: [Vec3] = []
        for _ in 0..<1500 {
            let d = Vec3(rng.normal(), rng.normal(), rng.normal()).normalized
            let o = Vec3(rng.normal(), rng.normal(), rng.normal()) * 0.05
            let t = scene.cast(o, d).1 * (1 + 0.02 * rng.normal())
            cloud.append(o + d * t)
        }
        let center = positions.reduce(Vec3.zero, +) / Double(positions.count)

        func run(_ sources: [StitchSource], points: [Vec3], name: String) throws -> Double {
            var o = StitchOptions()
            o.outputWidth = 2048
            o.seamGridWidth = 1024
            let res = try Stitcher().stitch(sources, scenePoints: points, options: o)
            let G = res.report.rotations[0] * truth[0].transposed
            let gt = scene.equirect(width: res.panorama.width, center: center, gauge: G)
            let psnr = TestImageIO.psnr(res.panorama, gt)
            print("\(name): PSNR \(String(format: "%.2f", psnr)) dB, depth maps \(res.report.depthSources), parallax \(res.report.parallaxCompensated)")
            if let dir = ProcessInfo.processInfo.environment["PANO_TEST_OUTPUT"] {
                TestImageIO.writePPM(res.panorama, to: "\(dir)/nolidar_\(name).ppm")
            }
            return psnr
        }
        let none = try run(plain, points: [], name: "rotation-only")
        let sparse = try run(plain, points: cloud, name: "sparse-points")
        let full = try run(mono, points: cloud, name: "mono+sparse")
        XCTAssertGreaterThan(sparse, none + 3)
        XCTAssertGreaterThan(full, none + 8)
    }
}
