import Foundation

/// Content-aware seam selection by graph cuts (Kwatra et al. 2003 "Graphcut Textures";
/// Agarwala et al. 2004 "Interactive Digital Photomontage").
///
/// Every panorama pixel is labelled with the photo it is taken from. The energy is
///
///   E(L) = Σ_p D_p(L_p) + Σ_(p,q) V_pq(L_p, L_q)
///
/// - D_p: 0 inside a photo (+ a small preference for photo centres), ∞ outside it.
/// - V_pq: for neighbouring pixels with different labels a ≠ b,
///   |I_a(p) − I_b(p)| + |I_a(q) − I_b(q)|. Seams are therefore cheap where the two
///   photos agree and expensive where they differ (parallax, moving people, misaligned
///   detail), so they route around objects instead of cutting through them.
///
/// It is minimized with α-expansion (Boykov, Veksler & Zabih 2001) on a low-resolution
/// equirectangular grid, starting from the maximum-weight labelling.
public struct SeamFinder: Sendable {
    public var width: Int
    public var height: Int { width / 2 }
    public var centerWeight: Double = 0.06
    public var seamEpsilon: Double = 0.004
    public var outsideCost: Double = 2.0
    public var sweeps: Int = 2

    public init(width: Int) { self.width = width }

    /// One photo resampled onto the seam grid (only its footprint is stored).
    struct Tile {
        var x0: Int, y0: Int, w: Int, h: Int
        var rgb: [Float]      // gain-compensated colour
        var weight: [Float]   // centre weight, 0 = not covered
    }

    /// - Parameters:
    ///   - images: RGB photos at roughly the seam grid's resolution.
    ///   - cameras: cameras matching `images` (intrinsics already scaled).
    ///   - gains: per-photo colour gains.
    /// - Returns: label per seam-grid pixel (255 = uncovered).
    public func findSeams(images: [FloatImage], cameras: [PanoCamera], gains: [[Float]],
                          isCancelled: () -> Bool = { false }) -> [UInt8] {
        let n = images.count
        let W = width, H = height
        let tiles = (0..<n).map { makeTile(image: images[$0], camera: cameras[$0], gain: gains[$0]) }

        // Initial labelling: maximum centre weight.
        var labels = [UInt8](repeating: 255, count: W * H)
        var best = [Float](repeating: 0, count: W * H)
        for (k, t) in tiles.enumerated() {
            for ty in 0..<t.h {
                for tx in 0..<t.w {
                    let w = t.weight[ty * t.w + tx]
                    if w <= 0 { continue }
                    let gi = (t.y0 + ty) * W + wrap(t.x0 + tx)
                    if w > best[gi] { best[gi] = w; labels[gi] = UInt8(k) }
                }
            }
        }
        if n < 2 { return labels }

        for _ in 0..<sweeps {
            var changed = false
            for alpha in 0..<n {
                if isCancelled() { return labels }
                if expand(alpha: alpha, labels: &labels, tiles: tiles) { changed = true }
            }
            if !changed { break }
        }
        return labels
    }

    @inline(__always) func wrap(_ x: Int) -> Int {
        let r = x % width
        return r < 0 ? r + width : r
    }

    func makeTile(image: FloatImage, camera: PanoCamera, gain: [Float]) -> Tile {
        let W = width, H = height
        let P = camera.projector
        // Footprint bounding box on the seam grid (same approach as the blender).
        let fp = MultiBandBlender.footprint(of: camera, width: W, height: H, align: 1, pad: 2)
        var t = Tile(x0: fp.x0, y0: fp.y0, w: fp.width, h: fp.height,
                     rgb: [Float](repeating: 0, count: fp.width * fp.height * 3),
                     weight: [Float](repeating: 0, count: fp.width * fp.height))
        let K = camera.intrinsics
        let sx = Double(image.width) / Double(K.width), sy = Double(image.height) / Double(K.height)
        image.data.withUnsafeBufferPointer { src in
            t.rgb.withUnsafeMutableBufferPointer { rgb in
                t.weight.withUnsafeMutableBufferPointer { wt in
                    DispatchQueue.concurrentPerform(iterations: fp.height) { ty in
                        let y = fp.y0 + ty
                        for tx in 0..<fp.width {
                            let d = Equirect.direction(x: Double(self.wrap(fp.x0 + tx)), y: Double(y), width: W, height: H)
                            guard let p = P.project(d), P.inside(p) else { continue }
                            let i = ty * fp.width + tx
                            let wu = 1 - abs(2 * p.u / Double(K.width - 1) - 1)
                            let wv = 1 - abs(2 * p.v / Double(K.height - 1) - 1)
                            wt[i] = Float(max(1e-4, wu * wv))
                            FloatImage.sampleBilinear(src, width: image.width, height: image.height, channels: 3,
                                                      x: p.u * sx, y: p.v * sy, out: rgb.baseAddress! + i * 3)
                            rgb[i * 3] *= gain[0]; rgb[i * 3 + 1] *= gain[1]; rgb[i * 3 + 2] *= gain[2]
                        }
                    }
                }
            }
        }
        return t
    }

    /// Colour of photo `k` at grid pixel (x, y), or nil if not covered.
    @inline(__always)
    func color(_ tiles: [Tile], _ k: Int, _ x: Int, _ y: Int) -> (Float, Float, Float)? {
        let t = tiles[k]
        let ty = y - t.y0
        if ty < 0 || ty >= t.h { return nil }
        var tx = x - t.x0
        if tx < 0 { tx += width } else if tx >= width { tx -= width }
        if tx < 0 || tx >= t.w {
            // Footprints may extend past the wrap point on either side.
            tx = x - t.x0 + width
            if tx < 0 || tx >= t.w { tx = x - t.x0 - width }
            if tx < 0 || tx >= t.w { return nil }
        }
        let i = ty * t.w + tx
        if t.weight[i] <= 0 { return nil }
        return (t.rgb[i * 3], t.rgb[i * 3 + 1], t.rgb[i * 3 + 2])
    }

    @inline(__always)
    func centre(_ tiles: [Tile], _ k: Int, _ x: Int, _ y: Int) -> Float {
        let t = tiles[k]
        let ty = y - t.y0
        if ty < 0 || ty >= t.h { return 0 }
        for shift in [0, width, -width] {
            let tx = x - t.x0 + shift
            if tx >= 0 && tx < t.w { return t.weight[ty * t.w + tx] }
        }
        return 0
    }

    /// Seam cost contribution at one pixel between photos a and b.
    @inline(__always)
    func pixelCost(_ tiles: [Tile], _ a: Int, _ b: Int, _ x: Int, _ y: Int) -> Double {
        guard let ca = color(tiles, a, x, y), let cb = color(tiles, b, x, y) else { return outsideCost }
        let dr = ca.0 - cb.0, dg = ca.1 - cb.1, db = ca.2 - cb.2
        return Double((dr * dr + dg * dg + db * db).squareRoot())
    }

    @inline(__always)
    func V(_ tiles: [Tile], _ a: Int, _ b: Int, _ p: (Int, Int), _ q: (Int, Int)) -> Double {
        if a == b { return 0 }
        return seamEpsilon + pixelCost(tiles, a, b, p.0, p.1) + pixelCost(tiles, a, b, q.0, q.1)
    }

    @inline(__always)
    func D(_ tiles: [Tile], _ k: Int, _ x: Int, _ y: Int) -> Double {
        let w = centre(tiles, k, x, y)
        return w > 0 ? centerWeight * Double(1 - w) : 1e6
    }

    /// One α-expansion move. Returns true if any label changed.
    func expand(alpha: Int, labels: inout [UInt8], tiles: [Tile]) -> Bool {
        let W = width, H = height
        let t = tiles[alpha]
        let a8 = UInt8(alpha)
        // Graph nodes: pixels covered by α whose label is not α yet.
        var nodeOf = [Int32](repeating: -1, count: t.w * t.h)
        var pixels: [(Int, Int)] = []
        for ty in 0..<t.h {
            for tx in 0..<t.w where t.weight[ty * t.w + tx] > 0 {
                let x = wrap(t.x0 + tx), y = t.y0 + ty
                if labels[y * W + x] == a8 || labels[y * W + x] == 255 { continue }
                nodeOf[ty * t.w + tx] = Int32(pixels.count)
                pixels.append((x, y))
            }
        }
        if pixels.isEmpty { return false }
        let g = MaxFlowGraph(nodeCapacity: pixels.count, edgeCapacity: pixels.count * 2)
        g.addNodes(pixels.count)

        func node(_ x: Int, _ y: Int) -> Int {
            var tx = x - t.x0
            if tx < 0 { tx += W }
            if tx >= t.w { tx -= W }
            if tx < 0 || tx >= t.w { return -1 }
            let ty = y - t.y0
            if ty < 0 || ty >= t.h { return -1 }
            return Int(nodeOf[ty * t.w + tx])
        }

        for (idx, (x, y)) in pixels.enumerated() {
            let fp = Int(labels[y * W + x])
            g.addUnary(idx, e0: D(tiles, fp, x, y), e1: D(tiles, alpha, x, y))
            // Right and down neighbours (left/up are handled from the other side);
            // neighbours outside the graph contribute unary terms.
            for (nx, ny) in [(wrap(x + 1), y), (x, y + 1), (wrap(x - 1), y), (x, y - 1)] {
                if ny < 0 || ny >= H { continue }
                let fq = Int(labels[ny * W + nx])
                let j = node(nx, ny)
                if j >= 0 {
                    // Pairs inside the graph: add once (from the smaller index).
                    if j < idx { continue }
                    let A = V(tiles, fp, fq, (x, y), (nx, ny))
                    let B = V(tiles, fp, alpha, (x, y), (nx, ny))
                    let C = V(tiles, alpha, fq, (x, y), (nx, ny))
                    g.addPairwise(idx, j, A: A, B: B, C: C, D: 0)
                } else if fq != 255 {
                    // Neighbour keeps its label fq (it is already α, or α cannot cover it).
                    g.addUnary(idx, e0: V(tiles, fp, fq, (x, y), (nx, ny)), e1: V(tiles, alpha, fq, (x, y), (nx, ny)))
                }
            }
        }
        _ = g.maxflow()
        var changed = false
        for (idx, (x, y)) in pixels.enumerated() where g.isSink(idx) {
            labels[y * W + x] = a8
            changed = true
        }
        return changed
    }
}
