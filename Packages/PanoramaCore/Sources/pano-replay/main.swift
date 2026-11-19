import Foundation
import PanoramaCore

// Replays an exported capture (Captures/<id>/ from the app) through the stitcher.
// Images must be pre-converted to binary PPM next to the JPEGs (scripts/replay-capture.sh
// does that). Usage: pano-replay <capture-dir> [--width N] [--no-depth] [--no-seams] [--out file.ppm]

struct ShotRecord: Decodable {
    var image: String
    var intrinsics: Intrinsics
    var rotation: [Double]
    var position: [Double]
    var depth: String?
    var relativeDepth: String?
}
struct Manifest: Decodable {
    var shots: [ShotRecord]
    var scenePoints: [Float]
}

func readPPM(_ url: URL) throws -> FloatImage {
    let data = try Data(contentsOf: url)
    var idx = 0
    func token() -> String {
        while idx < data.count, [0x20, 0x0a, 0x0d, 0x09].contains(data[idx]) { idx += 1 }
        let start = idx
        while idx < data.count, ![0x20, 0x0a, 0x0d, 0x09].contains(data[idx]) { idx += 1 }
        return String(decoding: data[start..<idx], as: UTF8.self)
    }
    guard token() == "P6", let w = Int(token()), let h = Int(token()), Int(token()) == 255 else {
        throw NSError(domain: "ppm", code: 1)
    }
    idx += 1
    var img = FloatImage(width: w, height: h, channels: 3)
    for i in 0..<(w * h * 3) { img.data[i] = Float(data[idx + i]) / 255 }
    return img
}

func writePPM(_ img: FloatImage, to path: String) {
    var out = Data("P6\n\(img.width) \(img.height)\n255\n".utf8)
    let rgba = img.rgba8()
    var rgb = [UInt8](); rgb.reserveCapacity(img.width * img.height * 3)
    for i in 0..<(img.width * img.height) { rgb += [rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]] }
    out.append(contentsOf: rgb)
    FileManager.default.createFile(atPath: path, contents: out)
}

func readFloatGrid(_ url: URL) -> (Int, Int, [Float])? {
    guard let data = try? Data(contentsOf: url), data.count >= 8 else { return nil }
    let w = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) })
    let h = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) })
    guard w > 0, h > 0, data.count == 8 + w * h * 4 else { return nil }
    var values = [Float](repeating: 0, count: w * h)
    _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 8..<data.count) }
    return (w, h, values)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let dirArg = args.first else {
    print("usage: pano-replay <capture-dir> [--width N] [--no-depth] [--no-seams] [--out file.ppm]")
    exit(2)
}
let dir = URL(fileURLWithPath: dirArg)
var options = StitchOptions()
options.outputWidth = 4096
var outPath = dir.appendingPathComponent("replay.ppm").path
var i = 1
while i < args.count {
    switch args[i] {
    case "--width": options.outputWidth = Int(args[i + 1]) ?? 4096; i += 1
    case "--no-depth": options.compensateParallax = false
    case "--no-seams": options.graphCutSeams = false
    case "--out": outPath = args[i + 1]; i += 1
    default: break
    }
    i += 1
}

let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
let sources: [StitchSource] = manifest.shots.map { r in
    let ppm = dir.appendingPathComponent((r.image as NSString).deletingPathExtension + ".ppm")
    let R = Mat3(r.rotation[0], r.rotation[1], r.rotation[2], r.rotation[3], r.rotation[4],
                 r.rotation[5], r.rotation[6], r.rotation[7], r.rotation[8])
    let depth = r.depth.flatMap { readFloatGrid(dir.appendingPathComponent($0)) }.map { DepthMap(width: $0.0, height: $0.1, depth: $0.2) }
    let rel = r.relativeDepth.flatMap { readFloatGrid(dir.appendingPathComponent($0)) }.map { RelativeDepth(width: $0.0, height: $0.1, values: $0.2) }
    return StitchSource(intrinsics: r.intrinsics, rotation: R, position: Vec3(r.position[0], r.position[1], r.position[2]),
                        depth: depth, relativeDepth: rel, load: { try readPPM(ppm) })
}
var points: [Vec3] = []
for k in stride(from: 0, to: manifest.scenePoints.count - 2, by: 3) {
    points.append(Vec3(Double(manifest.scenePoints[k]), Double(manifest.scenePoints[k + 1]), Double(manifest.scenePoints[k + 2])))
}
print("\(sources.count) photos, \(points.count) scene points, LiDAR \(sources.filter { $0.depth != nil }.count), mono \(sources.filter { $0.relativeDepth != nil }.count)")
let offsets = sources.compactMap(\.position)
let c = offsets.reduce(Vec3.zero, +) / Double(max(1, offsets.count))
let spread = offsets.map { ($0 - c).length }
print(String(format: "camera position spread: mean %.3f m, max %.3f m", spread.reduce(0, +) / Double(max(1, spread.count)), spread.max() ?? 0))

var lastStage = ""
let result = try Stitcher().stitch(sources, scenePoints: points, options: options) { stage, p in
    if stage.rawValue != lastStage { lastStage = stage.rawValue; print("…", stage.rawValue) }
}
let r = result.report
print(String(format: """
pairs %d/%d, matches %d
residual (alignment px): sensor %.2f, rotation-only %.2f, depth %.2f -> final %.2f
depth model used: %@ (%d photos with depth, %d dropped), vignette a=%.3f b=%.3f, coverage %.3f, %.1fs
""", r.pairsAligned, r.pairsTried, r.matches, r.rmsBefore, r.residualRotationOnly, r.residualDepth, r.rmsAfter,
   r.depthModelUsed ? "yes" : "no", r.depthSources, r.depthDroppedPhotos, r.vignette.a, r.vignette.b, r.coverage, r.seconds))
writePPM(result.panorama, to: outPath)
print("wrote \(outPath)")
