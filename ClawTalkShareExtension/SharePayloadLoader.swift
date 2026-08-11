import Foundation
import UIKit
import UniformTypeIdentifiers

/// 一次分享的内容：文本/URL + 附件（附件已复制进 App Group 容器）。
struct SharePayload {
    var text: String = ""
    var attachments: [PendingShareAttachment] = []
    var hasContent: Bool {
        !text.isEmpty || !attachments.isEmpty
    }
}

/// 从系统分享上下文收集 text/url/image/file，附件落盘到 App Group 容器。
struct SharePayloadLoader {
    func load(from context: NSExtensionContext?, completion: @escaping (SharePayload) -> Void) {
        guard let items = context?.inputItems as? [NSExtensionItem], !items.isEmpty else {
            completion(SharePayload())
            return
        }

        var providers: [NSItemProvider] = []
        for item in items {
            if let attachments = item.attachments {
                providers.append(contentsOf: attachments)
            }
        }

        // URL 优先于纯文本（分享链接时系统常同时提供两者）
        let urlProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        let otherProviders = providers.filter { !$0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }

        var payload = SharePayload()
        let group = DispatchGroup()
        let lock = NSLock()

        func handleText(_ text: String) {
            lock.lock()
            if payload.text.isEmpty {
                payload.text = text
            }
            lock.unlock()
        }

        for provider in urlProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    handleText(url.absoluteString)
                }
                group.leave()
            }
        }

        for provider in otherProviders {
            if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                    if let text = item as? String {
                        handleText(text)
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                loadImage(provider) { attachment in
                    if let attachment {
                        lock.lock()
                        payload.attachments.append(attachment)
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                loadFile(provider) { attachment in
                    if let attachment {
                        lock.lock()
                        payload.attachments.append(attachment)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(payload)
        }
    }

    private func loadImage(_ provider: NSItemProvider, completion: @escaping (PendingShareAttachment?) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
            var data: Data?
            if let url = item as? URL {
                data = try? Data(contentsOf: url)
            } else if let image = item as? UIImage {
                data = image.jpegData(compressionQuality: 0.9)
            } else if let raw = item as? Data {
                data = raw
            }
            guard let data else {
                completion(nil)
                return
            }
            let ext = imageExtension(for: provider)
            let fileName = "image-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
            completion(ShareContainer.save(data: data, fileName: fileName, mimeType: "image/\(ext)"))
        }
    }

    private func loadFile(_ provider: NSItemProvider, completion: @escaping (PendingShareAttachment?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, _ in
            guard let url else {
                completion(nil)
                return
            }
            let attachment = ShareContainer.copy(from: url, fileName: url.lastPathComponent)
            completion(attachment)
        }
    }

    private func imageExtension(for provider: NSItemProvider) -> String {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if type.conforms(to: .image), let ext = type.preferredFilenameExtension {
                return ext
            }
        }
        return "jpg"
    }
}

/// App Group 容器写入工具：附件统一放 container/ShareUploads/。
enum ShareContainer {
    static func directory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareAppGroup.containerID
        ) else {
            return nil
        }
        let dir = container.appendingPathComponent(ShareAppGroup.attachmentsDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(data: Data, fileName: String, mimeType: String) -> PendingShareAttachment? {
        guard let dir = directory() else { return nil }
        let dest = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: dest, options: .atomic)
            return PendingShareAttachment(fileName: fileName, containerPath: dest.path, mimeType: mimeType)
        } catch {
            return nil
        }
    }

    static func copy(from sourceURL: URL, fileName: String) -> PendingShareAttachment? {
        guard let dir = directory() else { return nil }
        let mimeType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let dest = dir.appendingPathComponent(fileName)
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return PendingShareAttachment(fileName: fileName, containerPath: dest.path, mimeType: mimeType)
        } catch {
            return nil
        }
    }
}