import Foundation

/// 能力服务协议（对齐官方 NodeServiceProtocols）：
/// 定义我方能力服务的通用契约，供 UI/调度层面向协议编程。
protocol CameraServicing {
    func listDevices() async throws -> [String]
    func snap() async throws -> Data?
    func clip(duration: Double) async throws -> Data?
}

protocol ScreenRecordingServicing {
    func authorizationStatus() async -> Bool
    func record() async throws
    func stop() async throws -> URL?
}

protocol LocationServicing {
    func authorizationStatus() async -> Bool
    func currentLocation() async throws -> (latitude: Double, longitude: Double)?
}

protocol DeviceStatusServicing {
    func status() async -> [String: Any]
    func info() async -> [String: Any]
}

protocol PhotosServicing {
    func latest() async throws -> Data?
    func search(query: String) async throws -> [String]
}

protocol ContactsServicing {
    func list() async throws -> [String]
    func search(query: String) async throws -> [String]
}

protocol CalendarServicing {
    func events(start: Date, end: Date) async throws -> [String]
    func add(title: String, date: Date) async throws -> Bool
}

protocol RemindersServicing {
    func list() async throws -> [String]
    func add(title: String, due: Date?) async throws -> Bool
}

protocol MotionServicing {
    func activities() async throws -> [String]
    func pedometer() async throws -> [String: Any]
}
