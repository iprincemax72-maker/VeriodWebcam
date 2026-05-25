import CoreAudio
import Foundation
import Network

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

    private var listener: NWListener?
    private var player: AUHALPlayer?
    private var diagTimer: Timer?

    private var packetsReceived: UInt64 = 0
    private var packetsLost: UInt64 = 0
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

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            statusText = "Invalid port"
            teardownPlayer()
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: nwPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: .global(qos: .userInteractive))
                self.receive(on: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.statusText = "Listening on UDP \(port). Waiting for phone…"
                    case .failed(let err):
                        self.statusText = "Listener failed: \(err.localizedDescription)"
                        self.stop()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInteractive))
            isRunning = true
            packetsReceived = 0
            packetsLost = 0
            lastSeq = -1

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
        listener?.cancel()
        listener = nil
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

    nonisolated private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.handlePacket(data)
                }
            }
            if error == nil {
                self.receive(on: connection)
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

        let payload = data.subdata(in: 4..<data.count)
        pushPCM(payload)

        if packetsReceived % 50 == 0 {
            statusText = "Streaming · \(packetsReceived) packets in, \(packetsLost) lost"
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
