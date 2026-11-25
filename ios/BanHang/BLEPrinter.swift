import Foundation
import CoreBluetooth

/// Kết nối và gửi lệnh ESC/POS tới máy in nhiệt qua Bluetooth LE.
final class BLEPrinter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    /// Dịch vụ in thường gặp trên máy in nhiệt (Xprinter, Goojprt, Gprinter, Phomemo, …)
    private static let knownServices: Set<String> = [
        "18F0", "000018F0-0000-1000-8000-00805F9B34FB",
        "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2",
        "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
        "FF00", "FFE0", "FFF0", "AE30"
    ]

    private var central: CBCentralManager?
    private var readyWaiters: [(String?) -> Void] = []

    private var found: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]

    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var writeIsPreferred = false
    private var servicesLeft = 0

    private var connectDone: ((String?) -> Void)?
    private var sendDone: ((String?) -> Void)?
    private var chunks: [Data] = []
    private var withResponse = false
    private var timeoutWork: DispatchWorkItem?

    // MARK: - Trạng thái Bluetooth

    private func whenReady(_ cb: @escaping (String?) -> Void) {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        guard let c = central else { cb("Bluetooth chưa sẵn sàng"); return }
        switch c.state {
        case .poweredOn: cb(nil)
        case .unknown, .resetting: readyWaiters.append(cb)
        default: cb(stateMessage(c.state))
        }
    }

    private func stateMessage(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOff: return "Bluetooth đang tắt — hãy bật Bluetooth"
        case .unauthorized: return "Chưa cho phép Bluetooth — vào Cài đặt iPhone › Bán Hàng › bật Bluetooth"
        case .unsupported: return "Thiết bị không hỗ trợ Bluetooth LE"
        default: return "Bluetooth chưa sẵn sàng"
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .unknown || c.state == .resetting { return }
        let err: String? = c.state == .poweredOn ? nil : stateMessage(c.state)
        if c.state != .poweredOn { writeChar = nil }
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0(err) }
    }

    private func startTimeout(_ seconds: Double, _ action: @escaping () -> Void) {
        timeoutWork?.cancel()
        let w = DispatchWorkItem(block: action)
        timeoutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    // MARK: - Tìm máy in

    func scan(seconds: Double, done: @escaping ([[String: String]]?, String?) -> Void) {
        whenReady { err in
            if let err = err { done(nil, err); return }
            guard let c = self.central else { return }
            if let p = self.peripheral, p.state == .connected {
                self.found[p.identifier] = p
                if self.names[p.identifier] == nil { self.names[p.identifier] = p.name ?? "Máy in" }
            }
            c.scanForPeripherals(withServices: nil, options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                c.stopScan()
                let list: [[String: String]] = self.found.values.map {
                    ["name": self.names[$0.identifier] ?? $0.name ?? "", "address": $0.identifier.uuidString]
                }.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
                done(list, nil)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        guard let n = name, !n.isEmpty else { return }
        found[p.identifier] = p
        names[p.identifier] = n
    }

    // MARK: - In

    func printData(identifier: String, data: Data, done: @escaping (String?) -> Void) {
        if sendDone != nil || connectDone != nil { done("Máy in đang bận, thử lại sau giây lát"); return }
        whenReady { err in
            if let err = err { done(err); return }
            self.connect(identifier) { err in
                if let err = err { done(err); return }
                self.send(data, done: done)
            }
        }
    }

    private func connect(_ identifier: String, done: @escaping (String?) -> Void) {
        guard let c = central, let uuid = UUID(uuidString: identifier) else {
            done("Máy in chưa được chọn đúng — vào Cài đặt, bấm Tìm máy in rồi chọn lại"); return
        }
        if let p = peripheral, p.identifier == uuid, p.state == .connected, writeChar != nil {
            done(nil); return
        }
        if let old = peripheral, old.identifier != uuid { c.cancelPeripheralConnection(old) }
        writeChar = nil
        writeIsPreferred = false
        guard let p = found[uuid] ?? c.retrievePeripherals(withIdentifiers: [uuid]).first else {
            done("Không thấy máy in — hãy bật máy in, vào Cài đặt bấm Tìm máy in"); return
        }
        peripheral = p
        p.delegate = self
        connectDone = done
        startTimeout(12) {
            c.cancelPeripheralConnection(p)
            self.finishConnect("Không kết nối được máy in. Hãy bật máy in và để gần điện thoại.")
        }
        c.connect(p, options: nil)
    }

    private func finishConnect(_ err: String?) {
        timeoutWork?.cancel()
        let cb = connectDone
        connectDone = nil
        cb?(err)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        finishConnect("Không kết nối được máy in: \(error?.localizedDescription ?? "")")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        writeChar = nil
        if connectDone != nil { finishConnect("Máy in đã ngắt kết nối") }
        if sendDone != nil { finishSend("Máy in ngắt kết nối khi đang in") }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services, !services.isEmpty else {
            finishConnect("Thiết bị này không có cổng in Bluetooth LE"); return
        }
        servicesLeft = services.count
        services.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        servicesLeft -= 1
        let preferred = BLEPrinter.knownServices.contains(service.uuid.uuidString.uppercased())
        for ch in service.characteristics ?? [] {
            let canWrite = ch.properties.contains(.writeWithoutResponse) || ch.properties.contains(.write)
            guard canWrite else { continue }
            if writeChar == nil || (preferred && !writeIsPreferred) {
                writeChar = ch
                writeIsPreferred = preferred
            }
        }
        if servicesLeft <= 0 {
            finishConnect(writeChar == nil ? "Không tìm thấy cổng in — có thể thiết bị này không phải máy in" : nil)
        }
    }

    private func send(_ data: Data, done: @escaping (String?) -> Void) {
        guard let p = peripheral, let ch = writeChar else { done("Chưa kết nối máy in"); return }
        withResponse = !ch.properties.contains(.writeWithoutResponse)
        let maxLen = p.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse)
        let size = max(20, min(maxLen, 180))
        chunks = stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
        sendDone = done
        startTimeout(60) { self.finishSend("Hết thời gian chờ in") }
        pump()
    }

    private func pump() {
        guard sendDone != nil, let p = peripheral, let ch = writeChar else { return }
        if chunks.isEmpty {
            // chờ máy in nhận hết dữ liệu trong bộ đệm
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.finishSend(nil) }
            return
        }
        if withResponse {
            p.writeValue(chunks.removeFirst(), for: ch, type: .withResponse)
        } else {
            if p.canSendWriteWithoutResponse {
                p.writeValue(chunks.removeFirst(), for: ch, type: .withoutResponse)
            }
            // gửi chậm một chút để máy in giá rẻ không bị tràn bộ đệm
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { self.pump() }
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { finishSend("Lỗi gửi dữ liệu tới máy in: \(e.localizedDescription)"); return }
        pump()
    }

    private func finishSend(_ err: String?) {
        guard let cb = sendDone else { return }
        timeoutWork?.cancel()
        chunks = []
        sendDone = nil
        cb(err)
    }
}
