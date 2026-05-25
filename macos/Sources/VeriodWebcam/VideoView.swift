import AVFoundation
import AppKit
import SwiftUI

/// SwiftUI wrapper around `AVSampleBufferDisplayLayer`. External code
/// enqueues `CMSampleBuffer`s via the `layer` property.
final class VideoDisplayNSView: NSView {
    let sampleLayer: AVSampleBufferDisplayLayer

    override var isFlipped: Bool { true }

    init() {
        self.sampleLayer = AVSampleBufferDisplayLayer()
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        sampleLayer.videoGravity = .resizeAspect
        sampleLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(sampleLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        sampleLayer.frame = bounds
    }
}

struct VideoDisplayView: View {
    @ObservedObject var receiver: VideoReceiver

    var body: some View {
        ZStack {
            VideoDisplayNSViewRepresentable(receiver: receiver)
            if !receiver.hasSignal {
                Rectangle()
                    .fill(Color.black)
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Camera is disabled")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(receiver.isRunning
                         ? "Waiting for phone to send video…"
                         : "Tap Start video, then turn the camera on in the phone app.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }
        }
    }
}

private struct VideoDisplayNSViewRepresentable: NSViewRepresentable {
    let receiver: VideoReceiver

    func makeNSView(context: Context) -> VideoDisplayNSView {
        let v = VideoDisplayNSView()
        receiver.onSampleBuffer = { [weak v] sb in
            DispatchQueue.main.async {
                guard let v else { return }
                if v.sampleLayer.status == .failed {
                    v.sampleLayer.flush()
                }
                v.sampleLayer.enqueue(sb)
            }
        }
        receiver.onSignalLost = { [weak v] in
            DispatchQueue.main.async {
                v?.sampleLayer.flushAndRemoveImage()
            }
        }
        return v
    }

    func updateNSView(_ nsView: VideoDisplayNSView, context: Context) {}
}
