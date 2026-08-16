import Foundation
import OSLog
import UIKit
import UserNotifications

/// Manages a WebSocket connection with role "node", allowing the agent
/// to invoke device capabilities (device info, notifications, etc.).
@Observable
@MainActor
final class NodeConnection {

    enum State: Sendable {
        case disconnected
        case connecting
        case connected
    }

    private(set) var connectionState: State = .disconnected
    private(set) var lastError: String?

    /// Callback to inject images directly into the active chat.
    /// Set by the app when a ChatViewModel is active.
    var onImagesReceived: (([Data], String?) -> Void)?

    private let logger = Logger(subsystem: "com.openclaw.clawtalk", category: "node-conn")
    private var gateway: GatewayWebSocket?

    // MARK: - Invoke lifecycle (P2: cancel / input / timeout)

    private var activeInvokes: [String: Task<Void, Never>] = [:]
    private var invokeInputHandlers: [String: @MainActor (String) async -> Void] = [:]

    private static let defaultInvokeTimeoutMs = 30_000
    private static let maxInvokeTimeoutMs = 120_000
    private static let foregroundRestrictedPrefixes = ["canvas.", "camera.", "screen.", "talk."]

    // MARK: - Capabilities

    private static let declaredCaps = [
        "device", "notifications", "location", "contacts",
        "calendar", "reminders", "motion", "photos", "camera",
        "screen", "canvas", "voice",
        "health", "media", "watch", "talk",
    ]
    private static let declaredCommands = [
        "device.status", "device.info",
        "system.notify",
        "location.get",
        "contacts.search", "contacts.add",
        "calendar.events", "calendar.add",
        "reminders.list", "reminders.add",
        "motion.activity", "motion.pedometer",
        "photos.latest",
        "camera.list", "camera.snap",
        "screen.snapshot",
        "canvas.present", "canvas.navigate",
        "canvas.evalJS", "canvas.snapshot", "canvas.reset",
        "canvas.a2ui.reset", "canvas.a2ui.push", "canvas.a2ui.pushJSONL",
        "chat.push",
        "watch.status", "watch.notify",
        "talk.ptt.start", "talk.ptt.stop", "talk.ptt.cancel", "talk.ptt.once",
        "voicewake.set", "voicewake.get",
        "health.steps",
        "media.list",
    ]

    // MARK: - Connect

    func connect(resolvedURL: String, token: String) async {
        guard let wsURL = URL(string: resolvedURL) else {
            lastError = "Invalid WebSocket URL"
            return
        }

        if let existing = gateway {
            await existing.shutdown()
        }

        connectionState = .connecting
        lastError = nil
        logger.info("node connecting to \(wsURL.absoluteString, privacy: .public)")

        // TLS first-trust gate (TOFU): prompt before trusting an untrusted wss host.
        if wsURL.scheme?.lowercased() == "wss",
           let host = wsURL.host,
           !(await TLSFingerprintGate.shared.ensureTrust(host: host, port: wsURL.port ?? 443))
        {
            connectionState = .disconnected
            lastError = "未信任网关证书，已取消连接"
            LogCollector.record(module: "节点连接", lastError ?? "")
            return
        }

        let gw = GatewayWebSocket(
            url: wsURL,
            token: token,
            role: "node",
            scopes: [],
            caps: Self.declaredCaps,
            commands: Self.declaredCommands,
            clientMode: "node",
            pushHandler: { [weak self] push in
                await self?.handlePush(push)
            },
            stateHandler: { [weak self] state in
                await self?.handleStateChange(state)
            }
        )
        gateway = gw

        do {
            try await gw.connect()
            connectionState = .connected
            logger.info("node connected")
        } catch {
            logger.error("node connect failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .disconnected
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        for task in activeInvokes.values {
            task.cancel()
        }
        activeInvokes.removeAll()
        if let gw = gateway {
            await gw.shutdown()
        }
        gateway = nil
        connectionState = .disconnected
    }

    // MARK: - Event Handling

    private func handlePush(_ push: GatewayWebSocket.Push) async {
        switch push {
        case .snapshot:
            logger.info("node snapshot received")
        case .event(let evt):
            switch evt.event {
            case "node.invoke.request":
                await handleInvokeRequest(evt)
            case "node.invoke.cancel":
                await handleInvokeCancel(evt)
            case "node.invoke.input":
                await handleInvokeInput(evt)
            default:
                break
            }
        case .seqGap(let expected, let received):
            logger.warning("node event sequence gap: expected \(expected), got \(received)")
        }
    }

    private func handleStateChange(_ state: GatewayWebSocket.ConnectionState) {
        let newState: State = switch state {
        case .connected: .connected
        case .connecting: .connecting
        case .disconnected: .disconnected
        }
        connectionState = newState
    }

    // MARK: - Invoke Dispatch (P2)

    private func handleInvokeRequest(_ evt: EventFrame) async {
        guard let payload = evt.payload,
              let data = try? JSONEncoder().encode(payload),
              let request = try? JSONDecoder().decode(NodeInvokeRequest.self, from: data)
        else {
            logger.error("failed to decode node.invoke.request")
            return
        }

        logger.info("node.invoke: \(request.command, privacy: .public) id=\(request.id, privacy: .public)")

        // Background restriction mirrors official NodeAppModel.handleInvoke.
        if isBackgrounded(),
           Self.foregroundRestrictedPrefixes.contains(where: { request.command.hasPrefix($0) })
        {
            await sendInvokeResult(request, NodeInvokeResult(
                id: request.id,
                nodeId: request.nodeId,
                ok: false,
                payloadJSON: nil,
                error: NodeInvokeError(
                    code: "NODE_BACKGROUND_UNAVAILABLE",
                    message: "NODE_BACKGROUND_UNAVAILABLE: canvas/camera/screen/talk commands require foreground"))
            )
            return
        }

        let task = Task { [weak self] in
            await self?.runInvoke(request)
        }
        activeInvokes[request.id] = task
        await task.value
        activeInvokes.removeValue(forKey: request.id)
    }

    private func runInvoke(_ request: NodeInvokeRequest) async {
        let result: NodeInvokeResult
        do {
            let response = try await invokeWithTimeout(request)
            guard !Task.isCancelled else { return }
            result = NodeInvokeResult(
                id: request.id,
                nodeId: request.nodeId,
                ok: true,
                payloadJSON: response,
                error: nil
            )
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            result = NodeInvokeResult(
                id: request.id,
                nodeId: request.nodeId,
                ok: false,
                payloadJSON: nil,
                error: NodeInvokeError(code: "UNAVAILABLE", message: "node invoke cancelled")
            )
        } catch let error as NodeError {
            result = NodeInvokeResult(
                id: request.id,
                nodeId: request.nodeId,
                ok: false,
                payloadJSON: nil,
                error: NodeInvokeError(code: error.code, message: error.message)
            )
        } catch {
            result = NodeInvokeResult(
                id: request.id,
                nodeId: request.nodeId,
                ok: false,
                payloadJSON: nil,
                error: NodeInvokeError(code: "UNAVAILABLE", message: error.localizedDescription)
            )
        }
        await sendInvokeResult(request, result)
    }

    private func sendInvokeResult(_ request: NodeInvokeRequest, _ result: NodeInvokeResult) async {
        do {
            guard let gw = gateway else { return }
            let resultData = try JSONEncoder().encode(result)
            let resultCodable = try JSONDecoder().decode(AnyCodable.self, from: resultData)
            let paramsDict = resultCodable.dictValue ?? [:]
            _ = try await gw.request(method: "node.invoke.result", params: paramsDict)
        } catch {
            logger.error("failed to send invoke result: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// node.invoke.cancel: cancel the running task for the given invoke id.
    private func handleInvokeCancel(_ evt: EventFrame) async {
        guard let payload = evt.payload,
              let data = try? JSONEncoder().encode(payload),
              let cancel = try? JSONDecoder().decode(NodeInvokeCancelPayload.self, from: data)
        else {
            return
        }
        logger.info("node.invoke.cancel: \(cancel.invokeId, privacy: .public)")
        activeInvokes[cancel.invokeId]?.cancel()
        activeInvokes.removeValue(forKey: cancel.invokeId)
        // Interrupt any in-flight talk PTT capture (e.g. talk.ptt.once on VAD).
        TalkCapability.shared.cancelActive()
    }

    /// node.invoke.input: route realtime input to the active invoke (talk PTT).
    private func handleInvokeInput(_ evt: EventFrame) async {
        guard let payload = evt.payload,
              let data = try? JSONEncoder().encode(payload),
              let input = try? JSONDecoder().decode(NodeInvokeInputEvent.self, from: data)
        else {
            return
        }
        logger.info("node.invoke.input id=\(input.id, privacy: .public) seq=\(input.seq, privacy: .public)")
        await invokeInputHandlers[input.id]?(input.payloadJSON)
    }

    private func isBackgrounded() -> Bool {
        UIApplication.shared.applicationState != .active
    }

    /// Race dispatchCommand against timeoutMs (mirrors GatewayNodeSession+InvokeTimeout).
    /// The latch settles on the first outcome so a stuck command cannot hold the
    /// connection; the invoke task is cancelled best-effort afterwards.
    private func invokeWithTimeout(_ request: NodeInvokeRequest) async throws -> String? {
        let rawTimeout = request.timeoutMs ?? Self.defaultInvokeTimeoutMs
        let timeoutMs = min(max(0, rawTimeout), Self.maxInvokeTimeoutMs)
        guard timeoutMs > 0 else { return try await dispatchCommand(request) }

        let latch = InvokeResultLatch()
        let invokeTask = Task {
            do {
                let result = try await self.dispatchCommand(request)
                latch.resume(.success(result))
            } catch {
                latch.resume(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                latch.resume(.failure(NodeError.timeout))
            } catch {
                // Cancelled because the invoke settled first.
            }
        }
        defer {
            invokeTask.cancel()
            timeoutTask.cancel()
        }
        return try await latch.wait().get()
    }

    /// First-settled-wins latch for invoke timeouts (same shape as official InvokeLatch).
    private final class InvokeResultLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<String?, Error>, Never>?
        private var stored: Result<String?, Error>?
        private var resumed = false

        func resume(_ value: Result<String?, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            stored = value
            continuation?.resume(returning: value)
            continuation = nil
        }

        func wait() async -> Result<String?, Error> {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<String?, Error>, Never>) in
                lock.lock()
                defer { lock.unlock() }
                if resumed, let stored {
                    cont.resume(returning: stored)
                } else {
                    continuation = cont
                }
            }
        }
    }

    // MARK: - Command Dispatch

    private func dispatchCommand(_ request: NodeInvokeRequest) async throws -> String? {
        switch request.command {
        // Device
        case "device.info":
            return try encodeJSON(DeviceInfoCapability.getInfo())
        case "device.status":
            return try await encodeJSON(DeviceInfoCapability.getStatus())

        // Notifications
        case "system.notify":
            let params = request.decodedParams(as: SystemNotifyParams.self)
            try await NotificationCapability.notify(
                title: params?.title,
                body: params?.body,
                sound: params?.sound,
                priority: params?.priority,
                delivery: params?.delivery
            )
            return "{\"ok\":true}"

        // Location
        case "location.get":
            let result = try await LocationCapability.getLocation()
            let payload = NodePayloads.LocationPayload(
                lat: result.latitude,
                lon: result.longitude,
                accuracyMeters: result.horizontalAccuracy,
                altitudeMeters: result.altitude != 0 ? result.altitude : nil,
                speedMps: result.speed > 0 ? result.speed : nil,
                headingDeg: result.course >= 0 ? result.course : nil,
                timestamp: result.timestamp,
                isPrecise: result.horizontalAccuracy > 0 && result.horizontalAccuracy < 100,
                source: "gps"
            )
            return try encodeJSON(payload)

        // Contacts
        case "contacts.search":
            let params = request.decodedParams(as: ContactsSearchParams.self)
            let results = try await ContactsCapability.search(
                query: params?.query ?? "",
                limit: params?.limit ?? 20
            )
            return try encodeJSON(results)
        case "contacts.add":
            let params = request.decodedParams(as: ContactsAddParams.self)
            let result = try await ContactsCapability.addContact(
                givenName: params?.givenName,
                familyName: params?.familyName,
                phoneNumber: params?.phoneNumber,
                email: params?.email,
                organization: params?.organization,
                organizationName: params?.organizationName,
                displayName: params?.displayName,
                phoneNumbers: params?.phoneNumbers,
                emails: params?.emails
            )
            return try encodeJSON(result)

        // Calendar
        case "calendar.events":
            let params = request.decodedParams(as: CalendarEventsParams.self)
            let (daysBack, daysAhead) = Self.calendarRange(params: params)
            let events = try await CalendarCapability.listEvents(daysAhead: daysAhead, daysBack: daysBack)
            let payload = NodePayloads.CalendarEventsPayload(events: events.map {
                NodePayloads.CalendarEventPayload(
                    identifier: $0.identifier,
                    title: $0.title,
                    startISO: $0.startDate,
                    endISO: $0.endDate,
                    isAllDay: $0.isAllDay,
                    location: $0.location,
                    calendarTitle: $0.calendarName
                )
            })
            return try encodeJSON(payload)
        case "calendar.add":
            guard let params = request.decodedParams(as: CalendarAddParams.self),
                  let start = params.resolvedStart
            else {
                throw NodeError.invalidRequest("missing calendar event start")
            }
            let result = try await CalendarCapability.addEvent(
                title: params.title,
                startDate: start,
                endDate: params.resolvedEnd,
                location: params.location,
                notes: params.notes,
                isAllDay: params.isAllDay,
                calendarId: params.calendarId,
                calendarTitle: params.calendarTitle
            )
            let payload = NodePayloads.CalendarAddPayload(event: NodePayloads.CalendarEventPayload(
                identifier: result.identifier,
                title: params.title,
                startISO: start,
                endISO: params.resolvedEnd ?? start,
                isAllDay: params.isAllDay ?? false,
                location: params.location,
                calendarTitle: params.calendarTitle
            ))
            return try encodeJSON(payload)

        // Reminders
        case "reminders.list":
            let params = request.decodedParams(as: RemindersListParams.self)
            let completed: Bool? = {
                switch params?.status {
                case "completed": return true
                case "incomplete": return false
                default: return params?.completed
                }
            }()
            let reminders = try await RemindersCapability.list(completed: completed, limit: params?.limit ?? 50)
            let payload = NodePayloads.RemindersListPayload(reminders: reminders.map {
                NodePayloads.ReminderPayload(
                    identifier: $0.identifier,
                    title: $0.title,
                    dueISO: $0.dueDate,
                    completed: $0.isCompleted,
                    listName: $0.listName
                )
            })
            return try encodeJSON(payload)
        case "reminders.add":
            guard let params = request.decodedParams(as: RemindersAddParams.self) else {
                throw NodeError.invalidRequest("missing reminder params")
            }
            let result = try await RemindersCapability.add(
                title: params.title,
                dueDate: params.resolvedDue.flatMap { ISO8601DateFormatter().date(from: $0) },
                notes: params.notes,
                priority: params.priority ?? 0,
                listId: params.listId,
                listName: params.listName
            )
            let payload = NodePayloads.RemindersAddPayload(reminder: NodePayloads.ReminderPayload(
                identifier: result.identifier,
                title: params.title,
                dueISO: params.resolvedDue,
                completed: false,
                listName: params.listName
            ))
            return try encodeJSON(payload)

        // Health
        case "health.summary":
            let params = request.decodedParams(as: NodePayloads.HealthSummaryParams.self)
            let summary = try await HealthCapability.summary(period: params?.period ?? "today")
            return try encodeJSON(summary)
        case "health.steps":
            let params = request.decodedParams(as: HealthStepsParams.self)
            let result = try await HealthCapability.steps(days: params?.days ?? 7)
            return try encodeJSON(result)

        // Media
        case "media.list":
            let params = request.decodedParams(as: MediaListParams.self)
            let items = try await MediaCapability.recent(count: params?.count ?? 20)
            return try encodeJSON(items)

        // Motion
        case "motion.activity":
            let params = request.decodedParams(as: MotionActivityParams.self)
            let hours = Self.hours(fromStart: params?.startISO, end: params?.endISO, fallback: params?.hours ?? 1)
            let activities = try await MotionCapability.getActivity(hours: hours)
            let payload = NodePayloads.MotionActivityPayload(activities: activities.map {
                NodePayloads.MotionActivityEntry(
                    startISO: $0.startDate,
                    endISO: $0.endDate,
                    confidence: $0.confidence,
                    isWalking: $0.walking,
                    isRunning: $0.running,
                    isCycling: $0.cycling,
                    isAutomotive: $0.automotive,
                    isStationary: $0.stationary,
                    isUnknown: $0.unknown
                )
            })
            return try encodeJSON(payload)
        case "motion.pedometer":
            let params = request.decodedParams(as: MotionPedometerParams.self)
            let hours = Self.hours(fromStart: params?.startISO, end: params?.endISO, fallback: params?.hours ?? 24)
            let data = try await MotionCapability.getPedometer(hours: hours)
            let payload = NodePayloads.PedometerPayload(
                startISO: data.startDate,
                endISO: data.endDate,
                steps: data.steps,
                distanceMeters: data.distance,
                floorsAscended: data.floorsAscended,
                floorsDescended: data.floorsDescended
            )
            return try encodeJSON(payload)

        // Photos
        case "photos.latest":
            let params = request.decodedParams(as: PhotosLatestParams.self)
            let photos = try await PhotosCapability.getLatest(
                count: params?.limit ?? params?.count ?? 5,
                includeImage: params?.includeImage ?? true,
                maxWidth: params?.maxWidth ?? 512
            )
            // Inject images directly into chat
            let imageDataList = photos.compactMap { $0.imageBase64.flatMap { Data(base64Encoded: $0) } }
            if !imageDataList.isEmpty {
                onImagesReceived?(imageDataList, nil)
            }
            let payload = NodePayloads.PhotosLatestPayload(photos: photos.map {
                NodePayloads.PhotoPayload(
                    format: "jpeg",
                    base64: $0.imageBase64 ?? "",
                    width: $0.width,
                    height: $0.height,
                    createdAt: $0.creationDate
                )
            })
            return try encodeJSON(payload)

        // Camera
        case "camera.list":
            let devices = CameraCapability.listCameras()
            let payload = NodePayloads.CameraListPayload(devices: devices.map {
                NodePayloads.CameraDevicePayload(
                    id: $0.id,
                    name: $0.name,
                    position: $0.position,
                    deviceType: $0.deviceType
                )
            })
            return try encodeJSON(payload)
        case "camera.snap":
            let params = request.decodedParams(as: CameraSnapParams.self)
            let result = try await CameraCapability.snap(
                camera: params?.camera,
                facing: params?.facing ?? "front",
                quality: params?.quality ?? 0.8,
                maxWidth: params?.maxWidth ?? 1600,
                format: CameraCapability.CameraImageFormat(rawValue: params?.format ?? "") ?? .jpeg,
                deviceId: params?.deviceId,
                delayMs: params?.delayMs ?? 0
            )
            // Inject image directly into chat
            if let imageData = Data(base64Encoded: result.imageBase64) {
                onImagesReceived?([imageData], nil)
            }
            let payload = NodePayloads.CameraSnapPayload(
                format: result.format == "jpg" ? "jpeg" : result.format,
                base64: result.imageBase64,
                width: result.width,
                height: result.height
            )
            return try encodeJSON(payload)

        // Camera Clip
        case "camera.clip":
            let params = request.decodedParams(as: CameraClipParams.self)
            let result = try await CameraCapability.clip(
                camera: params?.camera,
                facing: params?.facing,
                durationMs: params?.durationMs,
                includeAudio: params?.includeAudio,
                format: CameraCapability.CameraVideoFormat(rawValue: params?.format ?? "") ?? .mp4,
                deviceId: params?.deviceId
            )
            return try encodeJSON(result)

        // Screen
        case "screen.snapshot":
            let params = request.decodedParams(as: ScreenSnapshotParams.self)
            let result = try await ScreenCapability.snapshot(
                maxWidth: params?.maxWidth ?? 1024,
                quality: params?.quality ?? 0.8,
                format: ScreenCapability.ScreenSnapshotFormat(rawValue: params?.format ?? "") ?? .jpeg
            )
            return try encodeJSON(result)

        // Screen Record
        case "screen.record":
            let params = request.decodedParams(as: ScreenRecordParams.self)
            let result = try await ScreenCapability.record(
                screenIndex: params?.screenIndex,
                durationMs: params?.durationMs,
                fps: params?.fps,
                includeAudio: params?.includeAudio
            )
            return try encodeJSON(result)

        // Canvas
        case "canvas.present":
            guard let params = request.decodedParams(as: CanvasPresentParams.self) else {
                throw NodeError.invalidRequest("missing canvas URL")
            }
            let result = try await CanvasCapability.shared.present(url: params.url)
            return try encodeJSON(result)
        case "canvas.navigate":
            guard let params = request.decodedParams(as: CanvasPresentParams.self) else {
                throw NodeError.invalidRequest("missing canvas URL")
            }
            let result = try await CanvasCapability.shared.navigate(url: params.url)
            return try encodeJSON(result)
        case "canvas.eval", "canvas.evalJS":
            let params = request.decodedParams(as: CanvasEvalParams.self)
            guard let script = params?.resolvedScript else {
                throw NodeError.invalidRequest("missing javaScript")
            }
            let result = try await CanvasCapability.shared.evalJS(script: script)
            return try encodeJSON(NodePayloads.CanvasEvalPayload(result: result.result))
        case "canvas.hide":
            CanvasCapability.shared.hide()
            return "{\"ok\":true}"
        case "canvas.snapshot":
            let params = request.decodedParams(as: CanvasSnapshotParams.self)
            let snapFormat = CanvasCapability.SnapshotFormat(rawValue: params?.format ?? "") ?? .jpeg
            let defaultMaxWidth = snapFormat == .png ? 900 : 1600
            let result = try await CanvasCapability.shared.snapshot(
                maxWidth: params?.maxWidth ?? defaultMaxWidth,
                quality: params?.quality ?? 0.8,
                format: snapFormat
            )
            return try encodeJSON(NodePayloads.CanvasSnapshotPayload(format: result.format, base64: result.imageBase64))
        case "canvas.reset":
            CanvasCapability.shared.reset()
            return "{\"ok\":true}"
        case "canvas.a2ui.reset":
            do {
                return try await CanvasCapability.shared.a2uiReset()
            } catch {
                throw NodeError.unavailable("A2UI_HOST_UNAVAILABLE: \(error.localizedDescription)")
            }
        case "canvas.a2ui.push":
            let params = request.decodedParams(as: NodePayloads.A2UIPushParams.self)
            if let messages = params?.messages {
                return try await CanvasCapability.shared.a2uiPush(messagesJSON: Self.encodeMessagesJSON(messages))
            }
            if let jsonl = params?.jsonl {
                return try await CanvasCapability.shared.a2uiPushJSONL(jsonl: jsonl)
            }
            throw NodeError.invalidRequest("missing a2ui messages")
        case "canvas.a2ui.pushJSONL":
            guard let params = request.decodedParams(as: NodePayloads.A2UIPushJSONLParams.self),
                  let jsonl = params.jsonl
            else {
                throw NodeError.invalidRequest("missing jsonl")
            }
            return try await CanvasCapability.shared.a2uiPushJSONL(jsonl: jsonl)

        // Voice Wake
        case "voicewake.set":
            let params = request.decodedParams(as: VoiceWakeSetParams.self)
            let result = try await VoiceWakeCapability.shared.setConfig(
                keywords: params?.keywords ?? [],
                enabled: params?.enabled ?? true,
                locale: params?.locale
            )
            return try encodeJSON(result)
        case "voicewake.get":
            return try encodeJSON(VoiceWakeCapability.shared.getConfig())

        // Watch
        case "watch.status":
            return try encodeJSON(WatchCapability.status())
        case "watch.notify":
            guard let params = request.decodedParams(as: WatchCapability.NotifyParams.self) else {
                throw NodeError.invalidRequest("missing watch.notify params")
            }
            if params.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               params.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw NodeError.invalidRequest("empty watch notification")
            }
            let result = try WatchCapability.notify(params: params)
            return try encodeJSON(result)

        // Talk
        case "talk.ptt.start":
            let result = try TalkCapability.shared.start()
            // Closure literal inherits @MainActor from the contextual type.
            invokeInputHandlers[request.id] = { payload in
                await self.handleTalkInput(payload)
            }
            return try encodeJSON(result)
        case "talk.ptt.stop":
            defer { invokeInputHandlers.removeValue(forKey: request.id) }
            let result = try await TalkCapability.shared.stop()
            return try encodeJSON(result)
        case "talk.ptt.cancel":
            defer { invokeInputHandlers.removeValue(forKey: request.id) }
            let result = try TalkCapability.shared.cancel()
            return try encodeJSON(result)
        case "talk.ptt.once":
            let result = try await TalkCapability.shared.once()
            return try encodeJSON(result)

        // Chat
        case "chat.push":
            let params = request.decodedParams(as: NodePayloads.ChatPushParams.self)
            let text = (params?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw NodeError.invalidRequest("empty chat.push text")
            }
            let shouldSpeak = params?.speak ?? true
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let notificationsAllowed: Bool = {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: return true
                default: return false
                }
            }()
            if !notificationsAllowed, !shouldSpeak {
                throw NodeError.notAuthorized("notifications")
            }
            let messageId = UUID().uuidString
            if notificationsAllowed {
                let content = UNMutableNotificationContent()
                content.title = "OpenClaw"
                content.body = text
                content.sound = .default
                content.userInfo = ["messageId": messageId]
                do {
                    try await UNUserNotificationCenter.current().add(
                        UNNotificationRequest(identifier: messageId, content: content, trigger: nil))
                } catch {
                    throw NodeError.notificationFailed(error.localizedDescription)
                }
            }
            if shouldSpeak {
                TalkCapability.speak(text: text)
            }
            return try encodeJSON(NodePayloads.ChatPushPayload(messageId: messageId))

        default:
            throw NodeError.unknownCommand(request.command)
        }
    }

    /// Realtime input routed to an active talk.ptt invoke (plumbing for gateway audio input).
    private func handleTalkInput(_ payloadJSON: String) async {
        guard let data = payloadJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let action = dict["action"]?.lowercased()
        else { return }
        switch action {
        case "stop", "cancel":
            try? TalkCapability.shared.cancel()
        default:
            break
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Helpers

    private static func calendarRange(params: CalendarEventsParams?) -> (daysBack: Int, daysAhead: Int) {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        var daysBack = params?.daysBack ?? 0
        var daysAhead = params?.daysAhead ?? 7
        if let startISO = params?.startISO, let start = formatter.date(from: startISO) {
            daysBack = max(0, Int(now.timeIntervalSince(start) / 86_400))
        }
        if let endISO = params?.endISO, let end = formatter.date(from: endISO) {
            daysAhead = max(0, Int(end.timeIntervalSince(now) / 86_400))
        }
        return (daysBack, daysAhead)
    }

    private static func hours(fromStart startISO: String?, end endISO: String?, fallback: Int) -> Int {
        let formatter = ISO8601DateFormatter()
        guard let startISO, let start = formatter.date(from: startISO) else { return fallback }
        let end = endISO.flatMap { formatter.date(from: $0) } ?? Date()
        let seconds = max(0, end.timeIntervalSince(start))
        return max(1, Int(ceil(seconds / 3600)))
    }

    private static func encodeMessagesJSON(_ messages: [AnyCodable]) -> String {
        guard let data = try? JSONEncoder().encode(messages),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

// MARK: - Protocol Types

struct NodeInvokeRequest: Decodable {
    let id: String
    let nodeId: String
    let command: String
    let paramsJSON: String?
    let timeoutMs: Int?
    let idempotencyKey: String?

    func decodedParams<T: Decodable>(as type: T.Type) -> T? {
        guard let json = paramsJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct NodeInvokeResult: Encodable {
    let id: String
    let nodeId: String
    let ok: Bool
    let payloadJSON: String?
    let error: NodeInvokeError?
}

struct NodeInvokeError: Encodable {
    let code: String
    let message: String
}

/// node.invoke.cancel payload: { invokeId }
struct NodeInvokeCancelPayload: Decodable {
    let invokeId: String

    private enum CodingKeys: String, CodingKey {
        case invokeId = "invokeId"
    }
}

/// node.invoke.input payload: { id, nodeId, seq, payloadJSON }
struct NodeInvokeInputEvent: Decodable {
    let id: String
    let nodeId: String
    let seq: Int
    let payloadJSON: String

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeId = "nodeId"
        case seq
        case payloadJSON = "payloadJSON"
    }
}

enum NodeError: LocalizedError {
    case unknownCommand(String)
    case invalidRequest(String)
    case unavailable(String)
    case timeout
    case notAuthorized(String)
    case notificationFailed(String)

    var code: String {
        switch self {
        case .unknownCommand, .invalidRequest:
            return "INVALID_REQUEST"
        case .timeout, .unavailable, .notAuthorized, .notificationFailed:
            return "UNAVAILABLE"
        }
    }

    var message: String {
        switch self {
        case .unknownCommand(let cmd):
            return "INVALID_REQUEST: unknown command \(cmd)"
        case .invalidRequest(let msg):
            return "INVALID_REQUEST: \(msg)"
        case .unavailable(let msg):
            return msg
        case .timeout:
            return "node invoke timed out"
        case .notAuthorized(let msg):
            return "NOT_AUTHORIZED: \(msg)"
        case .notificationFailed(let msg):
            return "NOTIFICATION_FAILED: \(msg)"
        }
    }

    var errorDescription: String? { message }
}

// MARK: - System Notify Params

struct SystemNotifyParams: Decodable {
    let title: String?
    let body: String?
    let sound: String?
    let priority: String?
    let delivery: String?
}

// MARK: - Health/Media Params

struct HealthStepsParams: Decodable {
    let days: Int?
}

struct MediaListParams: Decodable {
    let count: Int?
}
