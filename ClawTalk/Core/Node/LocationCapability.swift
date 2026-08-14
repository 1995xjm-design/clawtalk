import Foundation
import CoreLocation

enum LocationCapability {

    struct LocationResult: Encodable {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let speed: Double
        let course: Double
        let timestamp: String
    }

    enum LocationError: LocalizedError {
        case denied
        case unavailable
        case timeout

        var errorDescription: String? {
            switch self {
            case .denied: return "定位权限被拒绝"
            case .unavailable: return "定位服务不可用"
            case .timeout: return "定位超时，请到开阔处重试"
            }
        }
    }

    static func getLocation() async throws -> LocationResult {
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationError.unavailable
        }

        let delegate = LocationDelegate()
        let manager = CLLocationManager()
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyBest

        // Request permission if needed
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // Wait for authorization
            try await delegate.waitForAuthorization()
        } else if status == .denied || status == .restricted {
            throw LocationError.denied
        }

        manager.requestLocation()

        let location = try await delegate.waitForLocation()
        let formatter = ISO8601DateFormatter()

        return LocationResult(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            course: location.course,
            timestamp: formatter.string(from: location.timestamp)
        )
    }
}

// MARK: - CLLocationManager Delegate

private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    /// 授权 / 定位各 15 秒超时兜底：到点抛 .timeout，不再无限转圈。
    private let timeoutDuration: Duration = .seconds(15)

    func waitForLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
            Task {
                try? await Task.sleep(for: self.timeoutDuration)
                self.finishLocation(throwing: LocationCapability.LocationError.timeout)
            }
        }
    }

    func waitForAuthorization() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.authContinuation = continuation
            Task {
                try? await Task.sleep(for: self.timeoutDuration)
                self.finishAuthorization(throwing: LocationCapability.LocationError.timeout)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            finishLocation(returning: location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation(throwing: error)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            finishAuthorization()
        } else if status == .denied || status == .restricted {
            finishAuthorization(throwing: LocationCapability.LocationError.denied)
        }
    }

    // MARK: - 一次性恢复：先取走并置 nil 再 resume，避免超时与回调竞态导致重复恢复崩溃

    private func finishLocation(returning location: CLLocation) {
        lock.lock()
        guard let continuation = locationContinuation else {
            lock.unlock()
            return
        }
        locationContinuation = nil
        lock.unlock()
        continuation.resume(returning: location)
    }

    private func finishLocation(throwing error: Error) {
        lock.lock()
        guard let continuation = locationContinuation else {
            lock.unlock()
            return
        }
        locationContinuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }

    private func finishAuthorization() {
        lock.lock()
        guard let continuation = authContinuation else {
            lock.unlock()
            return
        }
        authContinuation = nil
        lock.unlock()
        continuation.resume()
    }

    private func finishAuthorization(throwing error: Error) {
        lock.lock()
        guard let continuation = authContinuation else {
            lock.unlock()
            return
        }
        authContinuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
