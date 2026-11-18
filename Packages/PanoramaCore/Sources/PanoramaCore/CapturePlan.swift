import Foundation

/// A direction the user is asked to point the phone at.
public struct CaptureTarget: Identifiable, Equatable, Sendable, Codable {
    public let id: Int
    /// Yaw relative to the initial heading (radians, positive = turn right).
    public let yaw: Double
    /// Pitch above the horizon (radians, +pi/2 = straight up).
    public let pitch: Double
    public let ring: Int

    /// World direction for a session whose initial heading has world longitude `baseYaw`.
    public func direction(baseYaw: Double) -> Vec3 {
        Equirect.direction(lon: baseYaw + yaw, lat: pitch)
    }

    public var isPole: Bool { abs(abs(pitch) - .pi / 2) < 1e-6 }
}

/// Plans a set of capture directions covering the full sphere with a requested overlap,
/// in the spirit of the classic "photo sphere" capture UIs: a ring on the horizon, rings
/// above and below, plus zenith and nadir.
public struct CapturePlan: Sendable {
    public let targets: [CaptureTarget]
    /// Two targets closer than this are considered neighbours (their photos overlap).
    public let neighbourAngle: Double

    /// - Parameters:
    ///   - horizontalFOV: horizontal field of view of the photos as the user holds the phone (radians).
    ///   - verticalFOV: vertical field of view as held (radians).
    ///   - overlap: fraction of each photo that should overlap its neighbour (0.3 to 0.4 is good).
    public init(horizontalFOV hfov: Double, verticalFOV vfov: Double, overlap: Double = 0.35) {
        let step = vfov * (1 - overlap)
        let ringsPerHemisphere = max(0, Int(ceil((.pi / 2) / step)) - 1)
        let ringSpacing = (.pi / 2) / Double(ringsPerHemisphere + 1)

        var pitches: [Double] = [0]
        if ringsPerHemisphere > 0 {
            for k in 1...ringsPerHemisphere { pitches.append(Double(k) * ringSpacing) }
            for k in 1...ringsPerHemisphere { pitches.append(-Double(k) * ringSpacing) }
        }

        var targets: [CaptureTarget] = []
        var maxYawStep = 0.0
        for (ringIndex, p) in pitches.enumerated() {
            let twoPi: Double = 2 * Double.pi
            let lonWidth: Double = 2 * atan(tan(hfov / 2) / cos(p))
            let perShot: Double = min(lonWidth, twoPi) * (1 - overlap)
            let n: Int = max(3, Int(ceil(twoPi / perShot)))
            let yawStep: Double = twoPi / Double(n)
            maxYawStep = max(maxYawStep, yawStep * cos(p))
            let offset = ringIndex % 2 == 1 ? yawStep / 2 : 0
            for i in 0..<n {
                var yaw: Double = Double(i) * yawStep + offset
                if yaw > Double.pi { yaw -= twoPi }
                targets.append(CaptureTarget(id: targets.count, yaw: yaw, pitch: p, ring: ringIndex))
            }
            // Zenith right after the top ring, nadir last.
            if ringsPerHemisphere == 0 || ringIndex == ringsPerHemisphere {
                targets.append(CaptureTarget(id: targets.count, yaw: 0, pitch: .pi / 2, ring: pitches.count))
            }
        }
        targets.append(CaptureTarget(id: targets.count, yaw: 0, pitch: -.pi / 2, ring: pitches.count + 1))
        self.targets = targets
        self.neighbourAngle = max(maxYawStep, ringSpacing) * 1.35
    }

    /// Chooses the next target to show: among uncaptured targets that neighbour an
    /// already-captured one (so every new photo overlaps the existing set), the one
    /// closest to where the user currently points. The first target is the one straight
    /// ahead on the horizon.
    public func nextTarget(captured: Set<Int>, currentDirection: Vec3, baseYaw: Double) -> CaptureTarget? {
        let remaining = targets.filter { !captured.contains($0.id) }
        if remaining.isEmpty { return nil }
        if captured.isEmpty { return targets[0] }
        let capturedDirs = targets.filter { captured.contains($0.id) }.map { $0.direction(baseYaw: baseYaw) }
        let adjacent = remaining.filter { t in
            let d = t.direction(baseYaw: baseYaw)
            return capturedDirs.contains { $0.angle(to: d) < neighbourAngle }
        }
        let pool = adjacent.isEmpty ? remaining : adjacent
        // Prefer staying on the same ring as long as possible (feels natural, like the
        // original app): weigh pitch changes slightly more than yaw changes.
        return pool.min { a, b in
            score(a, currentDirection, baseYaw) < score(b, currentDirection, baseYaw)
        }
    }

    private func score(_ t: CaptureTarget, _ current: Vec3, _ baseYaw: Double) -> Double {
        let d = t.direction(baseYaw: baseYaw)
        let (_, lat) = Equirect.lonLat(current)
        return current.angle(to: d) + 0.6 * abs(lat - t.pitch)
    }
}
