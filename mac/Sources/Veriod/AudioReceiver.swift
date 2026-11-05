import CoreAudio
import Darwin
import Foundation

/// Listens on a UDP port for VeriodWebcam audio packets and pipes PCM-16 mono
/// samples into an `AUHALPlayer` that targets a specific output device.
///
/// Packet wire format:
///   byte 0      : 0x01 (audio)
///   bytes 1..3  : 24-bit big-endian sequence number
///   bytes 4..N  : PCM-16 LE mono at 48 kHz
@MainActor
final class AudioReceiver: ObservableObject {

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusText: String = "Idle"
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var diagnostics: String = ""
    var gain: Float = 1.0

    private var player: AUHALPlayer?
    private var diagTimer: Timer?
    private var service: NetService?
    private var sock: Int32 = -1
    private let netQueue = DispatchQueue(label: "veriod.net")
    private var acceptPackets = false

    private(set) var packetsReceived: UInt64 = 0
    private(set) var packetsLost: UInt64 = 0
    private(set) var lastPacket: Date?
    private var lastSeq: Int = -1
    private var pendingPeak: Float = 0
    private var lastLevelPublish: Date = .distantPast

    func start(port: UInt16, deviceID: AudioDeviceID) {
        stop()
        do {
            let p = try AUHALPlayer(deviceID: deviceID, sampleRate: 48_000)
            try p.start()
            self.player = p
        } catch {
            statusText = "Audio engine error: \(error.localizedDescription)"
            return
        }

        // One datagram socket, not an NWConnection per phone. A connection
        // error used to stop the read loop forever, so the window sat on
        // "Phone stopped sending" while the phone was still transmitting.
        do {
            let fd = try openSocket(port)
            sock = fd
            publish(port)
            isRunning = true
            acceptPackets = true
            packetsReceived = 0
            packetsLost = 0
            lastSeq = -1
            statusText = "Waiting for phone…"
            netQueue.async { [weak self] in
                self?.readLoop(fd)
            }

            // Poll AUHAL diagnostics every 0.5s so the UI can show whether
            // audio is actually being rendered to the target device.
            diagTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDiagnostics()
                }
            }
        } catch {
            statusText = "Listen error: \(error.localizedDescription)"
            teardownPlayer()
        }
    }

    func stop() {
        acceptPackets = false
        if sock >= 0 {
            close(sock)
            sock = -1
        }
        service?.stop()
        service = nil
        diagTimer?.invalidate()
        diagTimer = nil
        teardownPlayer()
        isRunning = false
        statusText = "Idle"
        inputLevel = 0
        diagnostics = ""
    }

    private func teardownPlayer() {
        player?.stop()
        player = nil
    }

    private func refreshDiagnostics() {
        guard let p = player else { diagnostics = ""; return }
        let rendered = p.framesRendered
        let consumed = p.framesConsumed
        diagnostics = "Audio out: rendered \(rendered) frames · pulled \(consumed) samples from ring"
    }

    private func openSocket(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var rcv = Int32(1 << 20)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return fd
    }

    private func publish(_ port: UInt16) {
        let svc = NetService(
            domain: "local.",
            type: "_veriod._udp.",
            name: Host.current().localizedName ?? "Mac",
            port: Int32(port)
        )
        svc.schedule(in: .main, forMode: .common)
        svc.publish()
        service = svc
    }

    nonisolated private func readLoop(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(fd, base, raw.count, 0)
            }
            if n <= 0 { break }
            let data = Data(buf.prefix(n))
            Task { @MainActor in
                guard self.acceptPackets else { return }
                self.handlePacket(data)
            }
        }
    }

    private func handlePacket(_ data: Data) {
        guard data.count >= 4 else { return }
        let bytes = [UInt8](data)
        let type = bytes[0]
        guard type == 0x01 else { return }

        let seq = (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        if lastSeq >= 0 {
            let expected = (lastSeq + 1) & 0xFFFFFF
            if seq != expected {
                let diff = (seq - expected) & 0xFFFFFF
                if diff > 0 && diff < 1000 {
                    packetsLost &+= UInt64(diff)
                }
            }
        }
        lastSeq = seq
        packetsReceived &+= 1
        lastPacket = Date()

        let payload = data.subdata(in: 4..<data.count)
        pushPCM(payload)

        if packetsReceived % 50 == 0 {
            statusText = "Phone connected"
        }
    }

    private func pushPCM(_ pcm: Data) {
        guard let player else { return }
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return }

        var floats = [Float](repeating: 0, count: sampleCount)
        var peak: Float = 0
        let g = gain
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            let scale: Float = 1.0 / 32768.0
            for i in 0..<sampleCount {
                let raw = Float(base[i]) * scale * g
                // Soft-clip via tanh so extreme boost (up to 63x) stays smooth
                // instead of turning into square-wave distortion.
                let v = tanhf(raw)
                floats[i] = v
                let a = abs(v)
                if a > peak { peak = a }
            }
        }
        if peak > pendingPeak { pendingPeak = peak }
        let now = Date()
        if now.timeIntervalSince(lastLevelPublish) > 0.08 {
            inputLevel = max(inputLevel * 0.6, pendingPeak)
            pendingPeak = 0
            lastLevelPublish = now
        }

        floats.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                player.writeMono(base, count: sampleCount)
            }
        }
    }
}
