import XCTest
@testable import PanoramaCore

/// Runs the full pipeline at the phone's output size (8192 x 4096, 7 blend levels) with
/// positions + monocular depth, to catch crashes that only show at full resolution.
final class FullResolutionTests: XCTestCase {
    func testFullResolutionWithDepth() throws {
        guard ProcessInfo.processInfo.environment["PANO_FULLRES"] != nil else { throw XCTSkip("set PANO_FULLRES=1") }
        let scene = ParallaxScene()
        let K = SyntheticRig.intrinsics()
        let plan = CapturePlan(horizontalFOV: 2 * atan(Double(K.height) / 2 / K.fy),
                               verticalFOV: 2 * atan(Double(K.width) / 2 / K.fx))
        var rng = SplitMix(seed: 5)
        var sources: [StitchSource] = []
        for t in plan.targets {
            let R = SyntheticRig.portraitRotation(yaw: t.yaw, pitch: t.pitch, roll: 0)
            let pos = R * Vec3(0, 0, -0.1)
            let (img, depth) = scene.render(K: K, R: R, position: pos)
            let rel = RelativeDepth(width: depth.width, height: depth.height, values: depth.data.map { 1 / $0 })
            sources.append(StitchSource(intrinsics: K, rotation: R * Mat3.rotation(Vec3(rng.normal(), rng.normal(), rng.normal()) * 0.01),
                                        position: pos, relativeDepth: rel, load: { img }))
        }
        var o = StitchOptions()
        o.outputWidth = 8192
        let res = try Stitcher().stitch(sources, scenePoints: [], options: o)
        print("8192 ok: \(res.panorama.width)x\(res.panorama.height), coverage \(res.report.coverage), \(res.report.seconds)s")
        XCTAssertEqual(res.panorama.width, 8192)
    }
}
