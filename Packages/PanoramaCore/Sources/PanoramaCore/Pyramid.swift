import Foundation

/// Burt & Adelson Gaussian / Laplacian pyramid primitives using the classic
/// 5-tap binomial kernel [1 4 6 4 1] / 16.
///
/// All functions work on interleaved multi-channel images of arbitrary size.
/// The vertical boundary is always clamped; the horizontal boundary can either be
/// clamped or periodic (`wrapX`), which is what an equirectangular panorama needs
/// so that the 180 degree meridian blends seamlessly.
public enum Pyramid {

    @inline(__always)
    static func idx(_ i: Int, _ n: Int, wrap: Bool) -> Int {
        if wrap {
            let r = i % n
            return r < 0 ? r + n : r
        }
        return i < 0 ? 0 : (i >= n ? n - 1 : i)
    }

    /// Blur + subsample by two. Output size defaults to ceil(size / 2).
    public static func reduce(_ src: FloatImage, width ow: Int? = nil, height oh: Int? = nil, wrapX: Bool = false) -> FloatImage {
        let w = src.width, h = src.height, c = src.channels
        let outW = ow ?? (w + 1) / 2
        let outH = oh ?? (h + 1) / 2
        var tmp = [Float](repeating: 0, count: outW * h * c)
        src.data.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                // Horizontal pass
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let srow = y * w * c
                    let trow = y * outW * c
                    for m in 0..<outW {
                        let x = 2 * m
                        let a = srow + idx(x - 2, w, wrap: wrapX) * c
                        let b = srow + idx(x - 1, w, wrap: wrapX) * c
                        let d = srow + idx(x, w, wrap: wrapX) * c
                        let e = srow + idx(x + 1, w, wrap: wrapX) * c
                        let f = srow + idx(x + 2, w, wrap: wrapX) * c
                        let o = trow + m * c
                        for ch in 0..<c {
                            t[o + ch] = (s[a + ch] + 4 * s[b + ch] + 6 * s[d + ch] + 4 * s[e + ch] + s[f + ch]) * (1.0 / 16.0)
                        }
                    }
                }
            }
        }
        var out = FloatImage(width: outW, height: outH, channels: c)
        tmp.withUnsafeBufferPointer { t in
            out.data.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: outH) { m in
                    let y = 2 * m
                    let r0 = idx(y - 2, h, wrap: false) * outW * c
                    let r1 = idx(y - 1, h, wrap: false) * outW * c
                    let r2 = idx(y, h, wrap: false) * outW * c
                    let r3 = idx(y + 1, h, wrap: false) * outW * c
                    let r4 = idx(y + 2, h, wrap: false) * outW * c
                    let orow = m * outW * c
                    for i in 0..<(outW * c) {
                        o[orow + i] = (t[r0 + i] + 4 * t[r1 + i] + 6 * t[r2 + i] + 4 * t[r3 + i] + t[r4 + i]) * (1.0 / 16.0)
                    }
                }
            }
        }
        return out
    }

    /// Upsample by two + blur (the classic EXPAND operator) to the requested size.
    public static func expand(_ src: FloatImage, width outW: Int, height outH: Int, wrapX: Bool = false) -> FloatImage {
        let w = src.width, h = src.height, c = src.channels
        var tmp = [Float](repeating: 0, count: outW * h * c)
        src.data.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let srow = y * w * c
                    let trow = y * outW * c
                    for x in 0..<outW {
                        let m = x >> 1
                        let o = trow + x * c
                        if x & 1 == 0 {
                            let a = srow + idx(m - 1, w, wrap: wrapX) * c
                            let b = srow + idx(m, w, wrap: wrapX) * c
                            let d = srow + idx(m + 1, w, wrap: wrapX) * c
                            for ch in 0..<c { t[o + ch] = (s[a + ch] + 6 * s[b + ch] + s[d + ch]) * 0.125 }
                        } else {
                            let a = srow + idx(m, w, wrap: wrapX) * c
                            let b = srow + idx(m + 1, w, wrap: wrapX) * c
                            for ch in 0..<c { t[o + ch] = (s[a + ch] + s[b + ch]) * 0.5 }
                        }
                    }
                }
            }
        }
        var out = FloatImage(width: outW, height: outH, channels: c)
        tmp.withUnsafeBufferPointer { t in
            out.data.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: outH) { y in
                    let m = y >> 1
                    let orow = y * outW * c
                    let n = outW * c
                    if y & 1 == 0 {
                        let a = idx(m - 1, h, wrap: false) * n
                        let b = idx(m, h, wrap: false) * n
                        let d = idx(m + 1, h, wrap: false) * n
                        for i in 0..<n { o[orow + i] = (t[a + i] + 6 * t[b + i] + t[d + i]) * 0.125 }
                    } else {
                        let a = idx(m, h, wrap: false) * n
                        let b = idx(m + 1, h, wrap: false) * n
                        for i in 0..<n { o[orow + i] = (t[a + i] + t[b + i]) * 0.5 }
                    }
                }
            }
        }
        return out
    }

    public static func gaussian(_ img: FloatImage, levels: Int, wrapX: Bool = false) -> [FloatImage] {
        var out = [img]
        out.reserveCapacity(levels + 1)
        for _ in 0..<levels { out.append(reduce(out.last!, wrapX: wrapX)) }
        return out
    }

    /// Laplacian pyramid: `levels` band-pass images followed by the low-pass residual.
    public static func laplacian(_ img: FloatImage, levels: Int, wrapX: Bool = false) -> [FloatImage] {
        let g = gaussian(img, levels: levels, wrapX: wrapX)
        var out: [FloatImage] = []
        out.reserveCapacity(levels + 1)
        for l in 0..<levels {
            var band = g[l]
            let up = expand(g[l + 1], width: band.width, height: band.height, wrapX: wrapX)
            band.data.withUnsafeMutableBufferPointer { b in
                up.data.withUnsafeBufferPointer { u in
                    for i in 0..<b.count { b[i] -= u[i] }
                }
            }
            out.append(band)
        }
        out.append(g[levels])
        return out
    }

    /// Reconstruct an image from a Laplacian pyramid.
    public static func collapse(_ lap: [FloatImage], wrapX: Bool = false) -> FloatImage {
        var img = lap.last!
        for l in stride(from: lap.count - 2, through: 0, by: -1) {
            var up = expand(img, width: lap[l].width, height: lap[l].height, wrapX: wrapX)
            up.data.withUnsafeMutableBufferPointer { u in
                lap[l].data.withUnsafeBufferPointer { b in
                    for i in 0..<u.count { u[i] += b[i] }
                }
            }
            img = up
        }
        return img
    }

    /// Push-pull hole filling: pixels with `valid[i] == false` are replaced by a smooth
    /// extrapolation of the surrounding valid pixels. Used so that Laplacian pyramids do
    /// not see artificial edges at the border of a warped image's footprint.
    public static func pushPullFill(_ img: inout FloatImage, valid: [Bool], wrapX: Bool = false) {
        let c = img.channels
        // Premultiplied image + weight as an extra channel.
        var pm = FloatImage(width: img.width, height: img.height, channels: c + 1)
        var anyValid = false, allValid = true
        img.data.withUnsafeBufferPointer { s in
            pm.data.withUnsafeMutableBufferPointer { d in
                for i in 0..<(img.width * img.height) {
                    if valid[i] {
                        anyValid = true
                        for ch in 0..<c { d[i * (c + 1) + ch] = s[i * c + ch] }
                        d[i * (c + 1) + c] = 1
                    } else {
                        allValid = false
                    }
                }
            }
        }
        if !anyValid || allValid { return }
        // Pull: build normalized pyramid until every pixel is covered.
        var levels = [pm]
        while true {
            let last = levels.last!
            if last.width <= 1 && last.height <= 1 { break }
            var next = reduce(last, wrapX: wrapX)
            var covered = true
            next.data.withUnsafeMutableBufferPointer { d in
                for i in 0..<(next.width * next.height) {
                    let wgt = d[i * (c + 1) + c]
                    if wgt > 1e-6 {
                        let inv = 1 / wgt
                        for ch in 0..<c { d[i * (c + 1) + ch] *= inv }
                        d[i * (c + 1) + c] = 1
                    } else {
                        for ch in 0...c { d[i * (c + 1) + ch] = 0 }
                        covered = false
                    }
                }
            }
            levels.append(next)
            if covered { break }
        }
        // Push: fill holes from coarser levels.
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[l + 1]
            let lw = levels[l].width, lh = levels[l].height
            let up = expand(coarse, width: lw, height: lh, wrapX: wrapX)
            levels[l].data.withUnsafeMutableBufferPointer { d in
                up.data.withUnsafeBufferPointer { u in
                    for i in 0..<(lw * lh) {
                        let base = i * (c + 1)
                        if d[base + c] < 0.5 {
                            let uw = max(u[base + c], 1e-6)
                            for ch in 0..<c { d[base + ch] = u[base + ch] / uw }
                            d[base + c] = 1
                        }
                    }
                }
            }
        }
        let filled = levels[0]
        img.data.withUnsafeMutableBufferPointer { d in
            filled.data.withUnsafeBufferPointer { s in
                for i in 0..<(img.width * img.height) where !valid[i] {
                    for ch in 0..<c { d[i * c + ch] = s[i * (c + 1) + ch] }
                }
            }
        }
    }
}
