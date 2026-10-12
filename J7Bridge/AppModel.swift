import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var bleStatus = "Disconnected"
    @Published var wifiStatus = "Stopped"
    @Published var j7Host: String {
        didSet {
            UserDefaults.standard.set(j7Host, forKey: "j7bridge.j7Host")
            wifiTransport.setJ7Host(j7Host)
        }
    }
    @Published var deviceName = "-"
    @Published var callStatus = "IDLE"
    @Published var number = ""
    @Published var callerName = ""
    @Published var voiceStatus = "CLOSED"
    @Published var dialString = ""
    @Published var logs: [String] = []
    @Published var battery = "-"
    @Published var firmware = "-"
    @Published var imei = "-"
    @Published var isMuted = false
    @Published private(set) var callStartedAt: Date?

    @Published var autoConnect: Bool {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "j7bridge.autoConnect")
            ble.autoReconnect = autoConnect
        }
    }
    @Published var resolveCallerNames: Bool {
        didSet { UserDefaults.standard.set(resolveCallerNames, forKey: "j7bridge.resolveCallerNames") }
    }
    @Published var missedCallNotifications: Bool {
        didSet { UserDefaults.standard.set(missedCallNotifications, forKey: "j7bridge.missedCallNotifications") }
    }
    @Published var speakerDefault: Bool {
        didSet {
            UserDefaults.standard.set(speakerDefault, forKey: "j7bridge.speakerDefault")
            wifiVoice.setSpeakerDefault(speakerDefault)
        }
    }
    @Published var simSlot: Int {
        didSet { UserDefaults.standard.set(simSlot, forKey: "j7bridge.simSlot") }
    }

    let ble: BLEManager
    let callKit: CallKitManager
    let wifiTransport: WiFiTransport
    let wifiVoice: WiFiVoiceEngine
    let contacts: ContactsManager
    let history: CallHistoryStore
    let notifications = NotificationManager()

    private var currentDirection: CallDirection?
    private var currentContactName: String?
    private var callAudioActive = false
    private var remoteVoiceOpen = false
    private var ignoredBLEAudioFrames = 0
    private struct PendingSMSAssembly {
        var expectedCount: Int
        var sender: String
        var chunks: [Int: Data]
        var lastUpdated: Date
    }
    private var pendingSMS: [UInt16: PendingSMSAssembly] = [:]

    init() {
        autoConnect = UserDefaults.standard.object(forKey: "j7bridge.autoConnect") as? Bool ?? true
        resolveCallerNames = UserDefaults.standard.object(forKey: "j7bridge.resolveCallerNames") as? Bool ?? true
        missedCallNotifications = UserDefaults.standard.object(forKey: "j7bridge.missedCallNotifications") as? Bool ?? true
        speakerDefault = UserDefaults.standard.object(forKey: "j7bridge.speakerDefault") as? Bool ?? true
        simSlot = UserDefaults.standard.object(forKey: "j7bridge.simSlot") as? Int ?? 0
        let initialJ7Host = UserDefaults.standard.string(forKey: "j7bridge.j7Host") ?? "192.168.104.12"
        j7Host = initialJ7Host

        ble = BLEManager()
        callKit = CallKitManager()
        wifiTransport = WiFiTransport(j7Host: initialJ7Host, port: 50005)
        wifiVoice = WiFiVoiceEngine(transport: wifiTransport, transmitMicrophone: false)
        contacts = ContactsManager()
        history = CallHistoryStore()

        ble.autoReconnect = autoConnect
        wifiVoice.setSpeakerDefault(speakerDefault)

        ble.onLog = { [weak self] line in self?.log(line) }
        ble.onStatus = { [weak self] status in
            guard let self else { return }
            self.bleStatus = status
            if status == "Connected" {
                self.log("[HYBRID] BLE control connected; Wi-Fi is reserved for audio")
            }
        }
        ble.onDevice = { [weak self] name in self?.deviceName = name ?? "IKOS K7" }
        ble.onControlPayload = { [weak self] payload in self?.handleControl(payload) }
        ble.onAudioPayload = { [weak self] _ in self?.handleLegacyBLEAudioIgnored() }

        wifiTransport.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.wifiStatus = status
                self?.log(status)
            }
        }
        wifiTransport.onJ7HostDiscovered = { [weak self] host in
            Task { @MainActor [weak self] in
                guard let self, self.j7Host != host else { return }
                self.j7Host = host
                self.log("[HYBRID] J7 Wi-Fi IP discovered: \(host)")
            }
        }
        // Wi-Fi's J7WC HELLO/PONG is only a transport discovery handshake.
        // Call state, answer/end, dial and SMS stay on BLE GATT.
        wifiTransport.onControl = { [weak self] control, payload in
            guard let self else { return }
            switch control {
            case .hello, .pong:
                self.log("[WIFI_DISCOVERY] \(control) bytes=\(payload.count)")
            default:
                self.log("[WIFI] Ignored Wi-Fi call-control packet; BLE is authoritative (\(control))")
            }
        }
        wifiTransport.onAudioPCM = { [weak self] pcm, rate, channels, frames in
            self?.wifiVoice.receivePCM(pcm, sampleRate: rate, channels: channels, frames: frames)
        }
        wifiVoice.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log(status)
                if status.contains("HYBRID OPEN OK") {
                    self.voiceStatus = "WIFI ACTIVE"
                } else if status.contains("HYBRID CLOSED") || status.contains("START ERROR") {
                    self.voiceStatus = "CLOSED"
                } else if status.contains("J7_NATIVE_MIC") {
                    self.voiceStatus = "J7 REMOTE MIC"
                }
            }
        }

        callKit.onLog = { [weak self] line in self?.log(line) }
        callKit.onStart = { [weak self] number in self?.beginOutgoing(number) }
        callKit.onAnswer = { [weak self] in
            guard let self else { return }
            self.wifiVoice.prepareForCallAudio()
            self.ble.sendAnswer()
            self.log("[CALLKIT] ANSWER -> BLE GATT / K7 05")
        }
        callKit.onEnd = { [weak self] in self?.endFromCallKit() }
        callKit.onMute = { [weak self] muted in
            self?.isMuted = muted
            // J7-native microphone is the GSM uplink in this hybrid mode.
            self?.wifiVoice.setMuted(muted)
        }
        callKit.onDTMF = { [weak self] digits in self?.sendDTMFString(digits) }
        callKit.onAudioActivated = { [weak self] in
            guard let self else { return }
            self.callAudioActive = true
            self.log("[CALLKIT] audio session ACT -> waiting for BLE VOICE_OPEN readiness if needed")
            self.maybeStartVoice()
        }
        callKit.onAudioDeactivated = { [weak self] in
            guard let self else { return }
            self.callAudioActive = false
            self.wifiVoice.stop()
            self.voiceStatus = "CLOSED"
        }
    }

    func start() {
        ble.startScan()
        // Start UDP discovery while the app is foregrounded. It is not used for
        // call signalling; active CallKit audio keeps the actual call audio path alive.
        wifiTransport.start()
        if contacts.authorization == .authorized { contacts.load() }
    }

    func answerTest() { ble.sendAnswer() }

    func makeCall() {
        let cleaned = dialString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        beginCall(number: cleaned, direction: .outgoing, name: contacts.resolveName(for: cleaned))
        callKit.startOutgoing(number: cleaned)
    }

    func endCall() { callKit.endCurrentCall() }

    func tapDialpad(_ digit: String) {
        if callStatus == "ACTIVE" { sendDTMFString(digit) }
        else { dialString.append(digit) }
    }

    func backspaceDialpad() {
        guard callStatus != "ACTIVE", !dialString.isEmpty else { return }
        dialString.removeLast()
    }

    func requestContacts() { contacts.requestAccessAndLoad() }
    func clearHistory() { history.clear() }

    func requestDeviceInfo() {
        ble.requestDeviceCheck()
        ble.requestBattery()
        ble.requestFirmware()
        ble.requestIMEI()
    }

    func sendDTMFString(_ digits: String) {
        for character in digits {
            switch character {
            case "0"..."9", "*", "#":
                ble.sendDTMF(UInt8(String(character).utf8.first!))
            default: break
            }
        }
    }

    func handleControl(_ payload: Data) {
        guard let op = payload.first else { return }
        switch op {
        case K7Protocol.evtReceiveCall:
            handleIncoming(payload)
        case K7Protocol.evtAnswer:
            callStatus = "ACTIVE"
            log("[CALL] BLE ANSWER EVENT / ACTIVE")
            callKit.fulfillAnswerIfNeeded()
            beginCallIfNeeded(direction: currentDirection ?? .incoming)
            remoteVoiceOpen = false
            // This is a BLE control command: Android hybrid patch starts the Wi-Fi
            // capture core and sends EVT_VOICE_OPEN only after launch succeeds.
            ble.sendVoiceOpen()
            voiceStatus = "WAITING FOR J7 WIFI CORE"
        case K7Protocol.evtReceiveCallEnd:
            handleRemoteEnd()
        case K7Protocol.evtVoiceOpen:
            remoteVoiceOpen = true
            log("[BLE] J7 WIFI CORE READY ACK")
            maybeStartVoice()
        case K7Protocol.evtVoiceClose:
            remoteVoiceOpen = false
            log("[BLE] J7 VOICE_CLOSE")
            wifiVoice.stop()
            voiceStatus = "CLOSED"
        case K7Protocol.evtMakeCall:
            callStatus = "DIALING"
            log("[CALL] BLE MAKE_CALL EVENT \(K7Protocol.hex(payload))")
            callKit.reportOutgoingConnecting()
        case K7Protocol.evtReadBattery:
            if payload.count >= 5 { battery = String(payload[4]) }
            log("[K7] BATTERY \(battery)")
        case K7Protocol.evtFirmwareVersion:
            firmware = K7Protocol.decodeASCIIBlock(payload, offset: 1)
            log("[K7] FIRMWARE \(firmware)")
        case K7Protocol.evtIMEIInfo:
            imei = K7Protocol.decodeASCIIBlock(payload, offset: 3)
            log("[K7] IMEI \(imei)")
        case K7Protocol.evtSMS:
            if let fragment = K7Protocol.decodeSMSFragment(payload) {
                handleSMSFragment(fragment)
            } else if let legacy = K7Protocol.decodeSMS(payload) {
                // Backward-compatible handling of the original unfragmented v1 event.
                notifications.sendSMS(sender: legacy.sender, body: legacy.body)
                log("[SMS] v1 notification received over BLE from \(legacy.sender)")
            } else {
                log("[SMS] malformed hybrid SMS event bytes=\(payload.count)")
            }
        default:
            log("[RX] BLE CONTROL \(String(format: "%02X", op)) \(K7Protocol.hex(payload))")
        }
    }

    private func handleSMSFragment(_ fragment: K7SMSFragment) {
        let now = Date()
        pendingSMS = pendingSMS.filter { now.timeIntervalSince($0.value.lastUpdated) < 30 }

        var assembly = pendingSMS[fragment.messageID] ?? PendingSMSAssembly(
            expectedCount: fragment.count,
            sender: fragment.sender ?? "",
            chunks: [:],
            lastUpdated: now
        )
        guard assembly.expectedCount == fragment.count else {
            pendingSMS.removeValue(forKey: fragment.messageID)
            log("[SMS] fragment count mismatch id=\(fragment.messageID)")
            return
        }
        if let sender = fragment.sender { assembly.sender = sender }
        assembly.chunks[fragment.index] = fragment.bodyBytes
        assembly.lastUpdated = now
        pendingSMS[fragment.messageID] = assembly

        guard assembly.chunks.count == assembly.expectedCount,
              !assembly.sender.isEmpty else { return }
        var bodyData = Data()
        for index in 0..<assembly.expectedCount {
            guard let chunk = assembly.chunks[index] else { return }
            bodyData.append(chunk)
        }
        guard let body = String(data: bodyData, encoding: .utf8) else {
            pendingSMS.removeValue(forKey: fragment.messageID)
            log("[SMS] invalid UTF-8 after reassembly id=\(fragment.messageID)")
            return
        }
        let sender = assembly.sender
        pendingSMS.removeValue(forKey: fragment.messageID)
        notifications.sendSMS(sender: sender, body: body)
        log("[SMS] v2 notification reassembled id=\(fragment.messageID) parts=\(fragment.count) from \(sender)")
    }

    private func handleLegacyBLEAudioIgnored() {
        ignoredBLEAudioFrames += 1
        if ignoredBLEAudioFrames == 1 || ignoredBLEAudioFrames % 100 == 0 {
            log("[HYBRID] BLE AMR audio ignored count=\(ignoredBLEAudioFrames); Wi-Fi carries audio")
        }
    }

    private func handleIncoming(_ payload: Data) {
        guard callStatus == "IDLE" || callStatus == "ENDED" else {
            log("[CALL] duplicate incoming ignored")
            return
        }
        let incomingNumber = K7Protocol.decodeIncomingNumber(payload)
        guard !incomingNumber.isEmpty else {
            log("[CALL] incoming event had no decoded number")
            return
        }
        let name = resolveCallerNames ? contacts.resolveName(for: incomingNumber) : nil
        number = incomingNumber
        callerName = name ?? ""
        currentContactName = name
        currentDirection = .incoming
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        callStatus = "RINGING"
        log("[CALL] INCOMING \(name.map { "\($0) / " } ?? "")\(incomingNumber)")
        callKit.reportIncoming(number: incomingNumber, callerName: name)
    }

    private func beginOutgoing(_ outgoingNumber: String) {
        number = outgoingNumber
        callerName = contacts.resolveName(for: outgoingNumber) ?? ""
        currentContactName = callerName.isEmpty ? nil : callerName
        dialString = ""
        beginCall(number: outgoingNumber, direction: .outgoing, name: currentContactName)
        ble.sendMakeCall(number: outgoingNumber, simId: UInt8(simSlot))
        callStatus = "DIALING"
        log("[CALL] OUTGOING MAKE_CALL -> BLE GATT")
    }

    private func beginCall(number: String, direction: CallDirection, name: String?) {
        self.number = number
        currentDirection = direction
        currentContactName = name
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        if direction == .outgoing { callStatus = "DIALING" }
    }

    private func beginCallIfNeeded(direction: CallDirection) {
        if callStartedAt == nil { callStartedAt = Date() }
        currentDirection = direction
        if direction == .incoming && callerName.isEmpty { callerName = currentContactName ?? "" }
    }

    private func maybeStartVoice() {
        guard callStatus == "ACTIVE", callAudioActive, remoteVoiceOpen else { return }
        wifiTransport.start()
        guard wifiVoice.start() else {
            voiceStatus = "START FAILED"
            log("[HYBRID] Wi-Fi audio engine failed; BLE call control remains connected")
            return
        }
        voiceStatus = "WIFI ACTIVE / J7 MIC"
        log("[HYBRID] AUDIO START gate satisfied: GSM ACTIVE + CallKit audio active + BLE core-ready ACK")
    }

    private func endFromCallKit() {
        ble.sendVoiceClose()
        ble.sendHangup()
        remoteVoiceOpen = false
        wifiVoice.stop()
        finishHistory(direction: currentDirection ?? .outgoing)
        callStatus = "ENDED"
        voiceStatus = "CLOSED"
        callKit.clearCurrentCall()
    }

    private func handleRemoteEnd() {
        let wasRinging = callStatus == "RINGING"
        let direction = currentDirection ?? .incoming
        ble.sendVoiceClose()
        remoteVoiceOpen = false
        wifiVoice.stop()
        finishHistory(direction: wasRinging ? .missed : direction)
        callStatus = "ENDED"
        voiceStatus = "CLOSED"
        log("[CALL] BLE END EVENT")
        callKit.reportRemoteEnd()
    }

    private func finishHistory(direction: CallDirection) {
        let duration = callStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        if !number.isEmpty {
            history.add(number: number, name: currentContactName, direction: direction, duration: duration)
            if direction == .missed, missedCallNotifications {
                notifications.sendMissedCall(number: number, name: currentContactName)
            }
        }
        callStartedAt = nil
        currentDirection = nil
        currentContactName = nil
        callAudioActive = false
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(stamp)] \(line)")
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
}
