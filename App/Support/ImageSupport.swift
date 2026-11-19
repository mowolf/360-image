import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import PanoramaCore
import UniformTypeIdentifiers
import simd

extension Mat3 {
    /// Rotation part of an ARKit transform (camera-to-world).
    init(_ t: simd_float4x4) {
        let c0 = t.columns.0, c1 = t.columns.1, c2 = t.columns.2
        self.init(columns: Vec3(Double(c0.x), Double(c0.y), Double(c0.z)),
                  Vec3(Double(c1.x), Double(c1.y), Double(c1.z)),
                  Vec3(Double(c2.x), Double(c2.y), Double(c2.z)))
    }
}

extension Vec3 {
    var float3: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
    init(_ v: SIMD3<Float>) { self.init(Double(v.x), Double(v.y), Double(v.z)) }
}

extension Intrinsics {
    /// From an ARKit intrinsics matrix (column-major) for an image of the given size.
    init(_ k: simd_float3x3, width: Int, height: Int) {
        self.init(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]),
                  width: width, height: height)
    }
}

enum ImageSupport {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Converts a camera pixel buffer to a CGImage whose long side is at most `maxLongSide`.
    static func cgImage(from pixelBuffer: CVPixelBuffer, maxLongSide: Int) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let w = image.extent.width, h = image.extent.height
        let scale = min(1, CGFloat(maxLongSide) / max(w, h))
        if scale < 0.999 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image
            f.scale = Float(scale)
            f.aspectRatio = 1
            if let out = f.outputImage { image = out }
        }
        let rect = CGRect(x: 0, y: 0, width: (w * scale).rounded(.down), height: (h * scale).rounded(.down))
        let translated = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return ciContext.createCGImage(translated, from: rect, format: .RGBA8, colorSpace: sRGB)
    }

    static func downscaled(_ image: CGImage, maxLongSide: Int) -> CGImage? {
        let scale = min(1, CGFloat(maxLongSide) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.92, metadata: CGImageMetadata? = nil) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        let props = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        if let metadata {
            CGImageDestinationAddImageAndMetadata(dest, image, metadata, props)
        } else {
            CGImageDestinationAddImage(dest, image, props)
        }
        return CGImageDestinationFinalize(dest)
    }

    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func floatImage(from image: CGImage) -> FloatImage {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return bytes.withUnsafeBytes { FloatImage(rgba8: $0, width: w, height: h, bytesPerRow: w * 4) }
    }

    static func cgImage(from image: FloatImage) -> CGImage? {
        let bytes = image.rgba8()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Google Photo Sphere XMP metadata, so Photos apps / Google Maps / Facebook recognise
    /// the JPEG as an interactive 360° panorama.
    static func photoSphereMetadata(width: Int, height: Int, imageCount: Int,
                                    location: ShotLocation? = nil, heading: Double? = nil) -> CGImageMetadata {
        let meta = CGImageMetadataCreateMutable()
        let ns = "http://ns.google.com/photos/1.0/panorama/" as CFString
        CGImageMetadataRegisterNamespaceForPrefix(meta, ns, "GPano" as CFString, nil)
        func set(_ key: String, _ value: String) {
            CGImageMetadataSetValueWithPath(meta, nil, "GPano:\(key)" as CFString, value as CFString)
        }
        set("ProjectionType", "equirectangular")
        set("UsePanoramaViewer", "True")
        set("CaptureSoftware", "Pano360")
        set("StitchingSoftware", "Pano360")
        set("SourcePhotosCount", "\(imageCount)")
        // Heading of the panorama's centre (the first photo), so viewers can align it with the map.
        set("PoseHeadingDegrees", String(format: "%.1f", heading ?? 0))
        if let location {
            func gps(_ key: CFString, _ value: Any) {
                _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, key, value as CFTypeRef)
            }
            gps(kCGImagePropertyGPSLatitude, abs(location.latitude))
            gps(kCGImagePropertyGPSLatitudeRef, location.latitude >= 0 ? "N" : "S")
            gps(kCGImagePropertyGPSLongitude, abs(location.longitude))
            gps(kCGImagePropertyGPSLongitudeRef, location.longitude >= 0 ? "E" : "W")
            gps(kCGImagePropertyGPSAltitude, abs(location.altitude))
            gps(kCGImagePropertyGPSAltitudeRef, location.altitude >= 0 ? 0 : 1)
            gps(kCGImagePropertyGPSHPositioningError, location.horizontalAccuracy)
            if let heading {
                gps(kCGImagePropertyGPSImgDirection, heading)
                gps(kCGImagePropertyGPSImgDirectionRef, "T")
            }
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy:MM:dd"
            gps(kCGImagePropertyGPSDateStamp, f.string(from: location.timestamp))
            f.dateFormat = "HH:mm:ss"
            gps(kCGImagePropertyGPSTimeStamp, f.string(from: location.timestamp))
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyExifDictionary,
                                                         kCGImagePropertyExifDateTimeOriginal, df.string(from: Date()) as CFString)
        set("FullPanoWidthPixels", "\(width)")
        set("FullPanoHeightPixels", "\(height)")
        set("CroppedAreaImageWidthPixels", "\(width)")
        set("CroppedAreaImageHeightPixels", "\(height)")
        set("CroppedAreaLeftPixels", "0")
        set("CroppedAreaTopPixels", "0")
        return meta
    }
}
