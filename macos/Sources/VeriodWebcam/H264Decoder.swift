import CoreMedia
import Foundation
import VideoToolbox

/// Takes H.264 Annex B bytestreams (with 0x000001/0x00000001 start codes),
/// extracts SPS/PPS to build a `CMFormatDescription`, rewraps slice NALs into
/// AVCC length-prefixed format, and emits a `CMSampleBuffer` ready to be fed
/// to `AVSampleBufferDisplayLayer`.
final class H264Decoder {

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMFormatDescription?

    /// Feed one complete frame's Annex B data. May contain SPS/PPS/IDR/P slices.
    func decode(_ annexB: Data) {
        let nals = splitAnnexB(annexB)
        var avccFrame = Data()

        for nal in nals {
            guard let firstByte = nal.first else { continue }
            let type = firstByte & 0x1F
            switch type {
            case 7: // SPS
                sps = nal
                rebuildFormatIfReady()
            case 8: // PPS
                pps = nal
                rebuildFormatIfReady()
            case 5, 1: // IDR slice or non-IDR slice
                if formatDescription != nil {
                    var length = UInt32(nal.count).bigEndian
                    avccFrame.append(Data(bytes: &length, count: 4))
                    avccFrame.append(nal)
                }
            default:
                break
            }
        }

        if !avccFrame.isEmpty, let fd = formatDescription {
            emitSampleBuffer(data: avccFrame, formatDescription: fd)
        }
    }

    private func splitAnnexB(_ data: Data) -> [Data] {
        var result: [Data] = []
        let bytes = [UInt8](data)
        var nalStart = -1
        var i = 0
        while i < bytes.count {
            if i + 2 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0 {
                let scLen: Int
                if bytes[i + 2] == 1 {
                    scLen = 3
                } else if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    scLen = 4
                } else {
                    i += 1
                    continue
                }
                if nalStart >= 0 {
                    result.append(Data(bytes[nalStart..<i]))
                }
                nalStart = i + scLen
                i = nalStart
                continue
            }
            i += 1
        }
        if nalStart >= 0 && nalStart < bytes.count {
            result.append(Data(bytes[nalStart..<bytes.count]))
        }
        return result
    }

    private func rebuildFormatIfReady() {
        guard let sps, let pps else { return }

        var fd: CMFormatDescription?
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsPtr = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { pointerBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fd
                        )
                    }
                }
            }
        }
        if let fd {
            formatDescription = fd
        }
    }

    private func emitSampleBuffer(data: Data, formatDescription: CMFormatDescription) {
        var blockBuffer: CMBlockBuffer?
        let rawLen = data.count
        let rawPtr = malloc(rawLen)!
        data.copyBytes(to: rawPtr.assumingMemoryBound(to: UInt8.self), count: rawLen)

        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: rawPtr,
            blockLength: rawLen,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: rawLen,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            free(rawPtr)
            return
        }

        var sampleSize = rawLen
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return }

        // Tell the display layer to show this frame immediately — we don't
        // carry PTS from the encoder.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        onSampleBuffer?(sb)
    }
}
