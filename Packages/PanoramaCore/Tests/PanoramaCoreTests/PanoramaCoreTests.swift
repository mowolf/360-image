import XCTest
@testable import PanoramaCore

final class MathTests: XCTestCase {
    func testRotationVectorRoundTrip() {
        for w in [Vec3(0.1, -0.2, 0.3), Vec3(0, 0, 3.1), Vec3(2.0, 1.0, -0.5), Vec3(1e-9, 0, 0)] {
            let R = Mat3.rotation(w)
            let back = R.rotationVector
            XCTAssertEqual((back - w).length, 0, accuracy: 1e-7, "\(w) -> \(back)")
            let Rt = R * R.transposed
            for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(Rt[i, j], i == j ? 1 : 0, accuracy: 1e-12) } }
        }
    }

    func testEquirectRoundTrip() {
        let d = Vec3(0.3, 0.5, -0.8).normalized
        let ll = Equirect.lonLat(d)
        XCTAssertEqual((Equirect.direction(lon: ll.lon, lat: ll.lat) - d).length, 0, accuracy: 1e-12)
        XCTAssertEqual(Equirect.lonLat(Vec3(0, 0, -1)).lon, 0, accuracy: 1e-12)
        XCTAssertEqual(Equirect.lonLat(Vec3(1, 0, 0)).lon, .pi / 2, accuracy: 1e-12)
    }

    func testCholesky() {
        let a: [Double] = [4, 2, 0, 2, 5, 1, 0, 1, 3]
        let x = LinearSolver.solveSPD(a, [2, 3, 4], n: 3)!
        let b = [4 * x[0] + 2 * x[1], 2 * x[0] + 5 * x[1] + x[2], x[1] + 3 * x[2]]
        XCTAssertEqual(b[0], 2, accuracy: 1e-12); XCTAssertEqual(b[1], 3, accuracy: 1e-12); XCTAssertEqual(b[2], 4, accuracy: 1e-12)
    }
}

final class PyramidTests: XCTestCase {
    func testLaplacianCollapseIsExact() {
        var img = FloatImage(width: 64, height: 32, channels: 3)
        var rng = SplitMix(seed: 3)
        for i in 0..<img.data.count { img.data[i] = Float(rng.uniform()) }
        for wrap in [false, true] {
            let lap = Pyramid.laplacian(img, levels: 4, wrapX: wrap)
            let back = Pyramid.collapse(lap, wrapX: wrap)
            for i in 0..<img.data.count { XCTAssertEqual(back.data[i], img.data[i], accuracy: 1e-5) }
        }
    }

    func testPushPullFillsHoles() {
        var img = FloatImage(width: 40, height: 20, channels: 1, fill: 0)
        var valid = [Bool](repeating: false, count: 800)
        for i in 0..<400 { img.data[i] = 0.7; valid[i] = true }
        Pyramid.pushPullFill(&img, valid: valid)
        for v in img.data { XCTAssertEqual(v, 0.7, accuracy: 1e-4) }
    }
}

final class CapturePlanTests: XCTestCase {
    func testPlanCoversSphere() {
        // iPhone main camera held in portrait: ~51 x 65 degrees.
        let plan = CapturePlan(horizontalFOV: 51.radians, verticalFOV: 65.radians)
        XCTAssertGreaterThan(plan.targets.count, 15)
        XCTAssertLessThan(plan.targets.count, 45)
        XCTAssertEqual(plan.targets.filter { $0.isPole }.count, 2)
        // Every direction on the sphere must be within the photo of some target.
        let half = (h: 25.5.radians, v: 32.5.radians)
        var rng = SplitMix(seed: 9)
        for _ in 0..<2000 {
            let d = Vec3(rng.normal(), rng.normal(), rng.normal()).normalized
            let covered = plan.targets.contains { t in
                let R = SyntheticRig.portraitRotation(yaw: t.yaw, pitch: t.pitch)
                let c = R.transposed * d
                if c.z >= 0 { return false }
                // sensor x is vertical when held in portrait
                return abs(atan(c.x / -c.z)) < half.v && abs(atan(c.y / -c.z)) < half.h
            }
            XCTAssertTrue(covered, "uncovered direction \(d)")
            if !covered { break }
        }
    }

    func testNextTargetIsAdjacent() {
        let plan = CapturePlan(horizontalFOV: 51.radians, verticalFOV: 65.radians)
        var captured: Set<Int> = []
        var current = Vec3(0, 0, -1)
        XCTAssertEqual(plan.nextTarget(captured: captured, currentDirection: current, baseYaw: 0)?.id, 0)
        while let t = plan.nextTarget(captured: captured, currentDirection: current, baseYaw: 0) {
            captured.insert(t.id)
            current = t.direction(baseYaw: 0)
        }
        XCTAssertEqual(captured.count, plan.targets.count)
    }
}

enum SyntheticRig {
    /// Phone held upright in portrait: ARKit's sensor x axis points up.
    static func portraitRotation(yaw: Double, pitch: Double, roll: Double = 0) -> Mat3 {
        let Ry = Mat3.rotation(axis: Vec3(0, 1, 0), angle: -yaw)
        let Rx = Mat3.rotation(axis: Vec3(1, 0, 0), angle: pitch)
        let Rz = Mat3.rotation(axis: Vec3(0, 0, 1), angle: .pi / 2 + roll)
        return Ry * Rx * Rz
    }

    /// Landscape sensor of the given size; fx chosen for a ~65 degree long-side FOV.
    static func intrinsics(width: Int = 480, height: Int = 360) -> Intrinsics {
        let f = Double(width) / 2 / tan(32.5.radians)
        return Intrinsics(fx: f, fy: f, cx: Double(width) / 2 - 0.5 + 3.2, cy: Double(height) / 2 - 0.5 - 2.1,
                          width: width, height: height)
    }
}

final class StitcherTests: XCTestCase {
    func testDirectionConventions() {
        let R = SyntheticRig.portraitRotation(yaw: 30.radians, pitch: 10.radians)
        let ll = Equirect.lonLat(R * Vec3(0, 0, -1))
        XCTAssertEqual(ll.lon, 30.radians, accuracy: 1e-9)
        XCTAssertEqual(ll.lat, 10.radians, accuracy: 1e-9)
        // Sensor x axis points up when held in portrait.
        XCTAssertGreaterThan((R * Vec3(1, 0, 0)).y, 0.9)
    }

    func testPairwiseAlignmentRecoversRotation() {
        let scene = SyntheticScene()
        let K = SyntheticRig.intrinsics()
        let Ra = SyntheticRig.portraitRotation(yaw: 0, pitch: 0)
        let Rb = SyntheticRig.portraitRotation(yaw: 32.radians, pitch: 2.radians, roll: 1.radians)
        let a = scene.render(intrinsics: K, rotation: Ra).luminance()
        let b = scene.render(intrinsics: K, rotation: Rb).luminance()
        let noisy = Rb * Mat3.rotation(Vec3(0.02, -0.025, 0.015))
        let aligner = PairwiseAligner()
        let r = aligner.align(i: 0, j: 1, grayI: a, grayJ: b,
                              camI: PanoCamera(intrinsics: K, rotation: Ra),
                              camJ: PanoCamera(intrinsics: K, rotation: noisy))
        XCTAssertNotNil(r)
        guard let r else { return }
        XCTAssertGreaterThan(r.matches.count, 20)
        // Matches must be consistent with the TRUE rotations.
        var maxErr = 0.0
        for m in r.matches {
            maxErr = max(maxErr, (Ra * m.rayI).angle(to: Rb * m.rayJ))
        }
        XCTAssertLessThan(maxErr.degrees, 0.25, "max match error \(maxErr.degrees) deg")
    }

    func testFullSphereStitch() throws {
        let scene = SyntheticScene()
        let K = SyntheticRig.intrinsics()
        let asHeldH = 2 * atan(Double(K.height) / 2 / K.fy)
        let asHeldV = 2 * atan(Double(K.width) / 2 / K.fx)
        let plan = CapturePlan(horizontalFOV: asHeldH, verticalFOV: asHeldV)
        var rng = SplitMix(seed: 7)
        var truth: [Mat3] = []
        var sources: [StitchSource] = []
        for t in plan.targets {
            // The user never hits the target exactly.
            let R = SyntheticRig.portraitRotation(yaw: t.yaw + 2.radians * rng.normal(),
                                                  pitch: t.pitch + 1.5.radians * rng.normal(),
                                                  roll: 3.radians * rng.normal())
            truth.append(R)
            // Sensor rotation error of ~1 degree.
            let noise = Vec3(rng.normal(), rng.normal(), rng.normal()) * 1.0.radians
            let gain = 1 + 0.08 * rng.normal()
            let img = scene.render(intrinsics: K, rotation: R, gain: gain, noise: 0.01, seed: UInt64(t.id + 100))
            sources.append(StitchSource(intrinsics: K, rotation: R * Mat3.rotation(noise), load: { img }))
        }

        var options = StitchOptions()
        options.outputWidth = 2048
        var log: [String] = []
        let result = try Stitcher().stitch(sources, options: options) { stage, p in
            if p == 1 { log.append(stage.rawValue) }
        }
        let rep = result.report
        print("pairs \(rep.pairsAligned)/\(rep.pairsTried), matches \(rep.matches), rms \(rep.rmsBefore) -> \(rep.rmsAfter) px, coverage \(rep.coverage), \(rep.seconds)s")

        // Rotation accuracy up to the global gauge.
        let G = rep.rotations[0] * truth[0].transposed
        var errs: [Double] = []
        for k in 0..<truth.count {
            errs.append((G.transposed * rep.rotations[k] * truth[k].transposed).rotationVector.length.degrees)
        }
        let meanErr = errs.reduce(0, +) / Double(errs.count)
        print("rotation error mean \(meanErr) max \(errs.max()!) deg")
        XCTAssertLessThan(meanErr, 0.1)
        XCTAssertLessThan(errs.max()!, 0.4)
        XCTAssertGreaterThan(rep.coverage, 0.999)

        let gt = scene.equirect(width: result.panorama.width, gauge: G)
        let psnr = TestImageIO.psnr(result.panorama, gt)
        print("PSNR vs ground truth: \(psnr) dB")
        XCTAssertGreaterThan(psnr, 30)

        if let dir = ProcessInfo.processInfo.environment["PANO_TEST_OUTPUT"] {
            TestImageIO.writePPM(result.panorama, to: dir + "/stitched.ppm")
            TestImageIO.writePPM(gt, to: dir + "/truth.ppm")
            TestImageIO.writePPM(try sources[0].load(), to: dir + "/photo0.ppm")
        }
    }
}

final class VignettingTests: XCTestCase {
    func testVignettingIsEstimatedAndRemoved() throws {
        let scene = SyntheticScene()
        let K = SyntheticRig.intrinsics()
        let truthV = Vignette(a: -0.3, b: -0.05)
        let plan = CapturePlan(horizontalFOV: 2 * atan(Double(K.height) / 2 / K.fy),
                               verticalFOV: 2 * atan(Double(K.width) / 2 / K.fx))
        var rng = SplitMix(seed: 3)
        var truth: [Mat3] = []
        var sources: [StitchSource] = []
        for t in plan.targets {
            let R = SyntheticRig.portraitRotation(yaw: t.yaw + 1.5.radians * rng.normal(), pitch: t.pitch, roll: 0)
            truth.append(R)
            var img = scene.render(intrinsics: K, rotation: R, noise: 0.005, seed: UInt64(t.id))
            for y in 0..<K.height { for x in 0..<K.width {
                let f = Float(truthV.factor(r2: Vignette.radius2(u: Double(x), v: Double(y), K: K)))
                for c in 0..<3 { img.data[(y * K.width + x) * 3 + c] *= f }
            } }
            let frozen = img
            sources.append(StitchSource(intrinsics: K, rotation: R, load: { frozen }))
        }
        func run(_ correct: Bool) throws -> (Double, Vignette) {
            var o = StitchOptions()
            o.outputWidth = 2048
            o.correctVignetting = correct
            let res = try Stitcher().stitch(sources, options: o)
            let G = res.report.rotations[0] * truth[0].transposed
            let gt = scene.equirect(width: 2048, gauge: G)
            return (TestImageIO.psnr(res.panorama, gt), res.report.vignette)
        }
        let (off, _) = try run(false)
        let (on, v) = try run(true)
        print("vignetting off \(off) dB, on \(on) dB, estimated a=\(v.a) b=\(v.b), corner factor \(v.factor(r2: 1)) (truth \(truthV.factor(r2: 1)))")
        XCTAssertEqual(v.factor(r2: 1), truthV.factor(r2: 1), accuracy: 0.05)
        XCTAssertEqual(v.factor(r2: 0.5), truthV.factor(r2: 0.5), accuracy: 0.04)
        XCTAssertGreaterThan(on, off + 1)
    }
}
