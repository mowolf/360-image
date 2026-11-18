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
/// 2. **Exposure fusion** (Mertens, Kautz & Van Reeth 2007). Per-pixel weights from
///    contrast, saturation and well-exposedness are blended with Laplacian pyramids. The
///    darker frames keep lamps and windows from blowing out, the brighter ones lift
///    shadows, and same-exposure frames average out noise. No HDR radiance map or
///    tone-mapping operator is needed, and the result looks natural.
/// 3. **Deghosting.** Pixels whose exposure-normalized radiance disagrees with the reference
///    (people moving, etc.) are suppressed. Frames noticeably blurrier than the sharpest
///    one (motion blur) are down-weighted.
public enum ShotMerger {
    public struct Report: Sendable {
        public var shifts: [(Double, Double)] = []
        public var sharpness: [Double] = []
        public var exposures: [Double] = []
        public var reference = 0
    }

    /// - Parameter reference: index of the frame defining the output geometry (normally the
    ///   metered EV0 frame). Returns an image with the reference frame's size and intrinsics.
    public static func merge(_ frames: [BurstFrame], reference: Int = 0) -> (FloatImage, Report) {
        var report = Report()
        guard frames.count > 1 else { return (frames.first?.image ?? FloatImage(width: 1, height: 1, channels: 3), report) }
        var r = reference
        // If another frame at the same exposure is clearly sharper, it becomes the reference.
        let sameExposure = frames.indices.filter { abs(log(frames[$0].exposure / frames[r].exposure)) < 0.1 }
        if sameExposure.count > 1 {
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

        // 3. Mertens weights with deghosting.
        var weights: [FloatImage] = []
        for (k, img) in aligned.enumerated() {
            var w = mertensWeights(img)
            // Only clearly blurred frames (motion blur cuts this energy several-fold) are penalized.
            let ratio0 = sharp[k] / medianSharp
            let blurFactor = Float(ratio0 < 0.35 ? pow(ratio0 / 0.35, 2) : 1)
            let ratio = Float(ref.exposure / exposures[k])
            let lin = linearize(img)
            w.data.withUnsafeMutableBufferPointer { wd in
                for i in 0..<(W * H) {
                    if !valid[k][i] { wd[i] = 0; continue }
                    var f = blurFactor
                    if k != r {
                        // Ghost test on channels that are well exposed in both frames.
                        var diff: Float = 0, cnt: Float = 0
                        for c in 0..<3 {
                            let a = img.data[i * 3 + c], b = ref.image.data[i * 3 + c]
                            if a > 0.03 && a < 0.95 && b > 0.03 && b < 0.95 {
                                let la = lin.data[i * 3 + c] * ratio, lb = refLin.data[i * 3 + c]
                                diff += abs(log(max(la, 1e-4)) - log(max(lb, 1e-4)))
                                cnt += 1
                            }
                        }
                        if cnt > 0 && diff / cnt > 0.3 { f *= 0.02 }
                    }
                    wd[i] *= f
                }
            }
            weights.append(w)
        }
        // Normalize weights.
        for i in 0..<(W * H) {
            var sum: Float = 0
            for k in 0..<weights.count { sum += weights[k].data[i] }
            if sum < 1e-12 {
                // Nothing usable (e.g. clipped everywhere): fall back to the reference.
                for k in 0..<weights.count { weights[k].data[i] = k == r ? 1 : 0 }
            } else {
                for k in 0..<weights.count { weights[k].data[i] /= sum }
            }
        }

        // 4. Laplacian pyramid blend.
        let levels = max(1, Int(log2(Double(min(W, H)))) - 3)
        var acc: [FloatImage]?
        for k in 0..<aligned.count {
            let lap = Pyramid.laplacian(aligned[k], levels: levels)
            let gw = Pyramid.gaussian(weights[k], levels: levels)
            if acc == nil {
                acc = lap.map { FloatImage(width: $0.width, height: $0.height, channels: 3) }
            }
            for l in 0...levels {
                let n = lap[l].width * lap[l].height
                acc![l].data.withUnsafeMutableBufferPointer { a in
                    lap[l].data.withUnsafeBufferPointer { b in
                        gw[l].data.withUnsafeBufferPointer { w in
                            for i in 0..<n {
                                let wi = w[i]
                                a[i * 3] += wi * b[i * 3]
                                a[i * 3 + 1] += wi * b[i * 3 + 1]
                                a[i * 3 + 2] += wi * b[i * 3 + 2]
                            }
                        }
                    }
                }
            }
        }
        var out = Pyramid.collapse(acc!)
        for i in 0..<out.data.count { out.data[i] = max(0, min(1, out.data[i])) }
        return (out, report)
    }

    // MARK: - Helpers

    @inline(__always) static func srgbToLinear(_ v: Float) -> Float {
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

    static func mertensWeights(_ img: FloatImage) -> FloatImage {
        let W = img.width, H = img.height
        var w = FloatImage(width: W, height: H, channels: 1)
        let gray = img.luminance()
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                let xm = max(0, x - 1), xp = min(W - 1, x + 1), ym = max(0, y - 1), yp = min(H - 1, y + 1)
                let lap = abs(gray.data[y * W + xm] + gray.data[y * W + xp] + gray.data[ym * W + x]
                              + gray.data[yp * W + x] - 4 * gray.data[i])
                let r = img.data[i * 3], g = img.data[i * 3 + 1], b = img.data[i * 3 + 2]
                let mu = (r + g + b) / 3
                let sat = ((r - mu) * (r - mu) + (g - mu) * (g - mu) + (b - mu) * (b - mu)) / 3
                let e = expf(-((r - 0.5) * (r - 0.5) + (g - 0.5) * (g - 0.5) + (b - 0.5) * (b - 0.5)) / (2 * 0.2 * 0.2))
                // Contrast and saturation are softened (+ε) so flat regions still get weight
                // from well-exposedness, as in common Mertens implementations.
                w.data[i] = (lap + 0.01) * (sat.squareRoot() + 0.05) * e + 1e-8
            }
        }
        return w
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
