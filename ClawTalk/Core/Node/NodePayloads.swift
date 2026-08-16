import Foundation

/// Official-wire payload structs for node.invoke commands.
/// Field names mirror OpenClawKit models exactly so gateway-side parsing matches.
enum NodePayloads {

    // MARK: - location.get

    struct LocationPayload: Encodable {
        let lat: Double
        let lon: Double
        let accuracyMeters: Double
        let altitudeMeters: Double?
        let speedMps: Double?
        let headingDeg: Double?
        let timestamp: String
        let isPrecise: Bool
        let source: String?
    }

    // MARK: - photos.latest

    struct PhotoPayload: Encodable {
        let format: String
        let base64: String
        let width: Int
        let height: Int
        let createdAt: String?
    }

    struct PhotosLatestPayload: Encodable {
        let photos: [PhotoPayload]
    }

    // MARK: - calendar

    struct CalendarEventPayload: Encodable {
        let identifier: String
        let title: String
        let startISO: String
        let endISO: String
        let isAllDay: Bool
        let location: String?
        let calendarTitle: String?
    }

    struct CalendarEventsPayload: Encodable {
        let events: [CalendarEventPayload]
    }

    struct CalendarAddPayload: Encodable {
        let event: CalendarEventPayload
    }

    // MARK: - reminders

    struct ReminderPayload: Encodable {
        let identifier: String
        let title: String
        let dueISO: String?
        let completed: Bool
        let listName: String?
    }

    struct RemindersListPayload: Encodable {
        let reminders: [ReminderPayload]
    }

    struct RemindersAddPayload: Encodable {
        let reminder: ReminderPayload
    }

    // MARK: - motion

    struct MotionActivityEntry: Encodable {
        let startISO: String
        let endISO: String
        let confidence: String
        let isWalking: Bool
        let isRunning: Bool
        let isCycling: Bool
        let isAutomotive: Bool
        let isStationary: Bool
        let isUnknown: Bool
    }

    struct MotionActivityPayload: Encodable {
        let activities: [MotionActivityEntry]
    }

    struct PedometerPayload: Encodable {
        let startISO: String
        let endISO: String
        let steps: Int?
        let distanceMeters: Double?
        let floorsAscended: Int?
        let floorsDescended: Int?
    }

    // MARK: - health.summary

    struct HealthSummaryParams: Decodable {
        let period: String?
    }

    // MARK: - camera

    struct CameraDevicePayload: Encodable {
        let id: String
        let name: String
        let position: String
        let deviceType: String
    }

    struct CameraListPayload: Encodable {
        let devices: [CameraDevicePayload]
    }

    struct CameraSnapPayload: Encodable {
        let format: String
        let base64: String
        let width: Int
        let height: Int
    }

    // MARK: - canvas

    struct CanvasEvalPayload: Encodable {
        let result: String?
    }

    struct CanvasSnapshotPayload: Encodable {
        let format: String
        let base64: String
    }

    struct A2UIPushParams: Decodable {
        let messages: [AnyCodable]?
        let jsonl: String?
    }

    struct A2UIPushJSONLParams: Decodable {
        let jsonl: String?
    }

    // MARK: - chat.push

    struct ChatPushParams: Decodable {
        let text: String
        let speak: Bool?
    }

    struct ChatPushPayload: Encodable {
        let messageId: String?
    }
}
