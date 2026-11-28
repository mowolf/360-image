import Foundation

/// One frame of a per-target burst.
public struct BurstFrame: Sendable {
    public var image: FloatImage      // display-referred sRGB, 0...1
    public var intrinsics: Intrinsics // for this image's size
    public var rotation: Mat3         // camera-to-world (ARKit)
    /// Relative linear exposure (exposure time × ISO); only ratios matter.
    public var exposure: Double

    public init(image: FloatImage, intrinsics: Intrinsics, rotation: Mat3, exposure: Double) {
        self.image = image
        self.intrinsics = intrinsics
        self.rotation = rotation
        self.exposure = exposure
    }
}

/// Merges an exposure-bracketed burst taken at one capture target into a single photo:
///
/// 1. **Alignment.** Each frame is warped onto the reference with the rotation-only
///    homography from ARKit's poses, then a residual shift is found by coarse-to-fine NCC
///    on exposure-normalized luminance (hand tremor, rolling shutter).
/// 2. **Radiance merge** (Debevec & Malik style, with measured exposure ratios). All
///    frames are linearized and divided by their exposure, so they estimate the same scene
///    radiance. They are averaged with weights that avoid clipped and noisy values; ghosts
///    (anything that moved) and motion-blurred frames are suppressed.
/// 3. **Global highlight curve.** One fixed tone curve (identity in mid-tones, a soft
///    shoulder for highlights up to +4 EV) is applied to every photo. Exposure is locked
///    during capture, so overlapping photos map the same sky to the same values: no local
///    tone mapping that differs from shot to shot and shows up as blocks in the panorama.
public enum ShotMerger {
    public struct Report: Sendable {
        public var shifts: [(Double, Double)] = []
        public var sharpness: [Double] = []
        public var exposures: [Double] = []
        public var reference = 0
    }

    /// - Parameter reference: index of the frame defining the output geometry (normally the
    ///   metered EV0 frame). Returns an image with the reference frame's size and intrinsics.
    /// Merged burst encoded for display with the fixed `HighlightCurve.standard`.
    public static func merge(_ frames: [BurstFrame], reference: Int = 0,
                             allowReferenceSwitch: Bool = false) -> (FloatImage, Report) {
        guard frames.count > 1 else { return (frames.first?.image ?? FloatImage(width: 1, height: 1, channels: 3), Report()) }
        let (radiance, report) = mergeRadiance(frames, reference: reference, allowReferenceSwitch: allowReferenceSwitch)
        return (HighlightCurve.standard.apply(radiance), report)
    }

    /// Merged burst as linear scene radiance, relative to the reference frame's exposure
    /// (1.0 = white in the reference frame). A single frame is simply linearized.
    public static func mergeRadiance(_ frames: [BurstFrame], reference: Int = 0,
                                     allowReferenceSwitch: Bool = false) -> (FloatImage, Report) {
        var report = Report()
        guard frames.count > 1 else {
            return (linearize(frames.first?.image ?? FloatImage(width: 1, height: 1, channels: 3)), report)
        }
        var r = reference
        // Optionally let a clearly sharper same-exposure frame define the geometry. Callers that
        // enable this must use `report.reference`'s pose and intrinsics for the result.
        let sameExposure = frames.indices.filter { abs(log(frames[$0].exposure / frames[r].exposure)) < 0.1 }
        if allowReferenceSwitch && sameExposure.count > 1 {
            let s = jointSharpness(sameExposure.map { frames[$0].image }, exposures: sameExposure.map { frames[$0].exposure })
            if let best = s.indices.max(by: { s[$0] < s[$1] }), s[best] > 1.25 * s[sameExposure.firstIndex(of: r)!] {
                r = sameExposure[best]
            }
        }
        report.reference = r
        let ref = frames[r]
        let W = ref.image.width, H = ref.image.height

        // 1. Align all frames onto the reference.
        var aligned: [FloatImage] = []
        var valid: [[Bool]] = []
        let refLum = normalizedLuminance(ref.image, exposure: ref.exposure)
        for (k, f) in frames.enumerated() {
            if k == r {
                aligned.append(f.image)
                valid.append([Bool](repeating: true, count: W * H))
                report.shifts.append((0, 0))
                continue
            }
            let (warped0, _) = warp(f, onto: ref, shift: (0, 0))
            let lum = normalizedLuminance(warped0, exposure: f.exposure)
            let shift = estimateShift(refLum, lum, width: W, height: H)
            report.shifts.append(shift)
            let (warped, ok) = warp(f, onto: ref, shift: shift)
            aligned.append(warped)
            valid.append(ok)
        }

        // 2. Sharpness of each frame (exposure-normalized gradient energy on mid-tones).
        let sharp = jointSharpness(aligned, exposures: frames.map(\.exposure))
        report.sharpness = sharp
        let medianSharp = max(sharp.sorted()[sharp.count / 2], 1e-12)

        // Measured exposure ratios (the camera pipeline may not apply exactly what was
        // requested): median of linear-light ratios over pixels well exposed in both frames.
        let refLin = linearize(ref.image)
        var exposures = frames.map(\.exposure)
        for k in 0..<frames.count where k != r {
            let lin = linearize(aligned[k])
            var ratios: [Float] = []
            var i = 0
            while i < W * H {
                if valid[k][i] {
                    let a = aligned[k].data[i * 3 + 1], b = ref.image.data[i * 3 + 1]
                    if a > 0.08 && a < 0.85 && b > 0.08 && b < 0.85 {
                        ratios.append(lin.data[i * 3 + 1] / max(refLin.data[i * 3 + 1], 1e-5))
                    }
                }
                i += 7
            }
            if ratios.count > 300 {
                ratios.sort()
                exposures[k] = ref.exposure * Double(ratios[ratios.count / 2])
            }
        }
        report.exposures = exposures

        // 3. Radiance merge. Every frame is converted to linear light and divided by its
        //    measured exposure, so all frames estimate the same scene radiance; they are
        //    averaged with weights that avoid clipped and noisy values. Ghosts (anything that
        //    moved) are rejected against the reference, blurred frames are down-weighted.
        let lins = aligned.map { linearize($0) }
        let ratios = exposures.map { Float($0 / ref.exposure) }
        let blurFactors: [Float] = (0..<frames.count).map { k in
            let r0 = sharp[k] / medianSharp
            return Float(r0 < 0.35 ? pow(r0 / 0.35, 2) : 1)
        }
        let darkest = ratios.indices.min { ratios[$0] < ratios[$1] } ?? r
        var radiance = FloatImage(width: W, height: H, channels: 3)
        radiance.data.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: H) { y in
                for x in 0..<W {
                    let i = y * W + x
                    let refMax = max(aligned[r].data[i * 3], aligned[r].data[i * 3 + 1], aligned[r].data[i * 3 + 2])
                    let refClipped = refMax > 0.96
                    var acc: (Float, Float, Float) = (0, 0, 0)
                    var wsum: Float = 0
                    for k in 0..<frames.count where valid[k][i] {
                        let img = aligned[k].data
                        let vmax = max(img[i * 3], img[i * 3 + 1], img[i * 3 + 2])
                        // Hat weight: trust mid-tones, fade out towards clipping and black.
                        var w: Float = vmax > 0.96 ? 0 : (vmax > 0.85 ? (0.96 - vmax) / 0.11 : 1)
                        if vmax < 0.04 { w *= max(0.05, vmax / 0.04) }
                        w *= sqrtf(ratios[k]) * blurFactors[k] // longer exposures are less noisy
                        if w <= 0 { continue }
                        let inv = 1 / ratios[k]
                        let l0 = lins[k].data[i * 3] * inv, l1 = lins[k].data[i * 3 + 1] * inv, l2 = lins[k].data[i * 3 + 2] * inv
                        if k != r && !refClipped && refMax > 0.04 {
                            let ly = 0.2126 * l0 + 0.7152 * l1 + 0.0722 * l2
                            let ry = 0.2126 * lins[r].data[i * 3] + 0.7152 * lins[r].data[i * 3 + 1] + 0.0722 * lins[r].data[i * 3 + 2]
                            if abs(logf(max(ly, 1e-4)) - logf(max(ry, 1e-4))) > 0.35 { w *= 0.02 }
                        }
                        acc.0 += w * l0; acc.1 += w * l1; acc.2 += w * l2
                        wsum += w
                    }
                    if wsum < 1e-6 {
                        // Clipped in every frame (e.g. the sun): use the darkest frame as is.
                        let k = valid[darkest][i] ? darkest : r
                        let inv = 1 / ratios[k]
                        out[i * 3] = lins[k].data[i * 3] * inv
                        out[i * 3 + 1] = lins[k].data[i * 3 + 1] * inv
                        out[i * 3 + 2] = lins[k].data[i * 3 + 2] * inv
                    } else {
                        out[i * 3] = acc.0 / wsum; out[i * 3 + 1] = acc.1 / wsum; out[i * 3 + 2] = acc.2 / wsum
                    }
                }
            }
        }

        // 4. The same global highlight curve for every photo of the panorama (exposure is
        //    locked during capture), so overlapping photos stay consistent for blending.
        return (radiance, report)
    }

    // MARK: - Helpers

    @inline(__always) public static func linearToSRGB(_ v: Float) -> Float {
        let x = max(0, min(1, v))
        return x <= 0.0031308 ? 12.92 * x : 1.055 * powf(x, 1 / 2.4) - 0.055
    }

    @inline(__always) public static func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    static func linearize(_ img: FloatImage) -> FloatImage {
        var out = img
        for i in 0..<out.data.count { out.data[i] = srgbToLinear(out.data[i]) }
        return out
    }

    /// Luminance in linear light divided by exposure, then back to a perceptual scale, so
    /// frames with different exposures look alike for registration.
    static func normalizedLuminance(_ img: FloatImage, exposure: Double) -> FloatImage {
        var out = FloatImage(width: img.width, height: img.height, channels: 1)
        let inv = Float(1 / exposure)
        for i in 0..<(img.width * img.height) {
            let l = 0.2126 * srgbToLinear(img.data[i * 3]) + 0.7152 * srgbToLinear(img.data[i * 3 + 1])
                + 0.0722 * srgbToLinear(img.data[i * 3 + 2])
            out.data[i] = powf(max(l * inv, 0), 1 / 2.2)
        }
        return out
    }

    /// Blur score per frame: gradient energy at full resolution divided by gradient energy
    /// two pyramid levels down, on pixels that are mid-tone in *all* frames. Motion blur
    /// removes the fine scale but not the coarse one; exposure and tone-curve differences
    /// between frames cancel in the ratio.
    static func jointSharpness(_ imgs: [FloatImage], exposures: [Double]) -> [Double] {
        let grays = imgs.map { $0.luminance() }
        let coarse = grays.map { Pyramid.reduce(Pyramid.reduce($0)) }
        let W = grays[0].width, H = grays[0].height
        let cw = coarse[0].width, chh = coarse[0].height
        var fine = [Double](repeating: 0, count: imgs.count)
        var low = [Double](repeating: 0, count: imgs.count)
        for y in 1..<(chh - 1) {
            for x in 1..<(cw - 1) {
                let i = y * cw + x
                var ok = true
                for c in coarse where c.data[i] < 0.05 || c.data[i] > 0.9 { ok = false; break }
                if !ok { continue }
                for k in 0..<imgs.count {
                    let l = coarse[k].data
                    let gx = l[i + 1] - l[i - 1], gy = l[i + cw] - l[i - cw]
                    low[k] += Double(gx * gx + gy * gy)
                    // The 4x4 block of full-resolution pixels under this coarse pixel.
                    let g = grays[k].data
                    for yy in (4 * y)..<min(H - 1, 4 * y + 4) {
                        for xx in (4 * x)..<min(W - 1, 4 * x + 4) {
                            let j = yy * W + xx
                            let fx = g[j + 1] - g[j], fy = g[j + W] - g[j]
                            fine[k] += Double(fx * fx + fy * fy) / 16
                        }
                    }
                }
            }
        }
        return (0..<imgs.count).map { low[$0] > 0 ? fine[$0] / low[$0] : 0 }
    }

    /// Warps frame `f` into the reference frame's pixel grid using the rotation-only
    /// homography plus an extra pixel shift.
    static func warp(_ f: BurstFrame, onto ref: BurstFrame, shift: (Double, Double)) -> (FloatImage, [Bool]) {
        let W = ref.image.width, H = ref.image.height
        let Kr = ref.intrinsics, Kf = f.intrinsics
        let M = f.rotation.transposed * ref.rotation
        var out = FloatImage(width: W, height: H, channels: 3)
        var ok = [Bool](repeating: false, count: W * H)
        let sx = Double(f.image.width) / Double(Kf.width), sy = Double(f.image.height) / Double(Kf.height)
        f.image.data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                ok.withUnsafeMutableBufferPointer { o in
                    DispatchQueue.concurrentPerform(iterations: H) { y in
                        for x in 0..<W {
                            let u = Double(x) * Double(Kr.width) / Double(W) + shift.0
                            let v = Double(y) * Double(Kr.height) / Double(H) + shift.1
                            guard let p = Kf.project(M * Kr.ray(u: u, v: v)) else { continue }
                            let px = p.u * sx, py = p.v * sy
                            let i = y * W + x
                            if px >= 0 && py >= 0 && px <= Double(f.image.width - 1) && py <= Double(f.image.height - 1) {
                                o[i] = true
                            }
                            FloatImage.sampleBilinear(src, width: f.image.width, height: f.image.height, channels: 3,
                                                      x: px, y: py, out: dst.baseAddress! + i * 3)
                        }
                    }
                }
            }
        }
        return (out, ok)
    }

    /// Coarse-to-fine NCC search for the translation that best aligns `b` to `a`
    /// (both single-channel, same size). Returns (dx, dy) in full-resolution pixels to add
    /// to reference coordinates when sampling `b`'s source.
    static func estimateShift(_ a: FloatImage, _ b: FloatImage, width W: Int, height H: Int) -> (Double, Double) {
        let levels = max(0, min(5, Int(log2(Double(min(W, H)) / 96))))
        let pa = Pyramid.gaussian(a, levels: levels), pb = Pyramid.gaussian(b, levels: levels)
        var best = (0, 0)
        for l in stride(from: levels, through: 0, by: -1) {
            let r = l == levels ? 6 : 2
            let center = l == levels ? (0, 0) : (best.0 * 2, best.1 * 2)
            var bestScore = -Double.infinity
            var bestShift = center
            var scores: [String: Double] = [:]
            for dy in -r...r {
                for dx in -r...r {
                    let s = (center.0 + dx, center.1 + dy)
                    let sc = ncc(pa[l], pb[l], s)
                    scores["\(s.0),\(s.1)"] = sc
                    if sc > bestScore { bestScore = sc; bestShift = s }
                }
            }
            best = bestShift
            if l == 0 {
                // Sub-pixel refinement with parabola fits.
                func sc(_ x: Int, _ y: Int) -> Double { scores["\(x),\(y)"] ?? ncc(pa[0], pb[0], (x, y)) }
                let c = sc(best.0, best.1)
                let dxDen = sc(best.0 - 1, best.1) - 2 * c + sc(best.0 + 1, best.1)
                let dyDen = sc(best.0, best.1 - 1) - 2 * c + sc(best.0, best.1 + 1)
                var fx = 0.0, fy = 0.0
                if dxDen < 0 { fx = max(-0.5, min(0.5, 0.5 * (sc(best.0 - 1, best.1) - sc(best.0 + 1, best.1)) / dxDen)) }
                if dyDen < 0 { fy = max(-0.5, min(0.5, 0.5 * (sc(best.0, best.1 - 1) - sc(best.0, best.1 + 1)) / dyDen)) }
                // b(x + s) ≈ a(x): sample the source at reference + s.
                return (Double(best.0) + fx, Double(best.1) + fy)
            }
        }
        return (Double(best.0), Double(best.1))
    }

    /// NCC between a(x) and b(x + s) over the overlap (subsampled for large images).
    static func ncc(_ a: FloatImage, _ b: FloatImage, _ s: (Int, Int)) -> Double {
        let W = a.width, H = a.height
        let step = max(1, min(W, H) / 192)
        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        var y = max(0, -s.1) + 2
        while y < min(H, H - s.1) - 2 {
            var x = max(0, -s.0) + 2
            while x < min(W, W - s.0) - 2 {
                let va = Double(a.data[y * W + x]), vb = Double(b.data[(y + s.1) * W + x + s.0])
                n += 1; sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb
                x += step
            }
            y += step
        }
        if n < 20 { return -1 }
        let cov = sab - sa * sb / n, va = saa - sa * sa / n, vb = sbb - sb * sb / n
        if va <= 1e-12 || vb <= 1e-12 { return -1 }
        return cov / (va * vb).squareRoot()
    }
}

/// Global tone curve for merged HDR radiance (linear, 1.0 = white at the locked exposure).
/// Identity below `knee`; above it a smooth logarithmic shoulder compresses up to `maxInput`
/// (the darkest bracket's range) into the remaining headroom with matching slope at the
/// knee. Applied to luminance with hue preserved, then gently desaturated towards white
/// where a channel would clip.
public struct HighlightCurve: Sendable {
    public let knee: Float
    public let maxInput: Float
    private let c: Float

    public static let standard = HighlightCurve(knee: 0.55, maxInput: 16)

    public init(knee: Float, maxInput: Float) {
        self.knee = knee
        self.maxInput = maxInput
        // Solve (1 - knee) / (c * ln(1 + (maxInput - knee) / c)) = 1 for c (slope 1 at the knee).
        var lo: Float = 1e-4, hi: Float = 100
        for _ in 0..<100 {
            let mid = (lo + hi) / 2
            let slope = (1 - knee) / (mid * logf(1 + (maxInput - knee) / mid))
            if slope > 1 { lo = mid } else { hi = mid }
        }
        c = (lo + hi) / 2
    }

    public func map(_ x: Float) -> Float {
        if x <= knee { return max(0, x) }
        let y = knee + (1 - knee) * logf(1 + (x - knee) / c) / logf(1 + (maxInput - knee) / c)
        return min(1, y)
    }

    /// Exact inverse of `map` on [0, 1).
    public func inverse(_ y: Float) -> Float {
        if y <= knee { return max(0, y) }
        let L = logf(1 + (maxInput - knee) / c)
        let yy = min(y, 0.9999)
        return knee + c * (expf((yy - knee) * L / (1 - knee)) - 1)
    }

    /// Linear radiance in, display sRGB out.
    public func apply(_ radiance: FloatImage) -> FloatImage {
        var out = radiance
        let n = radiance.width * radiance.height
        out.data.withUnsafeMutableBufferPointer { d in
            DispatchQueue.concurrentPerform(iterations: max(1, n / 4096 + 1)) { chunk in
                let start = chunk * 4096, end = min(n, start + 4096)
                if start >= end { return }
                for i in start..<end {
                    var r = max(0, d[i * 3]), g = max(0, d[i * 3 + 1]), b = max(0, d[i * 3 + 2])
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    if y > knee {
                        let s = map(y) / y
                        r *= s; g *= s; b *= s
                        // Push over-range channels towards white instead of shifting the hue.
                        let m = max(r, g, b)
                        if m > 1 {
                            let t = min(1, (m - 1) / m)
                            r = r + (1 - r) * t; g = g + (1 - g) * t; b = b + (1 - b) * t
                            let m2 = max(r, g, b)
                            if m2 > 1 { r /= m2; g /= m2; b /= m2 }
                        }
                    }
                    d[i * 3] = ShotMerger.linearToSRGB(r)
                    d[i * 3 + 1] = ShotMerger.linearToSRGB(g)
                    d[i * 3 + 2] = ShotMerger.linearToSRGB(b)
                }
            }
        }
        return out
    }
}

/// Final tone mapping of the stitched panorama.
///
/// HDR shots are stored with the fixed `HighlightCurve.standard` so that overlapping photos
/// stay consistent for alignment and blending. After stitching, the panorama is decoded
/// back to linear radiance and re-encoded with a curve that fits *this* panorama:
/// without real highlights (99.9th percentile ≤ 1) nothing is compressed and whites stay
/// white; with highlights, only as much shoulder as their actual range needs.
public enum PanoramaToneMapper {
    public static func retone(_ img: inout FloatImage, encodedWith curve: HighlightCurve) {
        let n = img.width * img.height
        guard n > 0, img.channels == 3 else { return }
        // Decode to radiance (luminance-based, hue preserved).
        var lum = [Float](repeating: 0, count: n)
        img.data.withUnsafeMutableBufferPointer { d in
            for i in 0..<n {
                var r = ShotMerger.srgbToLinear(d[i * 3]), g = ShotMerger.srgbToLinear(d[i * 3 + 1]),
                    b = ShotMerger.srgbToLinear(d[i * 3 + 2])
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if y > curve.knee {
                    let s = curve.inverse(y) / y
                    r *= s; g *= s; b *= s
                }
                d[i * 3] = r; d[i * 3 + 1] = g; d[i * 3 + 2] = b
                lum[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        // Highlight range actually present (sampled percentile).
        var sample: [Float] = []
        sample.reserveCapacity(n / 7 + 1)
        var i = 0
        while i < n { sample.append(lum[i]); i += 7 }
        sample.sort()
        let p999 = sample[min(sample.count - 1, Int(Double(sample.count) * 0.999))]
        let finalCurve: HighlightCurve? = p999 <= 1.05 ? nil
            : HighlightCurve(knee: 0.75, maxInput: max(1.5, min(curve.maxInput, p999)))
        if let finalCurve {
            img = finalCurve.apply(img)
        } else {
            img.data.withUnsafeMutableBufferPointer { d in
                for k in 0..<(n * 3) { d[k] = ShotMerger.linearToSRGB(d[k]) }
            }
        }
    }
}

/// 16-bit log encoding of linear radiance (24 stops, 2^-12 ... 2^12 with ~0.0004-stop steps)
/// plus the panorama-wide exposure / tone curve selection for HDR captures.
public enum HDRRadiance {
    public static let minLog: Float = -12
    public static let maxLog: Float = 12

    public static func encode(_ r: FloatImage) -> [UInt16] {
        precondition(r.channels == 3)
        var out = [UInt16](repeating: 0, count: r.data.count)
        let span = maxLog - minLog
        r.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<src.count {
                    let x = src[i]
                    if x <= 0 { dst[i] = 0; continue }
                    let v = (log2f(x) - minLog) / span
                    dst[i] = UInt16(max(0, min(65535, v * 65535 + 0.5)))
                }
            }
        }
        return out
    }

    public static func decode(_ v: [UInt16], width: Int, height: Int) -> FloatImage {
        var img = FloatImage(width: width, height: height, channels: 3)
        let span = maxLog - minLog
        v.withUnsafeBufferPointer { src in
            img.data.withUnsafeMutableBufferPointer { dst in
                for i in 0..<min(src.count, dst.count) {
                    dst[i] = src[i] == 0 ? 0 : exp2f(Float(src[i]) / 65535 * span + minLog)
                }
            }
        }
        return img
    }

    /// Median and 99.9th percentile of luminance (sampled).
    public static func stats(_ r: FloatImage) -> (median: Double, p999: Double) {
        let n = r.width * r.height
        var lum: [Float] = []
        lum.reserveCapacity(n / 5 + 1)
        var i = 0
        while i < n {
            lum.append(0.2126 * r.data[i * 3] + 0.7152 * r.data[i * 3 + 1] + 0.0722 * r.data[i * 3 + 2])
            i += 5
        }
        lum.sort()
        guard !lum.isEmpty else { return (0.18, 1) }
        return (Double(lum[lum.count / 2]), Double(lum[min(lum.count - 1, Int(Double(lum.count) * 0.999))]))
    }

    /// Chooses one exposure gain and highlight curve for the whole panorama.
    /// - Parameter shots: per shot (median, p99.9) of its radiance already scaled to the
    ///   common exposure (radiance × E_ref / E_shot).
    public static func panoramaToneMapping(shots: [(median: Double, p999: Double)]) -> (gain: Float, curve: HighlightCurve) {
        guard !shots.isEmpty else { return (1, .standard) }
        let medians = shots.map(\.median).sorted()
        let median = max(medians[medians.count / 2], 1e-6)
        // Typical scene ends up at mid-grey, like a camera's auto exposure.
        let gain = max(1.0 / 64, min(64, 0.18 / median))
        let peak = (shots.map(\.p999).max() ?? 1) * gain
        let curve = peak <= 1.05 ? HighlightCurve(knee: 0.95, maxInput: 1.2)
                                 : HighlightCurve(knee: 0.7, maxInput: Float(min(256, max(1.5, peak * 1.5))))
        return (Float(gain), curve)
    }

    /// Radiance -> display sRGB with the panorama's gain and curve.
    public static func toDisplay(_ r: FloatImage, gain: Float, curve: HighlightCurve) -> FloatImage {
        var scaled = r
        scaled.data.withUnsafeMutableBufferPointer { d in
            for i in 0..<d.count { d[i] *= gain }
        }
        return curve.apply(scaled)
    }
}
