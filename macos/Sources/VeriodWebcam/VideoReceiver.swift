import AVFoundation
import CoreMedia
import Foundation
import Network

/// Listens on a UDP port for type-0x02 packets, reassembles chunks into whole
/// H.264 Annex B frames, and pipes them into `H264Decoder`. Decoded sample
/// buffers are forwarded to the caller (typically an
/// `AVSampleBufferDisplayLayer`).
@MainActor
final class VideoReceiver: ObservableObject {

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusText: String = "Camera idle"
    @Published private(set) var hasSignal: Bool = false

    /// Rotation degrees the Mac should apply to the decoded video so the
    /// image matches how the user is holding the phone. Sent as a control
    /// packet (type 0x03) from the phone whenever device rotation changes.
    @Published private(set) var displayRotationDegrees: Int = 0

    // Counters are plain vars — published updates at 60fps starve the main
    // thread and make button clicks feel laggy. We publish a snapshot text
    // on a 2Hz timer instead.
    private var framesShown: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var lastFrameAt: Date = .distantPast
    private var staleTimer: Timer?
    var onSignalLost: (() -> Void)?

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var listener: NWListener?
    private let assembler = FrameAssembler()
    private let decoder = H264Decoder()

    init() {
        decoder.onSampleBuffer = { [weak self] sb in
            guard let self else { return }
            // Ignore any decode stragglers that finish after stop().
            guard self.isRunningRaw else { return }
            self.framesShown &+= 1
            self.lastFrameAt = Date()
            self.onSampleBuffer?(sb)
            if !self.hasSignalRaw {
                self.hasSignalRaw = true
                Task { @MainActor in
                    if self.isRunningRaw { self.hasSignal = true }
                }
            }
        }
    }

    nonisolated(unsafe) private var hasSignalRaw: Bool = false
    nonisolated(unsafe) private var isRunningRaw: Bool = false

    func start(port: UInt16) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            statusText = "Invalid video port"
            return
        }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: nwPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: .global(qos: .userInteractive))
                self.receive(on: conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready: self.statusText = "Video listening on UDP \(port)"
                    case .failed(let e): self.statusText = "Video failed: \(e.localizedDescription)"; self.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInteractive))
            isRunningRaw = true
            isRunning = true
            framesShown = 0
            framesDropped = 0
            hasSignal = false
            lastFrameAt = .distantPast
            staleTimer?.invalidate()
            staleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let stale = Date().timeIntervalSince(self.lastFrameAt) > 1.0
                    if self.hasSignal && stale {
                        self.hasSignal = false
                        self.hasSignalRaw = false
                        self.onSignalLost?()
                    }
                    if self.isRunning {
                        self.statusText = self.hasSignal
                            ? "Streaming · \(self.framesShown) frames"
                            : "Listening on UDP \(port). Waiting for phone…"
                    }
                }
            }
        } catch {
            statusText = "Video listen error: \(error.localizedDescription)"
        }
    }

    func stop() {
        isRunningRaw = false
        staleTimer?.invalidate()
        staleTimer = nil
        let l = listener
        listener = nil
        isRunning = false
        hasSignal = false
        hasSignalRaw = false
        statusText = "Camera idle"
        onSignalLost?()
        DispatchQueue.global(qos: .utility).async { l?.cancel() }
    }

    nonisolated private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let type = data[0]
                if type == 0x02, data.count >= 8 {
                    let bytes = [UInt8](data)
                    let frameId = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
                    let chunkIdx = bytes[6]
                    let chunkTotal = bytes[7]
                    let payload = data.subdata(in: 8..<data.count)
                    if let frame = self.assembler.add(
                        frameId: frameId,
                        chunkIdx: chunkIdx,
                        chunkTotal: chunkTotal,
                        payload: payload
                    ) {
                        self.decoder.decode(frame)
                    }
                } else if type == 0x03, data.count >= 2 {
                    let orientation = data[1]
                    let degrees: Int = switch orientation {
                    case 0: 0                                      // portrait up
                    case 1: 90                                     // landscape right (phone rotated CW)
                    case 2: 180                                    // portrait down
                    case 3: 270                                    // landscape left (phone rotated CCW)
                    default: 0
                    }
                    Task { @MainActor in
                        if self.displayRotationDegrees != degrees {
                            self.displayRotationDegrees = degrees
                        }
                    }
                }
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }
}

/// Buffers chunks by frame id and returns the assembled Annex B bytestream
/// when every chunk for a frame has arrived. Drops old incomplete frames when
/// the buffer grows past `maxPendingFrames`.
final class FrameAssembler {

    private struct Pending {
        var total: Int
        var chunks: [UInt8: Data] = [:]
    }

    private var pending: [UInt16: Pending] = [:]
    private let maxPendingFrames = 24
    private let lock = NSLock()

    func add(frameId: UInt16, chunkIdx: UInt8, chunkTotal: UInt8, payload: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        var entry = pending[frameId] ?? Pending(total: Int(chunkTotal))
        entry.total = Int(chunkTotal)
        entry.chunks[chunkIdx] = payload
        pending[frameId] = entry

        if entry.chunks.count == entry.total {
            var result = Data()
            for i in 0..<entry.total {
                guard let p = entry.chunks[UInt8(i)] else {
                    pending.removeValue(forKey: frameId)
                    return nil
                }
                result.append(p)
            }
            pending.removeValue(forKey: frameId)
            return result
        }

        // Evict very old pending frames so we don't leak memory on loss.
        if pending.count > maxPendingFrames {
            let oldest = pending.keys.min { UInt16(bitPattern: Int16(bitPattern: $0) &- Int16(bitPattern: frameId)) < UInt16(bitPattern: Int16(bitPattern: $1) &- Int16(bitPattern: frameId)) }
            if let key = oldest {
                pending.removeValue(forKey: key)
            }
        }
        return nil
    }
}
