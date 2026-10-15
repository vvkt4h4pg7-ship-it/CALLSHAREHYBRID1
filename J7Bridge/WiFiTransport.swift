import Foundation
import Network
import Darwin

final class WiFiTransport {
    enum Control: UInt8 {
        case hello = 0x01
        case incomingCall = 0x10
        case callAnswer = 0x11
        case callActive = 0x12
        case callEnd = 0x13
        case voiceOpen = 0x14
        case voiceClose = 0x15
        case makeCall = 0x20
        case hangup = 0x21
        case dtmf = 0x22
        case pong = 0x31
    }

    // Wi-Fi UDP audio uses the J7WV protocol: 48 kHz, stereo S16_LE.
    // 960-frame PCM blocks are split into three MTU-safe 320-frame datagrams.
    private static let controlMagic: [UInt8] = [0x4A, 0x37, 0x57, 0x43] // J7WC
    private static let audioMagic: [UInt8] = [0x4A, 0x37, 0x57, 0x56]   // J7WV
    private static let version: UInt8 = 1
    private static let controlHeaderSize = 12
    private static let audioHeaderSize = 20

    // R2 MTU-safe wire test: 3 fragments assemble into one 20 ms PCM frame.
    private static let fragmentFlag: UInt16 = 0x0002
    private static let fragmentIndexShift: UInt16 = 8
    // Accept the alternate R2 flag layout present in earlier project snapshots.
    // Both layouts are treated as three 320-frame pieces sharing one sequence.
    private static let alternateFragmentFlag: UInt16 = 0x0008
    private static let alternateFragmentIndexShift: UInt16 = 4
    private static let alternateFragmentIndexMask: UInt16 = 0x0030
    private static let fragmentCount = 3
    private static let fragmentPCMBytes = 1280
    private static let fragmentFrames: UInt16 = 320
    private static let fullPCMBytes = 3840
    private var rxFragmentParts: [UInt32: [Int: Data]] = [:]
    private var rxFragmentOrder: [UInt32] = []
    private var txAudioFrames: UInt64 = 0

    private var _j7Host: String
    let port: UInt16

    var j7Host: String { _j7Host }

    var onControl: ((Control, Data) -> Void)?
    var onAudioPCM: ((Data, UInt32, UInt16, UInt16) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Fires only after a valid J7 audio packet or our discovery beacon proves the peer IP.
    var onJ7HostDiscovered: ((String) -> Void)?

    private let rxQueue = DispatchQueue(label: "com.callshare.wifi.rx", qos: .userInitiated)
    private let txQueue = DispatchQueue(label: "com.callshare.wifi.tx", qos: .userInitiated)

    private var listener: NWListener?
    private var uplink: NWConnection?
    // Control commands go to Android ControlUdpService on UDP 50006.
    // Keep the proven BSD-socket RX and audio uplink path unchanged.
    private var controlUplink: NWConnection?
    private let controlTxPort: UInt16 = 50006
    // R2: use a real UDP datagram socket for RX. This avoids NWConnection peer churn
    // when the Android sender uses an ephemeral UDP source port.
    private var rxSocket: Int32 = -1
    private var rxDatagrams: UInt64 = 0
    private var rxAudioDatagrams: UInt64 = 0
    private var sequence: UInt32 = 0
    private var pendingTX: [Data] = []
    private var pendingControlTX: [Data] = []
    private let maxPendingTX = 15 // 5 full R2 frames x 3 datagrams/frame

    // R1 background resilience: recover terminal UDP uplink failures instead of
    // leaving the audio/control path nil until the user edits the J7 address.
    private var uplinkReconnectWorkItem: DispatchWorkItem?
    private var controlReconnectWorkItem: DispatchWorkItem?
    private var uplinkRetryAttempt = 0
    private var controlRetryAttempt = 0
    private var started = false
    private var coreDiscoveryTimer: DispatchSourceTimer?
    private var coreDiscoveryProbeCount: UInt64 = 0

    init(j7Host: String = "192.168.104.12", port: UInt16 = 50005) {
        self._j7Host = j7Host
        self.port = port
    }

    deinit {
        stop()
    }

    func start() {
        txQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.startListener()
            // Start iPhone -> J7 UDP audio as well as the J7 -> iPhone receiver.
            // BLE remains authoritative for call signaling.
            self.startUplink()
            self.startCoreDiscoveryTimer()
        }
    }

    func stop() {
        txQueue.async { [weak self] in
            guard let self else { return }
            self.started = false
            if let timer = self.coreDiscoveryTimer {
                timer.setEventHandler {}
                timer.cancel()
                self.coreDiscoveryTimer = nil
            }
            self.uplinkReconnectWorkItem?.cancel()
            self.uplinkReconnectWorkItem = nil
            self.controlReconnectWorkItem?.cancel()
            self.controlReconnectWorkItem = nil
            self.uplinkRetryAttempt = 0
            self.controlRetryAttempt = 0
            self.onStatus?("[WIFI] TRANSPORT STOP requested")
            self.listener?.cancel()
            self.listener = nil
            self.uplink?.cancel()
            self.uplink = nil
            self.controlUplink?.cancel()
            self.controlUplink = nil
            if self.rxSocket >= 0 {
                shutdown(self.rxSocket, SHUT_RDWR)
                close(self.rxSocket)
                self.rxSocket = -1
            }
            self.rxDatagrams = 0
            self.rxAudioDatagrams = 0
            self.rxFragmentParts.removeAll(keepingCapacity: false)
            self.rxFragmentOrder.removeAll(keepingCapacity: false)
            self.txAudioFrames = 0
            self.pendingTX.removeAll(keepingCapacity: false)
            self.pendingControlTX.removeAll(keepingCapacity: false)
        }
    }

    func setJ7Host(_ host: String) {
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        txQueue.async { [weak self] in
            guard let self else { return }
            if self._j7Host == cleaned {
                // Host can be set before start(); if already correct, ensure the
                // audio uplink exists after start.
                if self.started && self.uplink == nil {
                    self.startUplink()
                }
                return
            }
            self._j7Host = cleaned
            self.onStatus?("[WIFI] RECONNECT reason=J7_HOST_CHANGED host=\(cleaned)")
            self.uplinkReconnectWorkItem?.cancel()
            self.uplinkReconnectWorkItem = nil
            self.controlReconnectWorkItem?.cancel()
            self.controlReconnectWorkItem = nil
            self.uplinkRetryAttempt = 0
            self.controlRetryAttempt = 0
            self.uplink?.cancel()
            self.uplink = nil
            self.controlUplink?.cancel()
            self.controlUplink = nil
            // BLE owns call control; UDP uplink carries iPhone microphone PCM.
            if self.started {
                self.startUplink()
                self.sendCoreDiscoveryHello()
            }
            self.onStatus?("[WIFI] J7 HOST = \(cleaned)")
        }
    }

    func sendHello() {
        sendControl(.hello, payload: Data())
    }

    func sendAnswer() {
        sendControl(.callAnswer, payload: Data())
    }

    func sendHangup() {
        sendControl(.hangup, payload: Data())
    }

    func sendVoiceOpen() {
        sendControl(.voiceOpen, payload: Data())
    }

    func sendVoiceClose() {
        sendControl(.voiceClose, payload: Data())
    }

    func sendMakeCall(number: String) {
        sendControl(.makeCall, payload: Data(number.utf8))
    }

    func sendDTMF(_ value: UInt8) {
        sendControl(.dtmf, payload: Data([value]))
    }

    func sendAudioPCM(_ pcm: Data, sampleRate: UInt32 = 48_000, channels: UInt16 = 2, frames: UInt16 = 960) {
        guard pcm.count == Int(frames) * Int(channels) * 2 else {
            onStatus?("[WIFI_R2] TX PCM size invalid: \(pcm.count)")
            return
        }
        // R2 is intentionally paired to the known 48k/stereo/960-frame wire frame.
        guard sampleRate == 48_000, channels == 2, frames == 960, pcm.count == Self.fullPCMBytes else {
            onStatus?("[WIFI_R2] TX unsupported format rate=\(sampleRate) ch=\(channels) frames=\(frames) bytes=\(pcm.count)")
            return
        }

        txQueue.async { [weak self] in
            guard let self else { return }
            let frameSequence = self.nextSequence() // one sequence for all 3 fragments of this frame
            for fragmentIndex in 0..<Self.fragmentCount {
                let start = fragmentIndex * Self.fragmentPCMBytes
                let chunk = pcm.subdata(in: start..<(start + Self.fragmentPCMBytes))
                let flags = UInt16(0x0001 | Int(Self.fragmentFlag) | (fragmentIndex << Int(Self.fragmentIndexShift)))
                let packet = self.makeAudioPacket(
                    pcm: chunk,
                    sampleRate: sampleRate,
                    channels: channels,
                    frames: Self.fragmentFrames,
                    sequence: frameSequence,
                    flags: flags
                )
                self.enqueueOrSend(packet)
            }
            self.txAudioFrames &+= 1
            if self.txAudioFrames == 1 || self.txAudioFrames % 50 == 0 {
                self.onStatus?("[WIFI_R2] TX PCM FRAME #\(self.txAudioFrames) seq=\(frameSequence) fragments=3 datagram=1300B totalPCM=3840B")
            }
        }
    }

    /// Periodically sends J7WC HELLO from the same socket bound to UDP 50005.
    /// This makes the packet source port 50005, so the native J7 core can learn
    /// the current iPhone hotspot IP and reply to the listener without relying
    /// on a stale --peer address. Regular call controls remain BLE-only.
    private func startCoreDiscoveryTimer() {
        guard coreDiscoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: txQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .seconds(2), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.sendCoreDiscoveryHello() }
        coreDiscoveryTimer = timer
        timer.resume()
    }

    private func sendCoreDiscoveryHello() {
        guard started, rxSocket >= 0 else { return }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        let parseResult = _j7Host.withCString { inet_pton(AF_INET, $0, &destination.sin_addr) }
        guard parseResult == 1 else {
            onStatus?("[WIFI HYBRID] HELLO skipped; J7 host is not IPv4: \(_j7Host)")
            return
        }
        let packet = makeControlPacket(type: .hello, payload: Data())
        let sent = packet.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return withUnsafePointer(to: &destination) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(rxSocket, base, packet.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        coreDiscoveryProbeCount &+= 1
        if sent != packet.count {
            onStatus?("[WIFI HYBRID] CORE HELLO send failed errno=\(errno)")
        } else if coreDiscoveryProbeCount == 1 || coreDiscoveryProbeCount % 15 == 0 {
            onStatus?("[WIFI HYBRID] CORE HELLO #\(coreDiscoveryProbeCount) -> \(_j7Host):\(port)")
        }
    }

    private func startListener() {
        // R2 intentionally uses a BSD UDP socket for RX instead of NWListener/NWConnection.
        // NWConnection can create/tear down peer objects as the Android sender changes
        // its ephemeral source port. A bound datagram socket receives every UDP packet
        // addressed to port 50005 without that peer lifecycle.
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            onStatus?("[WIFI] UDP RX SOCKET ERROR errno=\(errno)")
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            onStatus?("[WIFI] UDP RX BIND ERROR port=\(port) errno=\(errno)")
            close(fd)
            return
        }

        rxSocket = fd
        onStatus?("[WIFI] UDP RX SOCKET BOUND 0.0.0.0:\(port)")
        rxQueue.async { [weak self] in
            self?.receiveDatagrams(fd: fd)
        }
    }

    private func receiveDatagrams(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65535)

        while true {
            if rxSocket != fd { return }

            var source = sockaddr_in()
            var sourceLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { sourcePtr -> Int in
                sourcePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sourceSockaddr in
                    recvfrom(fd, &buffer, buffer.count, 0, sourceSockaddr, &sourceLen)
                }
            }

            if count < 0 {
                if errno == EINTR { continue }
                if rxSocket == fd {
                    onStatus?("[WIFI] UDP RX ERROR errno=\(errno)")
                }
                return
            }

            if count == 0 { continue }

            rxDatagrams += 1
            let data = Data(buffer[0..<count])
            let isAudio = count >= 4 && buffer[0] == 0x4A && buffer[1] == 0x37 && buffer[2] == 0x57 && buffer[3] == 0x56
            if let reason = discoveryReason(for: data) {
                let sourceHost = ipv4String(from: source.sin_addr)
                considerDiscoveredJ7Host(sourceHost, reason: reason)
            }
            if isAudio {
                rxAudioDatagrams += 1
                if rxAudioDatagrams == 1 || rxAudioDatagrams % 50 == 0 {
                    onStatus?("[WIFI_AUDIO] RX DATAGRAM #\(rxAudioDatagrams) len=\(count) total=\(rxDatagrams)")
                }
            } else if rxDatagrams <= 5 {
                onStatus?("[WIFI] RX DATAGRAM #\(rxDatagrams) len=\(count)")
            }

            handleDatagram(data)
        }
    }

    private func discoveryReason(for data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        // Accept only a well-formed J7WV packet from the established native audio protocol.
        if Array(bytes[0..<4]) == Self.audioMagic {
            guard bytes.count >= Self.audioHeaderSize else { return nil }
            let sampleRate = readLE32(bytes, 8)
            let channels = readLE16(bytes, 12)
            let format = readLE16(bytes, 14)
            let frames = readLE16(bytes, 16)
            let flags = readLE16(bytes, 18)
            let expected = Self.audioHeaderSize + Int(frames) * Int(channels) * 2
            guard sampleRate == 48_000, channels == 2, format == 1,
                  (flags & 0x0001) != 0, bytes.count == expected else { return nil }
            if let fragmentIndex = fragmentIndex(from: flags) {
                guard frames == Self.fragmentFrames, expected == 1300,
                      fragmentIndex < Self.fragmentCount else { return nil }
                return "valid fragmented J7WV audio"
            }
            guard frames == 960, expected == 3860 else { return nil }
            return "valid legacy J7WV audio"
        }

        // Cold-start discovery beacon emitted by the J7 helper app.
        if Array(bytes[0..<4]) == Self.controlMagic,
           bytes.count >= Self.controlHeaderSize,
           bytes[4] == Self.version,
           bytes[5] == Control.pong.rawValue {
            let payloadLength = Int(readLE16(bytes, 10))
            guard payloadLength == bytes.count - Self.controlHeaderSize else { return nil }
            let payload = Data(bytes[Self.controlHeaderSize..<bytes.count])
            guard String(data: payload, encoding: .utf8) == "CALLSHARE_DISCOVERY_R1" else { return nil }
            return "J7WC discovery beacon"
        }
        return nil
    }

    /// Decode the fragment index from either known R2 header layout.
    /// The caller separately validates the audio flag and payload size.
    private func fragmentIndex(from flags: UInt16) -> Int? {
        if (flags & Self.fragmentFlag) != 0 {
            return Int((flags >> Self.fragmentIndexShift) & 0x3)
        }
        if (flags & Self.alternateFragmentFlag) != 0 {
            return Int((flags & Self.alternateFragmentIndexMask) >> Self.alternateFragmentIndexShift)
        }
        return nil
    }

    private func ipv4String(from address: in_addr) -> String {
        let value = UInt32(bigEndian: address.s_addr)
        return "\(UInt8((value >> 24) & 0xff)).\(UInt8((value >> 16) & 0xff)).\(UInt8((value >> 8) & 0xff)).\(UInt8(value & 0xff))"
    }

    private func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = octets[0], b = octets[1]
        return a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) || (a == 169 && b == 254)
    }

    private func considerDiscoveredJ7Host(_ host: String, reason: String) {
        guard isPrivateIPv4(host) else { return }
        txQueue.async { [weak self] in
            guard let self, self.started, self._j7Host != host else { return }
            let oldHost = self._j7Host
            self._j7Host = host
            self.onStatus?("[WIFI] RECONNECT reason=AUTO_DISCOVERY old=\(oldHost) new=\(host)")
            self.uplinkReconnectWorkItem?.cancel()
            self.uplinkReconnectWorkItem = nil
            self.controlReconnectWorkItem?.cancel()
            self.controlReconnectWorkItem = nil
            self.uplinkRetryAttempt = 0
            self.controlRetryAttempt = 0
            self.uplink?.cancel()
            self.uplink = nil
            self.controlUplink?.cancel()
            self.controlUplink = nil
            // Discovery changed the host and cleared the old connection; recreate the uplink.
            self.startUplink()
            self.sendCoreDiscoveryHello()
            self.onStatus?("[WIFI AUTO] J7 IP DISCOVERED \(oldHost) -> \(host) via \(reason)")
            self.onJ7HostDiscovered?(host)
        }
    }

    private func startUplink() {
        guard started else { return }
        guard uplink == nil else { return }

        let targetHost = _j7Host
        let connection = NWConnection(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        uplink = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onStatus?("[WIFI] J7 UPLINK host=\(targetHost) state=\(String(describing: state))")
            switch state {
            case .ready:
                self.uplinkReconnectWorkItem?.cancel()
                self.uplinkReconnectWorkItem = nil
                self.uplinkRetryAttempt = 0
                self.flushPendingTX()
                self.sendHello()
            case .failed(let error):
                self.onStatus?("[WIFI] J7 UPLINK FAILED host=\(targetHost) error=\(error.localizedDescription)")
                // Only clear/recover the connection if this is still the current uplink.
                if self.uplink === connection {
                    self.uplink = nil
                    connection.cancel()
                    self.scheduleUplinkReconnect(reason: "failed")
                } else {
                    connection.cancel()
                }
            case .cancelled:
                self.onStatus?("[WIFI] J7 UPLINK CANCELLED host=\(targetHost) current=\(self.uplink === connection)")
                // Intentional host-change/stop cancels clear `uplink` first, so only
                // an unexpected cancellation of the active connection is restarted.
                if self.uplink === connection {
                    self.uplink = nil
                    self.scheduleUplinkReconnect(reason: "unexpected-cancel")
                }
            case .waiting(let error):
                self.onStatus?("[WIFI] J7 UPLINK WAITING host=\(targetHost) error=\(error.localizedDescription)")
            default:
                break
            }
        }

        connection.start(queue: txQueue)
    }

    private func scheduleUplinkReconnect(reason: String) {
        guard started, uplinkReconnectWorkItem == nil else { return }
        uplinkRetryAttempt = min(uplinkRetryAttempt + 1, 6)
        let delay = min(5.0, 0.5 * pow(2.0, Double(uplinkRetryAttempt - 1)))
        let attempt = uplinkRetryAttempt
        onStatus?("[WIFI] J7 UPLINK RECONNECT SCHEDULED reason=\(reason) attempt=\(attempt) delay=\(String(format: "%.1f", delay))s")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.uplinkReconnectWorkItem = nil
            guard self.started, self.uplink == nil else { return }
            self.onStatus?("[WIFI] J7 UPLINK RECONNECT NOW attempt=\(attempt)")
            self.startUplink()
        }
        uplinkReconnectWorkItem = work
        txQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startControlUplink() {
        guard started else { return }
        guard controlUplink == nil else { return }

        let targetHost = _j7Host
        let connection = NWConnection(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: controlTxPort)!,
            using: .udp
        )
        controlUplink = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onStatus?("[WIFI] CONTROL UPLINK host=\(targetHost) state=\(String(describing: state)) port=\(self.controlTxPort)")
            switch state {
            case .ready:
                self.controlReconnectWorkItem?.cancel()
                self.controlReconnectWorkItem = nil
                self.controlRetryAttempt = 0
                self.flushPendingControlTX()
            case .failed(let error):
                self.onStatus?("[WIFI] CONTROL UPLINK FAILED host=\(targetHost) error=\(error.localizedDescription)")
                if self.controlUplink === connection {
                    self.controlUplink = nil
                    connection.cancel()
                    self.scheduleControlReconnect(reason: "failed")
                } else {
                    connection.cancel()
                }
            case .cancelled:
                self.onStatus?("[WIFI] CONTROL UPLINK CANCELLED host=\(targetHost) current=\(self.controlUplink === connection)")
                if self.controlUplink === connection {
                    self.controlUplink = nil
                    self.scheduleControlReconnect(reason: "unexpected-cancel")
                }
            case .waiting(let error):
                self.onStatus?("[WIFI] CONTROL UPLINK WAITING host=\(targetHost) error=\(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: txQueue)
    }

    private func scheduleControlReconnect(reason: String) {
        guard started, controlReconnectWorkItem == nil else { return }
        controlRetryAttempt = min(controlRetryAttempt + 1, 6)
        let delay = min(5.0, 0.5 * pow(2.0, Double(controlRetryAttempt - 1)))
        let attempt = controlRetryAttempt
        onStatus?("[WIFI] CONTROL RECONNECT SCHEDULED reason=\(reason) attempt=\(attempt) delay=\(String(format: "%.1f", delay))s")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.controlReconnectWorkItem = nil
            guard self.started, self.controlUplink == nil else { return }
            self.onStatus?("[WIFI] CONTROL RECONNECT NOW attempt=\(attempt)")
            self.startControlUplink()
        }
        controlReconnectWorkItem = work
        txQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                self.onStatus?("[WIFI] RX ERROR: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if let data, !data.isEmpty {
                self.handleDatagram(data)
            }

            self.receiveLoop(connection)
        }
    }

    private func handleDatagram(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }

        if Array(bytes.prefix(4)) == Self.audioMagic {
            parseAudioDatagram(data)
            return
        }

        if Array(bytes.prefix(4)) == Self.controlMagic {
            parseControlDatagram(data)
            return
        }

        onStatus?("[WIFI] RX UNKNOWN DATAGRAM len=\(data.count)")
    }

    private func parseControlDatagram(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.controlHeaderSize else {
            onStatus?("[WIFI] CONTROL DROP short=\(data.count)")
            return
        }
        guard Array(bytes[0..<4]) == Self.controlMagic, bytes[4] == Self.version else { return }

        let typeRaw = bytes[5]
        guard let type = Control(rawValue: typeRaw) else {
            onStatus?("[WIFI] CONTROL DROP type=0x\(String(format: "%02X", typeRaw))")
            return
        }

        let payloadLength = Int(UInt16(bytes[10]) | (UInt16(bytes[11]) << 8))
        guard payloadLength == bytes.count - Self.controlHeaderSize else {
            onStatus?("[WIFI] CONTROL DROP length")
            return
        }

        let payload = Data(bytes[Self.controlHeaderSize..<bytes.count])
        onControl?(type, payload)
    }

    private func parseAudioDatagram(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.audioHeaderSize else {
            onStatus?("[WIFI] AUDIO DROP short=\(data.count)")
            return
        }
        guard Array(bytes[0..<4]) == Self.audioMagic else { return }

        let sequence = readLE32(bytes, 4)
        let sampleRate = readLE32(bytes, 8)
        let channels = readLE16(bytes, 12)
        let format = readLE16(bytes, 14)
        let frames = readLE16(bytes, 16)
        let flags = readLE16(bytes, 18)

        guard sampleRate == 48_000, channels == 2, format == 1, (flags & 0x0001) != 0 else {
            onStatus?("[WIFI_R2] AUDIO DROP header rate=\(sampleRate) ch=\(channels) fmt=\(format) flags=\(flags)")
            return
        }

        let payload = Data(bytes[Self.audioHeaderSize..<bytes.count])
        let expected = Int(frames) * Int(channels) * 2
        guard payload.count == expected else {
            onStatus?("[WIFI_R2] AUDIO DROP size=\(payload.count) expected=\(expected)")
            return
        }

        if let fragmentIndex = fragmentIndex(from: flags) {
            guard frames == Self.fragmentFrames, fragmentIndex < Self.fragmentCount,
                  payload.count == Self.fragmentPCMBytes, data.count == 1300 else {
                onStatus?("[WIFI_R2] FRAGMENT DROP seq=\(sequence) idx=\(fragmentIndex) len=\(data.count) pcm=\(payload.count) flags=0x\(String(flags, radix: 16))")
                return
            }

            if rxFragmentParts[sequence] == nil {
                rxFragmentParts[sequence] = [:]
                rxFragmentOrder.append(sequence)
            }
            rxFragmentParts[sequence]?[fragmentIndex] = payload

            // Keep only a small bounded reassembly window (~160 ms). Old incomplete
            // frames are discarded rather than increasing audio latency indefinitely.
            while rxFragmentOrder.count > 8 {
                let stale = rxFragmentOrder.removeFirst()
                rxFragmentParts.removeValue(forKey: stale)
            }

            guard let parts = rxFragmentParts[sequence], parts.count == Self.fragmentCount else { return }
            var assembled = Data()
            assembled.reserveCapacity(Self.fullPCMBytes)
            for index in 0..<Self.fragmentCount {
                guard let part = parts[index], part.count == Self.fragmentPCMBytes else { return }
                assembled.append(part)
            }
            rxFragmentParts.removeValue(forKey: sequence)
            rxFragmentOrder.removeAll { $0 == sequence }
            guard assembled.count == Self.fullPCMBytes else { return }

            if rxAudioDatagrams <= 9 || rxAudioDatagrams % 150 == 0 {
                onStatus?("[WIFI_R2] RX REASSEMBLED seq=\(sequence) fragments=3 datagrams=1300B pcm=\(assembled.count)B")
            }
            // WiFiVoiceEngine expects 960 stereo frames = 3840 PCM bytes.
            onAudioPCM?(assembled, sampleRate, channels, 960)
            return
        }

        // Backward-compatible receive for legacy, single-datagram 20 ms J7WV audio.
        guard frames == 960, payload.count == Self.fullPCMBytes else {
            onStatus?("[WIFI_R2] AUDIO DROP unexpected legacy frame=\(frames) pcm=\(payload.count)")
            return
        }
        if rxAudioDatagrams <= 3 {
            onStatus?("[WIFI_AUDIO] RX VALID legacy J7WV rate=\(sampleRate) ch=\(channels) frames=\(frames) pcm=\(payload.count)B")
        }
        onAudioPCM?(payload, sampleRate, channels, frames)
    }

    private func sendControl(_ control: Control, payload: Data) {
        txQueue.async { [weak self] in
            guard let self else { return }
            let packet = self.makeControlPacket(type: control, payload: payload)
            self.enqueueControlOrSend(packet)
        }
    }

    private func enqueueOrSend(_ packet: Data) {
        guard let uplink else {
            if pendingTX.count >= maxPendingTX { pendingTX.removeFirst() }
            pendingTX.append(packet)
            return
        }

        uplink.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onStatus?("[WIFI] TX ERROR: \(error.localizedDescription)")
            }
        })
    }

    private func flushPendingTX() {
        guard !pendingTX.isEmpty else { return }
        let items = pendingTX
        pendingTX.removeAll(keepingCapacity: true)
        for item in items { enqueueOrSend(item) }
    }

    private func enqueueControlOrSend(_ packet: Data) {
        guard let controlUplink else {
            if pendingControlTX.count >= maxPendingTX { pendingControlTX.removeFirst() }
            pendingControlTX.append(packet)
            onStatus?("[WIFI] CONTROL TX QUEUED port=\(controlTxPort)")
            return
        }

        controlUplink.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onStatus?("[WIFI] CONTROL TX ERROR: \(error.localizedDescription)")
            } else {
                self?.onStatus?("[WIFI] CONTROL TX SENT len=\(packet.count) port=\(self?.controlTxPort ?? 50006)")
            }
        })
    }

    private func flushPendingControlTX() {
        guard !pendingControlTX.isEmpty else { return }
        let items = pendingControlTX
        pendingControlTX.removeAll(keepingCapacity: true)
        for item in items { enqueueControlOrSend(item) }
    }

    private func makeControlPacket(type: Control, payload: Data) -> Data {
        let seq = nextSequence()
        var out = Data(Self.controlMagic)
        out.append(Self.version)
        out.append(type.rawValue)
        appendLE32(&out, seq)
        appendLE16(&out, UInt16(min(payload.count, Int(UInt16.max))))
        out.append(payload.prefix(Int(UInt16.max)))
        return out
    }

    private func makeAudioPacket(pcm: Data, sampleRate: UInt32, channels: UInt16, frames: UInt16,
                                 sequence: UInt32, flags: UInt16) -> Data {
        var out = Data(Self.audioMagic)
        appendLE32(&out, sequence)
        appendLE32(&out, sampleRate)
        appendLE16(&out, channels)
        appendLE16(&out, 1) // S16_LE
        appendLE16(&out, frames)
        appendLE16(&out, flags)
        out.append(pcm)
        return out
    }

    private func nextSequence() -> UInt32 {
        let value = sequence
        sequence &+= 1
        return value
    }

    private func readLE16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private func readLE32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) |
        (UInt32(b[i + 1]) << 8) |
        (UInt32(b[i + 2]) << 16) |
        (UInt32(b[i + 3]) << 24)
    }

    private func appendLE16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
