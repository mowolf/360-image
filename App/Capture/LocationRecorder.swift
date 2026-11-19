import CoreLocation
import CoreMotion
import Foundation

/// GPS position and compass heading for a captured photo.
struct ShotLocation: Codable, Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    /// True-north heading (degrees) of the camera's viewing direction, if known.
    var heading: Double?
    var timestamp: Date
}

/// Records GPS (CoreLocation) and the camera's true-north heading (CoreMotion's
/// `xTrueNorthZVertical` attitude, which works with the phone held upright, unlike a
/// plain compass heading). Everything is optional: without permission photos simply
/// have no location.
final class LocationRecorder: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let motion = CMMotionManager()
    private var lastLocation: CLLocation?
    private var lastHeading: Double?
    private let lock = NSLock()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: begin()
        default: break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
    }

    /// Location + heading right now (nil without permission or fix).
    func snapshot() -> ShotLocation? {
        lock.lock(); defer { lock.unlock() }
        guard let loc = lastLocation, loc.horizontalAccuracy >= 0 else { return nil }
        return ShotLocation(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                            altitude: loc.altitude, horizontalAccuracy: loc.horizontalAccuracy,
                            heading: lastHeading, timestamp: loc.timestamp)
    }

    private func begin() {
        manager.startUpdatingLocation()
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        guard motion.isDeviceMotionAvailable, frames.contains(.xTrueNorthZVertical) else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: OperationQueue()) { [weak self] m, _ in
            guard let self, let m else { return }
            // Rows of the rotation matrix are the device axes in the reference frame
            // (x = true north, y = west, z = up). The camera looks along device -z.
            let r = m.attitude.rotationMatrix
            let north = -r.m31, west = -r.m32
            guard north * north + west * west > 0.01 else { return } // pointing straight up/down
            var deg = atan2(-west, north) * 180 / .pi
            if deg < 0 { deg += 360 }
            self.lock.lock(); self.lastHeading = deg; self.lock.unlock()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            begin()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lock.lock(); defer { lock.unlock() }
        if lastLocation == nil || loc.horizontalAccuracy <= (lastLocation?.horizontalAccuracy ?? .infinity) + 5
            || loc.timestamp.timeIntervalSince(lastLocation!.timestamp) > 10 {
            lastLocation = loc
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
