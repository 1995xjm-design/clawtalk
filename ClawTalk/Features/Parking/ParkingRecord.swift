import Foundation

/// 停车记录：坐标 + 反向地址 + 备注 + 本地照片文件名 + 记录时间。
/// 照片文件存于 Application Support/ClawTalk/ParkingPhotos/，模型只存文件名（与完整路径解耦）。
struct ParkingRecord: Identifiable, Codable, Equatable {
    let id: String
    var latitude: Double
    var longitude: Double
    var address: String?
    var note: String?
    var photoPath: String?
    var recordedAt: Date

    init(
        id: String = UUID().uuidString,
        latitude: Double,
        longitude: Double,
        address: String? = nil,
        note: String? = nil,
        photoPath: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.note = note
        self.photoPath = photoPath
        self.recordedAt = recordedAt
    }
}
