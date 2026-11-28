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

extension ShotMergerTests {
    /// Two overlapping shots, one with the bright lamp in frame and one without, merged
    /// separately, must agree in their overlap. Shot-local tone mapping (e.g. Mertens
    /// fusion) breaks this and shows up as brightness blocks in the panorama.
    func testMergedShotsAreConsistentAcrossShots() {
        let scene = SyntheticScene(seed: 9)
        let K = Intrinsics(fx: 300, fy: 300, cx: 159.5, cy: 119.5, width: 320, height: 240)
        var rng = SplitMix(seed: 12)
        func burst(_ R: Mat3) -> FloatImage {
            let exposures = [1.0, 1.0, 0.25, 0.0625]
            let frames = exposures.map { e in
                BurstFrame(image: render(K, R, exposure: e, scene: scene, rng: &rng), intrinsics: K, rotation: R, exposure: e)
            }
            return ShotMerger.merge(frames).0
        }
        let Ra = Mat3.identity
        let Rb = Mat3.rotation(axis: Vec3(0, 1, 0), angle: -0.35) // ~20 degrees to the right
        let a = burst(Ra), b = burst(Rb)
        // Warp b into a's geometry and compare where both are valid and not clipped.
        let (bw, ok) = ShotMerger.warp(BurstFrame(image: b, intrinsics: K, rotation: Rb, exposure: 1),
                                        onto: BurstFrame(image: a, intrinsics: K, rotation: Ra, exposure: 1), shift: (0, 0))
        var diff = 0.0, n = 0.0
        for i in 0..<(320 * 240) where ok[i] {
            let va = a.data[i * 3 + 1], vb = bw.data[i * 3 + 1]
            if va > 0.97 || vb > 0.97 { continue }
            diff += Double(abs(va - vb)); n += 1
        }
        print("overlap pixels \(Int(n)), mean |difference| \(diff / max(n, 1))")
        XCTAssertGreaterThan(n, 5000)
        XCTAssertLessThan(diff / n, 0.02)
    }

    func testHighlightCurveIsMonotonicAndIdentityInMidtones() {
        let c = HighlightCurve.standard
        XCTAssertEqual(c.map(0.18), 0.18, accuracy: 1e-6)
        XCTAssertEqual(c.map(0.45), 0.45, accuracy: 1e-5)
        var last: Float = -1
        for i in 0...400 {
            let x = Float(i) / 25
            let y = c.map(x)
            XCTAssertGreaterThanOrEqual(y, last)
            last = y
        }
        XCTAssertLessThan(c.map(1), 0.75)      // former white keeps headroom
        XCTAssertGreaterThan(c.map(8), 0.9)    // +3 EV bright but below white
        XCTAssertLessThan(c.map(4), c.map(8))  // and distinguishable
    }
}

extension ShotMergerTests {
    func testCurveInverse() {
        let c = HighlightCurve.standard
        for x in stride(from: Float(0), through: 12, by: 0.37) {
            XCTAssertEqual(c.inverse(c.map(x)), x, accuracy: max(0.002, x * 0.01))
        }
    }

    /// A panorama without real highlights must come back unchanged (no washed-out whites).
    func testRetoneWithoutHighlightsIsIdentity() {
        var rng = SplitMix(seed: 2)
        let W = 64, H = 32
        let radiance = FloatImage(width: W, height: H, channels: 3,
                                  data: (0..<(W * H * 3)).map { _ in Float(rng.uniform()) * 0.95 })
        var encoded = HighlightCurve.standard.apply(radiance)
        PanoramaToneMapper.retone(&encoded, encodedWith: .standard)
        var maxErr: Float = 0
        for i in 0..<radiance.data.count {
            maxErr = max(maxErr, abs(encoded.data[i] - ShotMerger.linearToSRGB(radiance.data[i])))
        }
        print("retone identity max error \(maxErr)")
        XCTAssertLessThan(maxErr, 0.03)
    }

    /// With real highlights the result keeps them below white and mid-tones near the original.
    func testRetoneWithHighlights() {
        let W = 100, H = 10
        var radiance = FloatImage(width: W, height: H, channels: 3)
        for i in 0..<(W * H) {
            let v: Float = i % 100 < 90 ? 0.18 : 6.0   // 10% very bright sky
            radiance.data[i * 3] = v; radiance.data[i * 3 + 1] = v; radiance.data[i * 3 + 2] = v
        }
        var encoded = HighlightCurve.standard.apply(radiance)
        PanoramaToneMapper.retone(&encoded, encodedWith: .standard)
        XCTAssertEqual(encoded.data[0], ShotMerger.linearToSRGB(0.18), accuracy: 0.02)   // mid-grey unchanged
        XCTAssertLessThan(encoded.data[95 * 3], 1.0)                                         // highlight not clipped
        XCTAssertGreaterThan(encoded.data[95 * 3], 0.9)
    }
}

extension ShotMergerTests {
    func testHDRRadianceEncodingRoundTrip() {
        let vals: [Float] = [0, 0.0003, 0.01, 0.18, 1, 7.5, 900]
        let img = FloatImage(width: vals.count, height: 1, channels: 3, data: vals.flatMap { [$0, $0, $0] })
        let back = HDRRadiance.decode(HDRRadiance.encode(img), width: vals.count, height: 1)
        for (i, v) in vals.enumerated() {
            XCTAssertEqual(back.data[i * 3], v, accuracy: max(1e-6, v * 0.001))
        }
    }

    /// Dark start point and a much brighter side: after the common exposure scaling, the
    /// panorama-wide mapping keeps mid-tones near grey and the bright side below white.
    func testPanoramaToneMappingHandlesWideRange() {
        // Shot A (dark interior) median 0.02, p999 0.3; shot B (sunny side) median 2, p999 40.
        let (gain, curve) = HDRRadiance.panoramaToneMapping(shots: [(0.02, 0.3), (0.05, 0.8), (2.0, 40)])
        let mid = curve.map(0.05 * gain)
        let sky = curve.map(40 * gain)
        print("gain \(gain), maxInput \(curve.maxInput), interior \(ShotMerger.linearToSRGB(curve.map(0.02 * gain))), sky \(ShotMerger.linearToSRGB(sky))")
        XCTAssertGreaterThan(ShotMerger.linearToSRGB(mid), 0.3)
        XCTAssertLessThan(sky, 1.0)
    }
}

