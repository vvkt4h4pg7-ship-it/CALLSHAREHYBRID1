import Foundation
import CoreBluetooth

final class BLEManager: NSObject, ObservableObject {
    private var central: CBCentralManager!
    private(set) var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var flowChar: CBCharacteristic?
    private var txChar: CBCharacteristic?

    var onLog: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDevice: ((String?) -> Void)?
    var onControlPayload: ((Data) -> Void)?
    var onAudioPayload: ((Data) -> Void)?

    var autoReconnect = true
    private var reconnectWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.ugur.callshare.ble.central"]
        )
    }

    func startScan() {
        guard central.state == .poweredOn else {
            log("[BLE] Bluetooth not ready: \(central.state.rawValue)")
            return
        }
        central.stopScan()
        onStatus?("Scanning")
        log("[BLE] Scanning for IKOS K7 service")
        central.scanForPeripherals(withServices: [K7Protocol.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        rxChar = nil
        flowChar = nil
        txChar = nil
        onStatus?("Disconnected")
    }

    func sendAnswer() { sendControl(Data([K7Protocol.cmdAnswer])) }
    func sendHangup() { sendControl(Data([K7Protocol.cmdHangup])) }
    func sendVoiceOpen() { sendControl(Data([K7Protocol.evtVoiceOpen])) }
    func sendVoiceClose() { sendControl(Data([K7Protocol.evtVoiceClose])) }

    func sendMakeCall(number: String, simId: UInt8) {
        sendControl(K7Protocol.makeCallPayload(number: number, simId: simId))
    }

    func sendDTMF(_ value: UInt8) {
        sendControl(K7Protocol.dtmfPayload(value))
    }

    func requestDeviceCheck() { sendControl(Data([K7Protocol.cmdDevCheck])) }
    func requestBattery() { sendControl(Data([K7Protocol.cmdReadBattery])) }
    func requestFirmware() { sendControl(Data([K7Protocol.cmdFirmwareVersion])) }
    func requestIMEI() { sendControl(Data([K7Protocol.cmdIMEIInfo])) }
    func requestCurrentCall() { sendControl(Data([K7Protocol.cmdGetCurrentCall])) }

    func sendAudio(_ amr: Data) {
        guard let p = peripheral, let tx = txChar else { log("[BLE] AUDIO TX unavailable"); return }
        let frame = K7Protocol.wrapAudio(amr)
        log("[BLE] AUDIO TX \(K7Protocol.hex(frame))")
        p.writeValue(frame, for: tx, type: .withoutResponse)
    }

    private func sendControl(_ payload: Data) {
        guard let p = peripheral, let tx = txChar else {
            log("[BLE] TX unavailable")
            return
        }
        let frame = K7Protocol.wrapControl(payload)
        log("[BLE] TX \(K7Protocol.hex(frame))")
        p.writeValue(frame, for: tx, type: .withResponse)
    }

    private func scheduleReconnect() {
        guard autoReconnect, peripheral == nil else { return }
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startScan() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func log(_ value: String) { onLog?(value) }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("[BLE] state=\(central.state.rawValue)")
        if central.state == .poweredOn {
            if let peripheral, peripheral.state == .connected {
                peripheral.delegate = self
                onStatus?("Connected")
                centralDidRestoreOrConnect(peripheral)
            } else {
                startScan()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let saved = restored.first {
            peripheral = saved
            saved.delegate = self
            onDevice?(saved.name)
            log("[BLE] CENTRAL STATE RESTORED peripheral=\(saved.identifier.uuidString) state=\(saved.state.rawValue)")
            if saved.state == .connected {
                onStatus?("Connected")
                centralDidRestoreOrConnect(saved)
            } else if saved.state != .connecting {
                onStatus?("Reconnecting")
                central.connect(saved, options: nil)
            }
        }
    }

    private func centralDidRestoreOrConnect(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([K7Protocol.service])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if self.peripheral != nil { return }
        self.peripheral = peripheral
        onDevice?(peripheral.name)
        log("[BLE] FOUND \(peripheral.name ?? "IKOS K7") RSSI=\(RSSI)")
        central.stopScan()
        onStatus?("Connecting")
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onStatus?("Connected")
        log("[BLE] CONNECTED")
        centralDidRestoreOrConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("[BLE] CONNECT FAIL \(error?.localizedDescription ?? "unknown")")
        self.peripheral = nil
        onStatus?("Disconnected")
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("[BLE] DISCONNECTED \(error?.localizedDescription ?? "")")
        self.peripheral = nil
        rxChar = nil
        flowChar = nil
        txChar = nil
        onStatus?("Disconnected")
        scheduleReconnect()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            log("[BLE] service discovery error \(error!)")
            return
        }
        peripheral.services?.forEach { service in
            log("[BLE] SERVICE \(service.uuid)")
            peripheral.discoverCharacteristics([K7Protocol.rx, K7Protocol.flow, K7Protocol.tx], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            log("[BLE] characteristic discovery error \(error!)")
            return
        }
        service.characteristics?.forEach { characteristic in
            switch characteristic.uuid {
            case K7Protocol.rx:
                rxChar = characteristic
                log("[BLE] RX 5CB8 props=\(characteristic.properties)")
                peripheral.setNotifyValue(true, for: characteristic)
            case K7Protocol.flow:
                flowChar = characteristic
                log("[BLE] FLOW 5CB9 props=\(characteristic.properties)")
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            case K7Protocol.tx:
                txChar = characteristic
                log("[BLE] TX 5CBA props=\(characteristic.properties)")
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        log("[BLE] notify \(characteristic.uuid) enabled=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "none")")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else {
            log("[BLE] RX error \(error?.localizedDescription ?? "no data")")
            return
        }
        log("[BLE] RX \(characteristic.uuid) \(K7Protocol.hex(data))")
        guard let parsed = K7Protocol.parse(data) else {
            log("[BLE] frame parse failed")
            return
        }
        if parsed.channel == 3 {
            NSLog("[J7BRIDGE_DIAG] BLE AUDIO RX len=\(parsed.payload.count)")
            NSLog("[J7BRIDGE_DIAG] BLE TO VoiceEngine.receiveAMR")
            onAudioPayload?(parsed.payload)
        } else {
            onControlPayload?(parsed.payload)
        }
    }
}
