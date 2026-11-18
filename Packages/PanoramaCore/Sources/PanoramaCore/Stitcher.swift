import Foundation

/// One captured photo handed to the stitcher.
public struct StitchSource: Sendable {
    public var intrinsics: Intrinsics
    /// Sensor (ARKit) camera-to-world rotation at capture time.
    public var rotation: Mat3
    /// Loads the full-resolution RGB image. Called twice (alignment + blending), so the
    /// stitcher never needs to hold all full-size photos in memory at once.
    public var load: @Sendable () throws -> FloatImage

    public init(intrinsics: Intrinsics, rotation: Mat3, load: @escaping @Sendable () throws -> FloatImage) {
        self.intrinsics = intrinsics
        self.rotation = rotation
        self.load = load
    }
}

public struct StitchOptions: Sendable {
    /// Width of the equirectangular output (height = width / 2). Rounded to a multiple of 2^levels.
    public var outputWidth: Int = 6144
    public var blendLevels: Int = 5
    public var refineAlignment = true
    public var compensateGain = true
    /// Rotate the result so the first photo is in the middle of the panorama.
    public var centerOnFirstPhoto = true
    public init() {}
}

public enum StitchStage: String, Sendable {
    case preparing = "Preparing photos"
    case aligning = "Aligning photos"
    case optimizing = "Optimizing camera poses"
    case exposure = "Balancing exposure"
    case blending = "Blending"
    case finishing = "Finishing"
}

public struct StitchReport: Sendable {
    public var pairsTried = 0
    public var pairsAligned = 0
    public var matches = 0
    public var rmsBefore = 0.0
    public var rmsAfter = 0.0
    public var coverage = 0.0
    public var rotations: [Mat3] = []
    public var gains: [[Float]] = []
    public var seconds = 0.0
}

public struct StitchResult: Sendable {
    public var panorama: FloatImage
    public var report: StitchReport
}

public enum StitchError: Error {
    case noImages
    case tooManyImages
    case cancelled
}

/// The full pipeline: sensor-guided pairwise alignment → rotation bundle adjustment →
/// gain compensation → max-weight seams → multi-band blending → equirectangular output.
public final class Stitcher: @unchecked Sendable {
    public typealias Progress = (StitchStage, Double) -> Void
    public var isCancelled: () -> Bool = { false }

    public init() {}

    public func stitch(_ sources: [StitchSource], options: StitchOptions = StitchOptions(),
                       progress: Progress? = nil) throws -> StitchResult {
        let start = Date()
        guard !sources.isEmpty else { throw StitchError.noImages }
        guard sources.count < 255 else { throw StitchError.tooManyImages }
        var report = StitchReport()
        let n = sources.count

        let levels = options.blendLevels
        let align = 1 << (levels + 1)
        let W = max(align, (options.outputWidth / align) * align)
        let H = W / 2
        let outPxPerRad = Double(W) / (2 * .pi)

        // 1. Load each photo once: grayscale for alignment + tiny RGB for gain statistics.
        var gray = [FloatImage](repeating: FloatImage(width: 1, height: 1, channels: 1), count: n)
        var grayK = [Intrinsics](repeating: sources[0].intrinsics, count: n)
        var thumbs = [FloatImage](repeating: FloatImage(width: 1, height: 1, channels: 3), count: n)
        var thumbK = [Intrinsics](repeating: sources[0].intrinsics, count: n)
        for k in 0..<n {
            if isCancelled() { throw StitchError.cancelled }
            let img = try sources[k].load()
            let K = Self.matchIntrinsics(sources[k].intrinsics, to: img)
            var g = img.luminance(), gk = K
            while gk.fx > 900 { g = Pyramid.reduce(g); gk = Self.halved(gk, g) }
            gray[k] = g; grayK[k] = gk
            var t = img, tk = K
            while tk.fx > 160 { t = Pyramid.reduce(t); tk = Self.halved(tk, t) }
            thumbs[k] = t; thumbK[k] = tk
            progress?(.preparing, Double(k + 1) / Double(n))
        }

        // 2. Pairwise alignment.
        var rotations = sources.map { $0.rotation.orthonormalized }
        if options.refineAlignment && n > 1 {
            let aligner = PairwiseAligner()
            let cams = (0..<n).map { PanoCamera(intrinsics: grayK[$0], rotation: rotations[$0]) }
            report.pairsTried = aligner.candidatePairs(cameras: cams).count
            let pairs = aligner.alignAll(gray: gray, cameras: cams) { progress?(.aligning, $0) }
            if isCancelled() { throw StitchError.cancelled }
            report.pairsAligned = pairs.count
            let matches = pairs.flatMap { $0.matches }
            report.matches = matches.count

            // 3. Global bundle adjustment.
            progress?(.optimizing, 0)
            if !matches.isEmpty {
                let focal = grayK.map { $0.fx }.reduce(0, +) / Double(n)
                let ba = BundleAdjuster(focal: focal)
                let res = ba.optimize(initial: rotations, matches: matches)
                rotations = res.rotations
                report.rmsBefore = res.initialRMS
                report.rmsAfter = res.finalRMS
            }
            progress?(.optimizing, 1)
        }
        gray = []

        if options.centerOnFirstPhoto {
            let lon0 = Equirect.lonLat(rotations[0] * Vec3(0, 0, -1)).lon
            let Ry = Mat3.rotation(axis: Vec3(0, 1, 0), angle: lon0)
            rotations = rotations.map { (Ry * $0).orthonormalized }
        }
        report.rotations = rotations

        // 4. Gain compensation.
        var gains = [[Float]](repeating: [1, 1, 1], count: n)
        if options.compensateGain && n > 1 {
            progress?(.exposure, 0)
            let cams = (0..<n).map { PanoCamera(intrinsics: thumbK[$0], rotation: rotations[$0]) }
            gains = GainCompensator().gains(thumbs: thumbs, cameras: cams)
            progress?(.exposure, 1)
        }
        thumbs = []
        report.gains = gains

        // 5. Seams, then multi-band blending one photo at a time.
        let blender = MultiBandBlender(width: W, height: H, levels: levels)
        var blendK = [Intrinsics]()
        for k in 0..<n {
            var K = sources[k].intrinsics
            // Pre-filter: never sample a photo at much more than the output resolution (avoids aliasing).
            var f = K.fx
            var halvings = 0
            while f / 2 >= outPxPerRad * 1.2 { f /= 2; halvings += 1 }
            for _ in 0..<halvings {
                K = Intrinsics(fx: K.fx / 2, fy: K.fy / 2, cx: K.cx / 2, cy: K.cy / 2,
                               width: (K.width + 1) / 2, height: (K.height + 1) / 2)
            }
            blendK.append(K)
            blender.addToSeamMap(index: k, camera: PanoCamera(intrinsics: K, rotation: rotations[k]))
        }
        blender.prepareBlending()
        for k in 0..<n {
            if isCancelled() { throw StitchError.cancelled }
            var img = try sources[k].load()
            var K = Self.matchIntrinsics(sources[k].intrinsics, to: img)
            while K.fx > blendK[k].fx * 1.01 { img = Pyramid.reduce(img); K = Self.halved(K, img) }
            blender.blend(index: k, image: img, camera: PanoCamera(intrinsics: K, rotation: rotations[k]), gain: gains[k])
            progress?(.blending, Double(k + 1) / Double(n))
        }
        progress?(.finishing, 0)
        let (pano, coverage) = blender.finish()
        report.coverage = coverage
        report.seconds = Date().timeIntervalSince(start)
        progress?(.finishing, 1)
        return StitchResult(panorama: pano, report: report)
    }

    /// Intrinsics after a pyramid REDUCE (pixel m of the new image is centred on pixel 2m).
    static func halved(_ K: Intrinsics, _ img: FloatImage) -> Intrinsics {
        Intrinsics(fx: K.fx / 2, fy: K.fy / 2, cx: K.cx / 2, cy: K.cy / 2, width: img.width, height: img.height)
    }

    /// Adapts intrinsics if the loaded image's size differs from the declared one.
    static func matchIntrinsics(_ K: Intrinsics, to img: FloatImage) -> Intrinsics {
        if K.width == img.width && K.height == img.height { return K }
        return K.scaled(toWidth: img.width, height: img.height)
    }
}
