import Foundation

/// One captured photo handed to the stitcher.
public struct StitchSource: Sendable {
    public var intrinsics: Intrinsics
    /// Sensor (ARKit) camera-to-world rotation at capture time.
    public var rotation: Mat3
    /// Loads the full-resolution RGB image. Called twice (alignment + blending), so the
    /// stitcher never needs to hold all full-size photos in memory at once.
    public var load: @Sendable () throws -> FloatImage
    /// Camera position at capture time (world, metres), e.g. from ARKit tracking.
    public var position: Vec3?
    /// Scene depth for the photo (LiDAR), used together with `position` to remove parallax.
    public var depth: DepthMap?
    /// Monocular relative inverse depth (e.g. Depth Anything V2), scaled to metric depth
    /// using ARKit feature points and triangulated matches.
    public var relativeDepth: RelativeDepth?

    public init(intrinsics: Intrinsics, rotation: Mat3, position: Vec3? = nil, depth: DepthMap? = nil,
                relativeDepth: RelativeDepth? = nil, load: @escaping @Sendable () throws -> FloatImage) {
        self.intrinsics = intrinsics
        self.rotation = rotation
        self.position = position
        self.depth = depth
        self.relativeDepth = relativeDepth
        self.load = load
    }
}

public struct StitchOptions: Sendable {
    /// Width of the equirectangular output (height = width / 2). Rounded to a multiple of 2^levels.
    public var outputWidth: Int = 6144
    public var blendLevels: Int = 5
    public var refineAlignment = true
    public var compensateGain = true
    /// Graph-cut seams that avoid cutting through objects that differ between photos.
    public var graphCutSeams = true
    /// Width of the grid seams are optimized on (height = width / 2).
    public var seamGridWidth = 1536
    /// Use camera positions + depth maps (when present) to compensate parallax.
    public var compensateParallax = true
    /// Re-match all pairs from the refined poses and adjust again (more accurate, ~+30% time).
    public var secondAlignmentPass = true
    /// Estimate and remove lens vignetting (darker photo corners) from the overlaps.
    public var correctVignetting = true
    /// Rotate the result so the first photo is in the middle of the panorama.
    public var centerOnFirstPhoto = true
    public init() {}
}

public enum StitchStage: String, Sendable {
    case preparing = "Preparing photos"
    case aligning = "Aligning photos"
    case optimizing = "Optimizing camera poses"
    case exposure = "Balancing exposure"
    case seams = "Finding seams"
    case depth = "Estimating depth"
    case refining = "Refining alignment"
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
    public var parallaxCompensated = false
    public var depthSources = 0
    /// Robust mean alignment residual (pixels at alignment resolution) per model.
    public var residualRotationOnly = 0.0
    public var residualDepth = 0.0
    public var depthModelUsed = false
    public var depthDroppedPhotos = 0
    public var vignette = Vignette()
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

    /// - Parameter scenePoints: sparse 3D points of the scene in the same world frame as the
    ///   sources' positions (ARKit's tracked feature points). Used to give every photo
    ///   metric depth for parallax compensation, also on iPhones without LiDAR.
    public func stitch(_ sources: [StitchSource], scenePoints: [Vec3] = [], options: StitchOptions = StitchOptions(),
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

        // Panorama centre = mean capture position; each camera keeps its offset from it.
        var offsets = [Vec3](repeating: .zero, count: n)
        let positions = sources.compactMap { $0.position }
        let hasPositions = options.compensateParallax && positions.count == n
        var panoCenter = Vec3.zero
        if hasPositions {
            panoCenter = positions.reduce(Vec3.zero, +) / Double(n)
            offsets = positions.map { $0 - panoCenter }
        }
        var depths: [DepthMap?] = sources.map { options.compensateParallax ? $0.depth : nil }
        func camera(_ k: Int, _ K: Intrinsics, _ R: Mat3) -> PanoCamera {
            PanoCamera(intrinsics: K, rotation: R, offset: offsets[k], depth: depths[k])
        }

        // 1. Load each photo once: grayscale for alignment, small RGB for gain statistics
        //    and seam finding.
        let seamW = max(256, min(options.seamGridWidth, W / 2))
        let seamPxPerRad = Double(seamW) / (2 * .pi)
        var gray = [FloatImage](repeating: FloatImage(width: 1, height: 1, channels: 1), count: n)
        var grayK = [Intrinsics](repeating: sources[0].intrinsics, count: n)
        var thumbs = [FloatImage](repeating: FloatImage(width: 1, height: 1, channels: 3), count: n)
        var thumbK = [Intrinsics](repeating: sources[0].intrinsics, count: n)
        var seamImgs = [FloatImage](repeating: FloatImage(width: 1, height: 1, channels: 3), count: n)
        var seamK = [Intrinsics](repeating: sources[0].intrinsics, count: n)
        for k in 0..<n {
            if isCancelled() { throw StitchError.cancelled }
            let img = try sources[k].load()
            let K = Self.matchIntrinsics(sources[k].intrinsics, to: img)
            var g = img.luminance(), gk = K
            while gk.fx > 900 { g = Pyramid.reduce(g); gk = Self.halved(gk, g) }
            gray[k] = g; grayK[k] = gk
            var t = img, tk = K
            while tk.fx / 2 >= seamPxPerRad * 1.1 { t = Pyramid.reduce(t); tk = Self.halved(tk, t) }
            seamImgs[k] = t; seamK[k] = tk
            while tk.fx > 160 { t = Pyramid.reduce(t); tk = Self.halved(tk, t) }
            thumbs[k] = t; thumbK[k] = tk
            progress?(.preparing, Double(k + 1) / Double(n))
        }

        // 2. Pairwise alignment.
        var rotations = sources.map { $0.rotation.orthonormalized }
        if options.refineAlignment && n > 1 {
            let aligner = PairwiseAligner()
            let cams = (0..<n).map { camera($0, grayK[$0], rotations[$0]) }
            report.pairsTried = aligner.candidatePairs(cameras: cams).count
            let pairs = aligner.alignAll(gray: gray, cameras: cams) { progress?(.aligning, $0) }
            if isCancelled() { throw StitchError.cancelled }
            report.pairsAligned = pairs.count
            var matches = pairs.flatMap { $0.matches }
            report.matches = matches.count

            let sensorRotations = rotations
            let focal = grayK.map { $0.fx }.reduce(0, +) / Double(n)
            func attachPoints() {
                let projectors = (0..<n).map { camera($0, grayK[$0], rotations[$0]).projector }
                for m in 0..<matches.count {
                    let a = matches[m]
                    if let p = grayK[a.i].project(a.rayI) { matches[m].pointI = projectors[a.i].cameraPoint(u: p.u, v: p.v) }
                    if let p = grayK[a.j].project(a.rayJ) { matches[m].pointJ = projectors[a.j].cameraPoint(u: p.u, v: p.v) }
                }
            }
            func bundleAdjust(start: [Mat3]) {
                guard !matches.isEmpty else { return }
                rotations = BundleAdjuster(focal: focal).optimize(initial: sensorRotations, matches: matches,
                                                                   offsets: offsets, start: start).rotations
            }

            // 3. Global bundle adjustment.
            //    a) Rotation-only: the classic model and the safe fallback.
            //    b) Parallax-aware: metric depth per photo (LiDAR / ARKit points / monocular
            //       depth, then points triangulated with refined rotations), each photo's depth
            //       calibrated against the matches, and BA on directions from the panorama centre.
            //    The depth model is kept only where it measurably reduces misalignment.
            progress?(.optimizing, 0)
            let ba = BundleAdjuster(focal: focal)
            let rotOnly = matches.isEmpty ? sensorRotations
                : ba.optimize(initial: sensorRotations, matches: matches, offsets: nil, start: sensorRotations).rotations
            rotations = rotOnly
            let zeroOffsets = [Vec3](repeating: .zero, count: n)
            let rotOnlyResiduals = ba.residuals(rotations: rotOnly, matches: matches, offsets: zeroOffsets)
            report.rmsBefore = ba.residuals(rotations: sensorRotations, matches: matches, offsets: zeroOffsets).robustMean
            report.residualRotationOnly = rotOnlyResiduals.robustMean
            report.rmsAfter = report.residualRotationOnly
            var useDepth = false

            if hasPositions && offsets.contains(where: { $0.length > 0.005 }) && !matches.isEmpty {
                progress?(.depth, 0)
                depths = estimateDepths(sources: sources, cloudRotations: sensorRotations, rotations: rotations,
                                        offsets: offsets, center: panoCenter, scenePoints: scenePoints, matches: [])
                attachPoints()
                bundleAdjust(start: rotOnly)
                progress?(.depth, 0.3)
                depths = estimateDepths(sources: sources, cloudRotations: sensorRotations, rotations: rotations,
                                        offsets: offsets, center: panoCenter, scenePoints: scenePoints, matches: matches)
                attachPoints()
                bundleAdjust(start: rotations)
                progress?(.depth, 0.6)
                for _ in 0..<2 {
                    depths = calibrateDepths(depths, rotations: rotations, offsets: offsets, matches: matches, focal: focal)
                    attachPoints()
                    bundleAdjust(start: rotations)
                }
                // Per-photo validation: drop depth where it makes that photo's matches worse.
                let depthResiduals = ba.residuals(rotations: rotations, matches: matches, offsets: offsets)
                var dropped = 0
                for k in 0..<n where depths[k] != nil {
                    let idx = matches.indices.filter { matches[$0].i == k || matches[$0].j == k }
                    if idx.count < 8 { continue }
                    let withDepth = idx.map { depthResiduals[$0] }.robustMean
                    let without = idx.map { rotOnlyResiduals[$0] }.robustMean
                    if withDepth > without * 1.1 { depths[k] = nil; dropped += 1 }
                }
                if dropped > 0 {
                    attachPoints()
                    bundleAdjust(start: rotations)
                }
                let depthCost = ba.residuals(rotations: rotations, matches: matches, offsets: offsets).robustMean
                report.residualDepth = depthCost
                report.depthDroppedPhotos = dropped
                // Global decision: depth must beat the rotation-only model.
                if depthCost < report.residualRotationOnly * 0.97 {
                    useDepth = true
                    report.rmsAfter = depthCost
                } else {
                    rotations = rotOnly
                }
                report.depthSources = depths.filter { $0 != nil }.count
                progress?(.depth, 1)
            }
            if !useDepth {
                depths = [DepthMap?](repeating: nil, count: n)
            }
            report.depthModelUsed = useDepth

            // 4. Second alignment pass from the refined poses: overlaps now start nearly
            //    aligned (and parallax-corrected), so matching finds more, more accurate
            //    correspondences. Then a final bundle adjustment with the chosen model.
            if options.secondAlignmentPass && !matches.isEmpty {
                progress?(.refining, 0)
                var aligner2 = PairwiseAligner()
                aligner2.config.maxSensorErrorDegrees = 3
                let cams2 = (0..<n).map { camera($0, grayK[$0], rotations[$0]) }
                let pairs2 = aligner2.alignAll(gray: gray, cameras: cams2) { progress?(.refining, $0 * 0.9) }
                if isCancelled() { throw StitchError.cancelled }
                // The new rays were measured against the refined rotations; express them in
                // the sensor-relative form the adjuster expects (rays are camera-frame already).
                var matches2 = pairs2.flatMap { $0.matches }
                if !useDepth {
                    for m in 0..<matches2.count { matches2[m].pointI = nil; matches2[m].pointJ = nil }
                }
                // Both match sets are independent measurements of the same geometry: use both.
                if !useDepth {
                    for m in 0..<matches.count { matches[m].pointI = nil; matches[m].pointJ = nil }
                }
                matches2 += matches
                do {
                    let offs: [Vec3]? = useDepth ? offsets : nil
                    let before = ba.residuals(rotations: rotations, matches: matches2, offsets: offs ?? zeroOffsets).robustMean
                    let refined = ba.optimize(initial: sensorRotations, matches: matches2, offsets: offs, start: rotations).rotations
                    let after = ba.residuals(rotations: refined, matches: matches2, offsets: offs ?? zeroOffsets).robustMean
                    if after <= before {
                        rotations = refined
                        report.rmsAfter = after
                        report.matches = matches2.count
                    }
                }
                progress?(.refining, 1)
            }
            progress?(.optimizing, 1)
        }
        gray = []
        report.parallaxCompensated = depths.contains { $0 != nil } && offsets.contains { $0.length > 1e-4 }

        if options.centerOnFirstPhoto {
            let lon0 = Equirect.lonLat(rotations[0] * Vec3(0, 0, -1)).lon
            let Ry = Mat3.rotation(axis: Vec3(0, 1, 0), angle: lon0)
            rotations = rotations.map { (Ry * $0).orthonormalized }
            offsets = offsets.map { Ry * $0 }
        }
        report.rotations = rotations

        // 4. Gain compensation.
        var gains = [[Float]](repeating: [1, 1, 1], count: n)
        var vignette = Vignette()
        if options.compensateGain && n > 1 {
            progress?(.exposure, 0)
            let cams = (0..<n).map { camera($0, thumbK[$0], rotations[$0]) }
            let res = GainCompensator().compensate(thumbs: thumbs, cameras: cams,
                                                   estimateVignetting: options.correctVignetting)
            gains = res.gains
            vignette = res.vignette
            report.vignette = vignette
            for k in 0..<n { vignette.correct(&seamImgs[k], K: seamK[k]) }
            progress?(.exposure, 1)
        }
        thumbs = []
        report.gains = gains

        // 5. Content-aware seams on a coarse grid.
        let blender = MultiBandBlender(width: W, height: H, levels: levels)
        if options.graphCutSeams && n > 1 {
            progress?(.seams, 0)
            let cams = (0..<n).map { camera($0, seamK[$0], rotations[$0]) }
            let finder = SeamFinder(width: seamW)
            let seams = finder.findSeams(images: seamImgs, cameras: cams, gains: gains, isCancelled: isCancelled)
            blender.setSeamLabels(seams, width: seamW)
            progress?(.seams, 1)
        }
        seamImgs = []
        if isCancelled() { throw StitchError.cancelled }

        // 6. Seam map at full resolution, then multi-band blending one photo at a time.
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
            blender.addToSeamMap(index: k, camera: camera(k, K, rotations[k]))
        }
        blender.prepareBlending()
        for k in 0..<n {
            if isCancelled() { throw StitchError.cancelled }
            var img = try sources[k].load()
            var K = Self.matchIntrinsics(sources[k].intrinsics, to: img)
            while K.fx > blendK[k].fx * 1.01 { img = Pyramid.reduce(img); K = Self.halved(K, img) }
            vignette.correct(&img, K: K)
            blender.blend(index: k, image: img, camera: camera(k, K, rotations[k]), gain: gains[k])
            progress?(.blending, Double(k + 1) / Double(n))
        }
        progress?(.finishing, 0)
        let (pano, coverage) = blender.finish()
        report.coverage = coverage
        report.seconds = Date().timeIntervalSince(start)
        progress?(.finishing, 1)
        return StitchResult(panorama: pano, report: report)
    }

    /// Fuses all depth cues into a metric depth map per photo.
    func estimateDepths(sources: [StitchSource], cloudRotations: [Mat3], rotations: [Mat3], offsets: [Vec3],
                        center: Vec3, scenePoints: [Vec3], matches: [RayMatch]) -> [DepthMap?] {
        let n = sources.count
        var samples = [[DepthSample]](repeating: [], count: n)
        func addSample(_ k: Int, _ X: Vec3, weight: Double, sensorFrame: Bool) {
            // X relative to the panorama centre.
            let c = (sensorFrame ? cloudRotations[k] : rotations[k]).transposed * (X - offsets[k])
            let z = -c.z
            if z < 0.1 || z > 60 { return }
            let K = sources[k].intrinsics
            guard let p = K.project(c), p.u >= 0, p.v >= 0, p.u <= Double(K.width - 1), p.v <= Double(K.height - 1) else { return }
            samples[k].append(DepthSample(u: p.u, v: p.v, z: z, weight: weight))
        }
        // ARKit's tracked feature points.
        for P in scenePoints {
            let X = P - center
            for k in 0..<n { addSample(k, X, weight: 1, sensorFrame: true) }
        }
        // Triangulated matches: the phone's movement between shots is the stereo baseline.
        for m in matches {
            let d1 = rotations[m.i] * m.rayI, d2 = rotations[m.j] * m.rayJ
            guard let X = DepthFusion.triangulate(o1: offsets[m.i], d1: d1, o2: offsets[m.j], d2: d2) else { continue }
            addSample(m.i, X, weight: 1, sensorFrame: false)
            addSample(m.j, X, weight: 1, sensorFrame: false)
        }
        return (0..<n).map { k in
            let K = sources[k].intrinsics
            let fused = DepthFusion.fuse(imageWidth: K.width, imageHeight: K.height, lidar: sources[k].depth,
                                         relative: sources[k].relativeDepth, samples: samples[k])
            return fused ?? sources[k].depth
        }
    }

    /// Per-photo correction of the depth map in inverse depth, 1/z' = α/z + β, chosen to
    /// minimize that photo's match residuals (other photos fixed). This absorbs scale/offset
    /// errors of monocular depth, especially in the far field where they matter most.
    func calibrateDepths(_ depths: [DepthMap?], rotations: [Mat3], offsets: [Vec3], matches: [RayMatch],
                         focal: Double) -> [DepthMap?] {
        let n = depths.count
        var out = depths
        let alphas: [Double] = [0.5, 0.65, 0.8, 0.9, 1.0, 1.1, 1.25, 1.45, 1.7]
        let betas: [Double] = [-0.08, -0.05, -0.03, -0.015, 0, 0.015, 0.03, 0.05, 0.08, 0.12]
        func dir(_ R: Mat3, _ ray: Vec3, _ point: Vec3?, _ off: Vec3) -> Vec3 {
            guard let point else { return R * ray }
            return (R * point + off).normalized
        }
        for k in 0..<n {
            guard let depth = depths[k] else { continue }
            // (own point, other direction) per match involving k.
            var obs: [(Vec3, Vec3)] = []
            for m in matches {
                if m.i == k, let p = m.pointI {
                    obs.append((p, dir(rotations[m.j], m.rayJ, m.pointJ, offsets[m.j])))
                } else if m.j == k, let p = m.pointJ {
                    obs.append((p, dir(rotations[m.i], m.rayI, m.pointI, offsets[m.i])))
                }
            }
            if obs.count < 12 { continue }
            var best = (1.0, 0.0), bestCost = Double.infinity
            for a in alphas {
                for b in betas {
                    var cost = 0.0
                    for (p, other) in obs {
                        let z = -p.z
                        let inv = a / max(z, 0.05) + b
                        let z2 = inv > 1 / Double(DepthMap.far) ? 1 / inv : Double(DepthMap.far)
                        let p2 = p * (z2 / max(z, 1e-6))
                        let e = ((rotations[k] * p2 + offsets[k]).normalized - other).length * focal
                        cost += e <= 2 ? e * e : 4 * e - 4
                    }
                    // Mild preference for no correction.
                    cost += Double(obs.count) * 0.3 * (pow((a - 1) / 0.5, 2) + pow(b / 0.08, 2))
                    if cost < bestCost { bestCost = cost; best = (a, b) }
                }
            }
            if best == (1.0, 0.0) { continue }
            let corrected = depth.data.map { z -> Float in
                let inv = best.0 / max(Double(z), 0.05) + best.1
                return Float(inv > 1 / Double(DepthMap.far) ? 1 / inv : Double(DepthMap.far))
            }
            out[k] = DepthMap(width: depth.width, height: depth.height, depth: corrected)
        }
        return out
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
