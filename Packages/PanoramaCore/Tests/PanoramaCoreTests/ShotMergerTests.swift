import XCTest
@testable import PanoramaCore

final class ShotMergerTests: XCTestCase {
    /// Scene radiance (linear): textured room plus very bright "lamps".
    func radiance(_ d: Vec3, scene: SyntheticScene) -> Vec3 {
        let c = scene.color(d)
        var lin = Vec3(Double(ShotMerger.srgbToLinear(Float(c.x))), Double(ShotMerger.srgbToLinear(Float(c.y))),
                       Double(ShotMerger.srgbToLinear(Float(c.z)))) * 0.6
        for lamp in [Vec3(0.15, 0.1, -1).normalized, Vec3(-0.2, -0.12, -1).normalized] where d.angle(to: lamp) < 4.radians {
            let k = 1 - d.angle(to: lamp) / 4.radians
            lin = lin + Vec3(8, 7, 5) * k   // 10-15x brighter than the room
        }
        return lin
    }

    func render(_ K: Intrinsics, _ R: Mat3, exposure: Double, scene: SyntheticScene, rng: inout SplitMix,
                ghost: Bool = false) -> FloatImage {
        var img = FloatImage(width: K.width, height: K.height, channels: 3)
        for v in 0..<K.height {
            for u in 0..<K.width {
                let d = (R * K.ray(u: Double(u), v: Double(v))).normalized
                var L = radiance(d, scene: scene) * exposure
                if ghost && u > 40 && u < 90 && v > 60 && v < 140 { L = Vec3(0.02, 0.3, 0.02) } // someone walking by
                for c in 0..<3 {
                    let lin = max(0, L[c] + 0.004 * rng.normal())
                    let srgb = lin <= 0.0031308 ? 12.92 * lin : 1.055 * pow(lin, 1 / 2.4) - 0.055
                    img.data[(v * K.width + u) * 3 + c] = Float(min(1, srgb))
                }
            }
        }
        return img
    }

    func testBracketedBurstFusionKeepsHighlightsAndAligns() {
        let scene = SyntheticScene(seed: 9)
        let K = Intrinsics(fx: 300, fy: 300, cx: 159.5, cy: 119.5, width: 320, height: 240)
        var rng = SplitMix(seed: 1)
        let R0 = Mat3.identity
        // Hand tremor between frames (true), and ARKit's slightly wrong estimate of it.
        let trueR = [R0, R0 * Mat3.rotation(Vec3(0.004, -0.003, 0.002)), R0 * Mat3.rotation(Vec3(-0.003, 0.005, -0.001))]
        let sensorR = trueR.enumerated().map { k, R in k == 0 ? R : R * Mat3.rotation(Vec3(0.0015, -0.001, 0)) }
        let exposures = [1.0, 0.25, 2.0]
        var frames: [BurstFrame] = []
        for k in 0..<3 {
            let img = render(K, trueR[k], exposure: exposures[k], scene: scene, rng: &rng, ghost: k == 2)
            frames.append(BurstFrame(image: img, intrinsics: K, rotation: sensorR[k], exposure: exposures[k]))
        }
        let (fused, report) = ShotMerger.merge(frames, reference: 0)

        // Highlights: far fewer clipped pixels than the metered frame.
        func clipped(_ img: FloatImage) -> Int {
            (0..<(img.width * img.height)).filter { img.data[$0 * 3 + 1] > 0.985 }.count
        }
        let c0 = clipped(frames[0].image), cf = clipped(fused)
        print("clipped pixels EV0: \(c0), fused: \(cf); shifts \(report.shifts); sharpness \(report.sharpness)")
        // Lamp cores are clipped even in the darkest frame; the fusion should get close to that.
        let cDark = clipped(frames[1].image)
        print("clipped in darkest frame: \(cDark)")
        XCTAssertGreaterThan(c0, 200)
        XCTAssertLessThan(Double(cf), Double(c0) * 0.5)
        XCTAssertLessThan(Double(cf), Double(cDark) * 1.5 + 50)

        // Alignment: the residual shift found for frame 1 must undo the sensor error
        // (0.0015 rad about x ≈ 0.45 px vertically, -0.001 about y ≈ 0.3 px).
        let s1 = report.shifts[1]
        XCTAssertLessThan(abs(s1.0) + abs(s1.1), 2.0)

        // Alignment: after warping with the found shift, the exposure-normalized frames must
        // match the reference better than with ARKit's rotation alone.
        let refLum = ShotMerger.normalizedLuminance(frames[0].image, exposure: 1)
        for k in 1...2 {
            let (w0, _) = ShotMerger.warp(frames[k], onto: frames[0], shift: (0, 0))
            let (w1, _) = ShotMerger.warp(frames[k], onto: frames[0], shift: report.shifts[k])
            let n0 = ShotMerger.ncc(refLum, ShotMerger.normalizedLuminance(w0, exposure: exposures[k]), (0, 0))
            let n1 = ShotMerger.ncc(refLum, ShotMerger.normalizedLuminance(w1, exposure: exposures[k]), (0, 0))
            print("frame \(k): NCC sensor-only \(n0), refined \(n1)")
            XCTAssertGreaterThanOrEqual(n1, n0 - 1e-6)
        }
        // None of the (equally sharp) frames may be classified as motion-blurred.
        let sMed = report.sharpness.sorted()[1], sMin = report.sharpness.min()!
        XCTAssertGreaterThan(sMin / sMed, 0.35)

        // Ghost: the "person" from frame 2 must not appear in the fused result.
        var green = 0.0
        for v in 70..<130 { for u in 50..<80 { green += Double(fused.data[(v * 320 + u) * 3 + 1] - fused.data[(v * 320 + u) * 3]) } }
        var greenRef = 0.0
        for v in 70..<130 { for u in 50..<80 { greenRef += Double(frames[0].image.data[(v * 320 + u) * 3 + 1] - frames[0].image.data[(v * 320 + u) * 3]) } }
        print("ghost region green excess fused \(green / 1800), reference \(greenRef / 1800)")
        XCTAssertLessThan(green / 1800, greenRef / 1800 + 0.08)
    }
}

extension ShotMergerTests {
    func testMotionBlurredFrameIsDetected() {
        // Detailed texture (like a real photo at full resolution): value noise at 2-6 px scale.
        var rng = SplitMix(seed: 5)
        var sharpImg = FloatImage(width: 320, height: 240, channels: 3)
        let cells = (0..<(80 * 60)).map { _ in Float(rng.uniform()) }
        for y in 0..<240 { for x in 0..<320 {
            let v = 0.25 + 0.5 * cells[(y / 4) * 80 + x / 4] * 0.7 + 0.15 * Float(sin(Double(x) * 0.9) * cos(Double(y) * 0.7))
            for c in 0..<3 { sharpImg.data[(y * 320 + x) * 3 + c] = v }
        } }
        // Horizontal motion blur over 9 px.
        var blurred = sharpImg
        for y in 0..<240 { for x in 0..<320 { for c in 0..<3 {
            var acc: Float = 0
            for d in -4...4 { acc += sharpImg.data[(y * 320 + min(319, max(0, x + d))) * 3 + c] }
            blurred.data[(y * 320 + x) * 3 + c] = acc / 9
        } } }
        let s = ShotMerger.jointSharpness([sharpImg, sharpImg, blurred], exposures: [1, 1, 1])
        print("sharpness sharp/blurred: \(s)")
        XCTAssertLessThan(s[2] / s[0], 0.35)
    }
}
