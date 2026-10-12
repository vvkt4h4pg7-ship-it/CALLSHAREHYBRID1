import Foundation
import CoreBluetooth

struct K7SMSFragment {
    let messageID: UInt16
    let index: Int
    let count: Int
    let sender: String?
    let bodyBytes: Data
}

enum K7Protocol {
    static let service = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB7")
    static let rx = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB8")
    static let flow = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB9")
    static let tx = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CBA")

    // Commands/events recovered from the supplied IKOS K7 source.
    static let cmdDevCheck: UInt8 = 0x01
    static let cmdMakeCall: UInt8 = 0x02
    static let cmdDTMF: UInt8 = 0x03
    static let cmdHangup: UInt8 = 0x04
    static let cmdAnswer: UInt8 = 0x05
    static let cmdReadBattery: UInt8 = 0x09
    static let cmdFirmwareVersion: UInt8 = 0x12
    static let cmdCodecSel: UInt8 = 0x13
    static let cmdHoldCall: UInt8 = 0x0E
    static let cmdRetrieveCall: UInt8 = 0x0F
    static let cmdSetSpeechVolume: UInt8 = 0x1A
    static let cmdVibratorEnable: UInt8 = 0x30
    static let cmdVibratorCheck: UInt8 = 0x31
    static let cmdIMEIInfo: UInt8 = 0x71
    static let cmdGetCurrentCall: UInt8 = 0xA8

    static let evtDevCheck: UInt8 = 0x01
    static let evtDTMF: UInt8 = 0x02
    static let evtMakeCall: UInt8 = 0x03
    static let evtHangup: UInt8 = 0x04
    static let evtAnswer: UInt8 = 0x05
    static let evtReadBattery: UInt8 = 0x09
    static let evtReceiveCall: UInt8 = 0x0A
    static let evtReceiveCallEnd: UInt8 = 0x0B
    static let evtHoldCall: UInt8 = 0x13
    static let evtRetrieveCall: UInt8 = 0x14
    static let evtFirmwareVersion: UInt8 = 0x16
    static let evtIMEIInfo: UInt8 = 0x71
    static let evtVoiceOpen: UInt8 = 0x0F
    static let evtVoiceClose: UInt8 = 0x10
    // CALLSHARE Hybrid extension (Android-side companion patch required):
    // [F1, 01, senderLen:u8, bodyLen:u8, sender UTF-8, body UTF-8].
    static let evtSMS: UInt8 = 0xF1

    static func makeCallPayload(number: String, simId: UInt8) -> Data {
        var data = Data([cmdMakeCall, simId])
        data.append(contentsOf: number.data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    static func dtmfPayload(_ value: UInt8) -> Data {
        Data([cmdDTMF, value])
    }

    static func wrapControl(_ payload: Data) -> Data {
        let lengthField = payload.isEmpty ? 0 : UInt8((payload.count - 1) & 0xFF)
        let checksum = UInt8((~(0x12 + Int(lengthField))) & 0xFF)
        var out = Data([0xC0])
        appendEscaped(&out, 0x12)
        appendEscaped(&out, lengthField)
        appendEscaped(&out, checksum)
        for byte in payload { appendEscaped(&out, byte) }
        out.append(0xC0)
        return out
    }

    static func wrapAudio(_ payload: Data) -> Data {
        let length = payload.count
        let h0 = UInt8(((length & 0x0F) << 4) | 0x03)
        let h1 = UInt8((length >> 4) & 0xFF)
        let checksum = UInt8((-Int(h0) - Int(h1)) & 0xFF)
        var out = Data([0xC0])
        appendEscaped(&out, h0)
        appendEscaped(&out, h1)
        appendEscaped(&out, checksum)
        for byte in payload { appendEscaped(&out, byte) }
        out.append(0xC0)
        return out
    }

    static func parse(_ raw: Data) -> (channel: Int, payload: Data)? {
        guard raw.count >= 4 else { return nil }
        var bytes = Array(raw)
        if bytes.first == 0xC0 {
            guard bytes.last == 0xC0 else { return nil }
            bytes.removeFirst()
            bytes.removeLast()
        }
        bytes = unescape(bytes)
        guard bytes.count >= 3 else { return nil }

        if bytes[0] == 0x12 {
            let length = Int(bytes[1]) + 1
            let checksum = UInt8((~(Int(bytes[0]) + Int(bytes[1]))) & 0xFF)
            guard bytes[2] == checksum, length == bytes.count - 3 else { return nil }
            return (2, Data(bytes[3..<bytes.count]))
        }

        let h0 = bytes[0]
        let h1 = bytes[1]
        let checksum = bytes[2]
        let length = Int(h0 >> 4) | (Int(h1) << 4)
        guard ((Int(h0) + Int(h1) + Int(checksum)) & 0xFF) == 0 else { return nil }
        guard length == bytes.count - 3, (h0 & 0x0F) == 3 else { return nil }
        return (3, Data(bytes[3..<bytes.count]))
    }

    static func decodeSMSFragment(_ payload: Data) -> K7SMSFragment? {
        guard payload.count >= 8, payload[0] == evtSMS, payload[1] == 0x02 else { return nil }
        let messageID = UInt16(payload[2]) | (UInt16(payload[3]) << 8)
        let index = Int(payload[4])
        let count = Int(payload[5])
        let senderLength = Int(payload[6])
        let bodyLength = Int(payload[7])
        guard messageID != 0, count > 0, count <= 32, index < count,
              payload.count == 8 + senderLength + bodyLength,
              senderLength <= 32, bodyLength <= 72,
              (index == 0 ? senderLength > 0 : senderLength == 0) else { return nil }
        let sender: String?
        if index == 0 {
            let senderData = Data(payload[8..<(8 + senderLength)])
            guard let decoded = String(data: senderData, encoding: .utf8) else { return nil }
            sender = decoded
        } else {
            sender = nil
        }
        let bodyStart = 8 + senderLength
        return K7SMSFragment(
            messageID: messageID,
            index: index,
            count: count,
            sender: sender,
            bodyBytes: Data(payload[bodyStart..<payload.count])
        )
    }

    static func decodeSMS(_ payload: Data) -> (sender: String, body: String)? {
        guard payload.count >= 4, payload[0] == evtSMS, payload[1] == 0x01 else { return nil }
        let senderLength = Int(payload[2])
        let bodyLength = Int(payload[3])
        guard senderLength > 0,
              payload.count == 4 + senderLength + bodyLength else { return nil }
        let senderStart = 4
        let bodyStart = senderStart + senderLength
        let senderData = Data(payload[senderStart..<bodyStart])
        let bodyData = Data(payload[bodyStart..<payload.count])
        guard let sender = String(data: senderData, encoding: .utf8),
              let body = String(data: bodyData, encoding: .utf8) else { return nil }
        return (sender, body)
    }

    static func decodeIncomingNumber(_ payload: Data) -> String {
        guard payload.count > 2 else { return "" }
        let raw = Data(payload.dropFirst(2))
        return String(data: raw, encoding: .utf16LittleEndian)?
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func decodeASCIIBlock(_ payload: Data, offset: Int) -> String {
        guard payload.count > offset else { return "" }
        return String(data: Data(payload.dropFirst(offset)), encoding: .ascii)?
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func appendEscaped(_ out: inout Data, _ value: UInt8) {
        switch value {
        case 0xC0: out.append(contentsOf: [0xDB, 0xDC])
        case 0xDB: out.append(contentsOf: [0xDB, 0xDD])
        default: out.append(value)
        }
    }

    private static func unescape(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if input[index] == 0xDB, index + 1 < input.count {
                switch input[index + 1] {
                case 0xDC:
                    output.append(0xC0)
                    index += 2
                    continue
                case 0xDD:
                    output.append(0xDB)
                    index += 2
                    continue
                default:
                    break
                }
            }
            output.append(input[index])
            index += 1
        }
        return output
    }
}
