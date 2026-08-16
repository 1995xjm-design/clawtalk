import AVFoundation
import Contacts
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import Photos
import ReplayKit
import Speech

/// Mirror of official `GatewayConnectionController.currentPermissions()`:
/// a `[String: Bool]` map of runtime authorization states advertised to the
/// gateway during the connect handshake (node sessions).
enum GatewayPermissions {
    static func current() async -> [String: Bool] {
        var permissions: [String: Bool] = [:]
        permissions["camera"] = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        permissions["microphone"] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        permissions["speechRecognition"] = SFSpeechRecognizer.authorizationStatus() == .authorized

        let locationStatus = CLLocationManager.authorizationStatus()
        permissions["location"] = isLocationAvailable(servicesEnabled: CLLocationManager.locationServicesEnabled(), status: locationStatus)

        permissions["screenRecording"] = RPScreenRecorder.shared().isAvailable

        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var photosAuthorized = photoStatus == .authorized
        if #available(iOS 18.0, *) {
            photosAuthorized = photosAuthorized || photoStatus == .limited
        }
        permissions["photos"] = photosAuthorized

        let contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        permissions["contacts"] = contactsStatus == .authorized || contactsStatus == .limited

        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        permissions["calendar"] = hasEventKitReadAccess(calendarStatus)

        let remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        permissions["reminders"] = hasEventKitReadAccess(remindersStatus)

        let motionManager = CMMotionActivityManager()
        permissions["motion"] = CMMotionActivityManager.isActivityAvailable()
        _ = motionManager

        return permissions
    }

    private static func isLocationAvailable(servicesEnabled: Bool, status: CLAuthorizationStatus) -> Bool {
        servicesEnabled && (status == .authorizedAlways || status == .authorizedWhenInUse)
    }

    private static func hasEventKitReadAccess(_ status: EKAuthorizationStatus) -> Bool {
        status == .authorized || status == .fullAccess
    }
}
