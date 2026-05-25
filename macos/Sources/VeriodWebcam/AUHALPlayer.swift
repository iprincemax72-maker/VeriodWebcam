import AudioToolbox
import CoreAudio
import Foundation
import os

/// Direct AUHAL output-unit player. Bypasses AVAudioEngine's device-caching
/// quirks. Feed mono Float32 samples via `writeMono`. Render callback duplicates
/// mono → all output channels.
///
/// Exposes `framesRendered` and `framesConsumed` atomics so the UI can confirm
/// that audio is actually being produced to the target device.
final class AUHALPlayer {

    private var unit: AudioUnit?
    let ring = AudioRingBuffer(capacity: 48_000)
    private let rendered = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let consumed = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    var framesRendered: UInt64 { rendered.withLock { $0 } }
    var framesConsumed: UInt64 { consumed.withLock { $0 } }

    init(deviceID: AudioDeviceID, sampleRate: Double = 48_000) throws {
        var lastLabel = "init"
        var lastStatus: OSStatus = noErr
        func track(_ label: String, _ s: OSStatus) {
            lastLabel = label
            lastStatus = s
        }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "AUHAL", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "\(lastLabel) failed (\(lastStatus))"])
        }

        var unitOpt: AudioUnit?
        track("AudioComponentInstanceNew", AudioComponentInstanceNew(comp, &unitOpt))
        guard lastStatus == noErr, let unit = unitOpt else {
            throw NSError(domain: "AUHAL", code: Int(lastStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(lastLabel) failed (\(lastStatus))"])
        }
        self.unit = unit

        var dev = deviceID
        track("Set CurrentDevice", AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ))
        guard lastStatus == noErr else {
            throw NSError(domain: "AUHAL", code: Int(lastStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(lastLabel) failed (\(lastStatus))"])
        }

        // Ask the device what format it wants for output and match our input
        // format to it (same sample rate, same channel count). AUHAL handles
        // the conversion from our Float32 interleaved to the device format
        // internally, but matching the sample rate avoids silent resampler
        // failures with some virtual devices (e.g. BlackHole at 44.1 kHz).
        var deviceFmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        track("Get device StreamFormat", AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,
            &deviceFmt,
            &fmtSize
        ))
        let devSR = deviceFmt.mSampleRate > 0 ? deviceFmt.mSampleRate : sampleRate
        let devCh = deviceFmt.mChannelsPerFrame > 0 ? deviceFmt.mChannelsPerFrame : 2

        var fmt = AudioStreamBasicDescription(
            mSampleRate: devSR,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * devCh,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * devCh,
            mChannelsPerFrame: devCh,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        track("Set input StreamFormat", AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ))
        guard lastStatus == noErr else {
            throw NSError(domain: "AUHAL", code: Int(lastStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(lastLabel) failed (\(lastStatus))"])
        }

        var cb = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frames, ioData -> OSStatus in
                let me = Unmanaged<AUHALPlayer>.fromOpaque(refCon).takeUnretainedValue()
                return me.render(frames: frames, ioData: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        track("Set RenderCallback", AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ))
        guard lastStatus == noErr else {
            throw NSError(domain: "AUHAL", code: Int(lastStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(lastLabel) failed (\(lastStatus))"])
        }

        track("AudioUnitInitialize", AudioUnitInitialize(unit))
        guard lastStatus == noErr else {
            throw NSError(domain: "AUHAL", code: Int(lastStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(lastLabel) failed (\(lastStatus))"])
        }
    }

    deinit {
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
    }

    func start() throws {
        guard let unit else { return }
        let s = AudioOutputUnitStart(unit)
        guard s == noErr else {
            throw NSError(domain: "AUHAL", code: Int(s),
                          userInfo: [NSLocalizedDescriptionKey: "AudioOutputUnitStart failed (\(s))"])
        }
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
    }

    func writeMono(_ samples: UnsafePointer<Float>, count: Int) {
        ring.write(samples, count: count)
    }

    private func render(frames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        guard list.count >= 1 else { return noErr }

        let n = Int(frames)
        rendered.withLock { $0 &+= UInt64(n) }

        let channels = Int(list[0].mNumberChannels)
        let ptr = list[0].mData!.assumingMemoryBound(to: Float.self)

        var mono = [Float](repeating: 0, count: n)
        let got = ring.read(&mono, count: n)
        consumed.withLock { $0 &+= UInt64(got) }

        for i in 0..<n {
            let v = mono[i]
            for c in 0..<channels {
                ptr[i * channels + c] = v
            }
        }
        return noErr
    }
}

final class AudioRingBuffer {
    private var buffer: [Float]
    private var writeIdx = 0
    private var readIdx = 0
    private var available = 0
    private let capacity: Int
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        lock.withLock {
            for i in 0..<count {
                if available == capacity {
                    readIdx = (readIdx + 1) % capacity
                    available -= 1
                }
                buffer[writeIdx] = samples[i]
                writeIdx = (writeIdx + 1) % capacity
                available += 1
            }
        }
    }

    /// Returns number of real samples read (rest filled with silence).
    @discardableResult
    func read(_ dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        lock.withLock {
            var real = 0
            for i in 0..<count {
                if available > 0 {
                    dest[i] = buffer[readIdx]
                    readIdx = (readIdx + 1) % capacity
                    available -= 1
                    real += 1
                } else {
                    dest[i] = 0
                }
            }
            return real
        }
    }
}
