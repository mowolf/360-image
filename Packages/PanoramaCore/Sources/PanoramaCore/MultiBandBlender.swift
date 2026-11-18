import Foundation

/// Equirectangular compositor with seam selection + multi-band (Laplacian pyramid) blending
/// (Burt & Adelson 1983; Brown & Lowe 2007, section 7).
///
/// - Seams: every panorama pixel is assigned to the photo with the highest centre-weight
///   w(x)·w(y) (a "maximum weight" seam, which places seams half way between photo centres).
/// - Blending: each photo's Laplacian band is blended with the Gaussian-blurred seam mask at
///   the same pyramid level, so low frequencies blend over wide regions (no visible exposure
///   steps) while high frequencies switch over a few pixels (no ghosting / blur).
/// - The panorama wraps around horizontally: pyramids of the full canvas are periodic in x.
public final class MultiBandBlender {
    public let width: Int
    public let height: Int
    public let levels: Int

    private var acc: [FloatImage] = []    // RGB per level
    private var wacc: [FloatImage] = []   // weight per level
    /// Seam map: index of the photo owning each panorama pixel (255 = none).
    let labels: UnsafeMutablePointer<UInt8>
    private var bestWeight: UnsafeMutablePointer<Float>?

    public struct Footprint: Sendable {
        public var x0: Int, x1: Int, y0: Int, y1: Int
        public var wrapsFully: Bool
        public var width: Int { x1 - x0 }
        public var height: Int { y1 - y0 }
    }

    public init(width: Int, height: Int, levels: Int) {
        precondition(width % (1 << levels) == 0 && height % (1 << levels) == 0,
                     "Panorama size must be divisible by 2^levels")
        self.width = width
        self.height = height
        self.levels = levels
        labels = .allocate(capacity: width * height)
        labels.initialize(repeating: 255, count: width * height)
        let bw = UnsafeMutablePointer<Float>.allocate(capacity: width * height)
        bw.initialize(repeating: 0, count: width * height)
        bestWeight = bw
    }

    deinit {
        labels.deallocate()
        bestWeight?.deallocate()
    }

    // MARK: Geometry helpers

    private lazy var colSin: [Double] = (0..<width).map { sin((Double($0) + 0.5) / Double(width) * 2 * .pi - .pi) }
    private lazy var colCos: [Double] = (0..<width).map { cos((Double($0) + 0.5) / Double(width) * 2 * .pi - .pi) }
    private lazy var rowSin: [Double] = (0..<height).map { sin(.pi / 2 - (Double($0) + 0.5) / Double(height) * .pi) }
    private lazy var rowCos: [Double] = (0..<height).map { cos(.pi / 2 - (Double($0) + 0.5) / Double(height) * .pi) }

    /// Bounding box of a camera's footprint on the canvas, padded and aligned to 2^levels.
    public func footprint(of cam: PanoCamera) -> Footprint {
        let align = 1 << levels
        return Self.footprint(of: cam, width: width, height: height, align: align, pad: 2 * align + 4)
    }

    /// Bounding box of a camera's footprint on an equirectangular grid of the given size.
    public static func footprint(of cam: PanoCamera, width: Int, height: Int, align: Int, pad basePad: Int) -> Footprint {
        let K = cam.intrinsics
        let P = cam.projector
        let W = Double(width), H = Double(height)
        // Depth-based reprojection can move interior pixels outside the hull of the
        // border; leave some extra room.
        let pad = basePad + (P.parallax ? width / 72 : 0)
        func inside(_ d: Vec3) -> Bool {
            guard let p = P.project(d) else { return false }
            return P.inside(p)
        }
        let north = inside(Vec3(0, 1, 0)), south = inside(Vec3(0, -1, 0))
        let center = Equirect.lonLat(P.unproject(u: K.cx, v: K.cy))
        var latMin = Double.infinity, latMax = -Double.infinity
        var dMin = Double.infinity, dMax = -Double.infinity
        let steps = 48
        let mw: Double = Double(K.width - 1), mh: Double = Double(K.height - 1)
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            let pts: [(Double, Double)] = [(t * mw, 0), (t * mw, mh), (0, t * mh), (mw, t * mh)]
            for (u, v) in pts {
                let ll = Equirect.lonLat(P.unproject(u: u, v: v))
                latMin = min(latMin, ll.lat); latMax = max(latMax, ll.lat)
                var dl = ll.lon - center.lon
                while dl > .pi { dl -= 2 * .pi }
                while dl < -.pi { dl += 2 * .pi }
                dMin = min(dMin, dl); dMax = max(dMax, dl)
            }
        }
        if north { latMax = .pi / 2 }
        if south { latMin = -.pi / 2 }
        var y0 = Int(floor((.pi / 2 - latMax) / .pi * H)) - pad
        var y1 = Int(ceil((.pi / 2 - latMin) / .pi * H)) + pad
        y0 = max(0, Int(floor(Double(y0) / Double(align))) * align)
        y1 = min(height, ((y1 + align - 1) / align) * align)

        var x0 = 0, x1 = width
        var full = north || south
        if !full {
            x0 = Int(floor((center.lon + dMin + .pi) / (2 * .pi) * W)) - pad
            x1 = Int(ceil((center.lon + dMax + .pi) / (2 * .pi) * W)) + pad
            x0 = Int(floor(Double(x0) / Double(align))) * align
            x1 = Int(ceil(Double(x1) / Double(align))) * align
            if x1 - x0 >= width { full = true }
        }
        if full { x0 = 0; x1 = width }
        return Footprint(x0: x0, x1: x1, y0: y0, y1: y1, wrapsFully: full)
    }

    /// Optional content-aware seams (from `SeamFinder`) on a coarser grid. Where the
    /// chosen photo covers a pixel it overrides the maximum-weight choice.
    private var seamLabels: [UInt8]?
    private var seamWidth = 0

    public func setSeamLabels(_ labels: [UInt8], width w: Int) {
        seamLabels = labels
        seamWidth = w
    }

    @inline(__always) private func wrapX(_ x: Int) -> Int {
        let r = x % width
        return r < 0 ? r + width : r
    }

    // MARK: Pass 1 — seam labels

    public func addToSeamMap(index k: Int, camera cam: PanoCamera) {
        precondition(k < 255)
        let fp = footprint(of: cam)
        let K = cam.intrinsics
        let P = cam.projector
        let seam = seamLabels
        let sW = seamWidth, sH = seamWidth / 2
        let sx = Double(sW) / Double(width), sy = Double(sH) / Double(height)
        let invW: Double = 2.0 / Double(K.width), invH: Double = 2.0 / Double(K.height)
        let maxU: Double = Double(K.width - 1), maxV: Double = Double(K.height - 1)
        let cs = colSin, cc = colCos, rs = rowSin, rc = rowCos
        let W = width
        let label = UInt8(k)
        let labPtr = labels
        guard let bestPtr = bestWeight else { preconditionFailure("addToSeamMap after prepareBlending") }
        DispatchQueue.concurrentPerform(iterations: fp.height) { (ty: Int) in
            let y = fp.y0 + ty
            let rcy: Double = rc[y], rsy: Double = rs[y]
            for x in fp.x0..<fp.x1 {
                var gx = x % W
                if gx < 0 { gx += W }
                let d = Vec3(rcy * cs[gx], rsy, -rcy * cc[gx])
                guard let p = P.project(d) else { continue }
                if p.u < 0 || p.v < 0 || p.u > maxU || p.v > maxV { continue }
                let wu: Double = 1 - abs(p.u * invW - 1)
                let wv: Double = 1 - abs(p.v * invH - 1)
                var w = Float(wu * wv) + 1e-6
                if let seam {
                    let si = min(sH - 1, Int(Double(y) * sy)) * sW + min(sW - 1, Int(Double(gx) * sx))
                    if seam[si] == label { w += 2 }
                }
                let i = y * W + gx
                if w > bestPtr[i] { bestPtr[i] = w; labPtr[i] = label }
            }
        }
    }

    /// Call once after all photos have been added to the seam map.
    public func prepareBlending() {
        bestWeight?.deallocate()
        bestWeight = nil
        acc = []
        wacc = []
        for l in 0...levels {
            acc.append(FloatImage(width: width >> l, height: height >> l, channels: 3))
            wacc.append(FloatImage(width: width >> l, height: height >> l, channels: 1))
        }
    }

    // MARK: Pass 2 — warp + blend one photo

    public func blend(index k: Int, image src: FloatImage, camera cam: PanoCamera, gain: [Float]) {
        let fp = footprint(of: cam)
        let tw = fp.width, th = fp.height
        let K = cam.intrinsics
        let P = cam.projector
        var tile = FloatImage(width: tw, height: th, channels: 3)
        var valid = [Bool](repeating: false, count: tw * th)
        var mask = FloatImage(width: tw, height: th, channels: 1)
        var anyLabel = false
        let cs = colSin, cc = colCos, rs = rowSin, rc = rowCos
        let maxU = Double(K.width - 1), maxV = Double(K.height - 1)
        let g = gain
        src.data.withUnsafeBufferPointer { s in
            tile.data.withUnsafeMutableBufferPointer { t in
                valid.withUnsafeMutableBufferPointer { v in
                    mask.data.withUnsafeMutableBufferPointer { m in
                        do { let lab = self.labels
                            DispatchQueue.concurrentPerform(iterations: th) { ty in
                                let y = fp.y0 + ty
                                for tx in 0..<tw {
                                    let gx = self.wrapX(fp.x0 + tx)
                                    let ti = ty * tw + tx
                                    if lab[y * self.width + gx] == UInt8(k) { m[ti] = 1 }
                                    let d = Vec3(rc[y] * cs[gx], rs[y], -rc[y] * cc[gx])
                                    guard let p = P.project(d), p.u >= 0, p.v >= 0, p.u <= maxU, p.v <= maxV else { continue }
                                    let o = t.baseAddress! + ti * 3
                                    FloatImage.sampleBilinear(s, width: src.width, height: src.height, channels: 3,
                                                              x: p.u, y: p.v, out: o)
                                    o[0] *= g[0]; o[1] *= g[1]; o[2] *= g[2]
                                    v[ti] = true
                                }
                            }
                        }
                    }
                }
            }
        }
        for i in 0..<mask.data.count where mask.data[i] > 0 { anyLabel = true; break }
        if !anyLabel { return }

        Pyramid.pushPullFill(&tile, valid: valid, wrapX: fp.wrapsFully)
        let lap = Pyramid.laplacian(tile, levels: levels, wrapX: fp.wrapsFully)
        let gm = Pyramid.gaussian(mask, levels: levels, wrapX: fp.wrapsFully)

        for l in 0...levels {
            let lw = width >> l
            let ox = fp.x0 >> l, oy = fp.y0 >> l
            let band = lap[l], wm = gm[l]
            acc[l].data.withUnsafeMutableBufferPointer { a in
                wacc[l].data.withUnsafeMutableBufferPointer { wa in
                    band.data.withUnsafeBufferPointer { b in
                        wm.data.withUnsafeBufferPointer { w in
                            DispatchQueue.concurrentPerform(iterations: band.height) { ty in
                                let y = oy + ty
                                for tx in 0..<band.width {
                                    let wt = w[ty * band.width + tx]
                                    if wt <= 0 { continue }
                                    var gx = (ox + tx) % lw
                                    if gx < 0 { gx += lw }
                                    let gi = y * lw + gx
                                    let ti = ty * band.width + tx
                                    a[gi * 3] += wt * b[ti * 3]
                                    a[gi * 3 + 1] += wt * b[ti * 3 + 1]
                                    a[gi * 3 + 2] += wt * b[ti * 3 + 2]
                                    wa[gi] += wt
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Pass 3 — normalize + collapse

    /// Returns the panorama and the fraction of the sphere covered by photos.
    public func finish() -> (FloatImage, Double) {
        for l in 0...levels {
            acc[l].data.withUnsafeMutableBufferPointer { a in
                wacc[l].data.withUnsafeBufferPointer { w in
                    for i in 0..<w.count {
                        if w[i] > 1e-8 {
                            let inv = 1 / w[i]
                            a[i * 3] *= inv; a[i * 3 + 1] *= inv; a[i * 3 + 2] *= inv
                        }
                    }
                }
            }
        }
        wacc = []
        var out = Pyramid.collapse(acc, wrapX: true)
        acc = []
        var valid = [Bool](repeating: false, count: width * height)
        var coveredArea = 0.0, totalArea = 0.0
        for y in 0..<height {
            let a = rowCos[y]
            for x in 0..<width {
                let i = y * width + x
                totalArea += a
                if labels[i] != 255 { valid[i] = true; coveredArea += a }
            }
        }
        out.data.withUnsafeMutableBufferPointer { d in
            for i in 0..<d.count { d[i] = max(0, min(1, d[i])) }
        }
        Pyramid.pushPullFill(&out, valid: valid, wrapX: true)
        return (out, coveredArea / max(totalArea, 1))
    }
}
