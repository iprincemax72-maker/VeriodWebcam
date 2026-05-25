import SwiftUI
import CoreAudio

struct ContentView: View {
    @StateObject private var receiver = AudioReceiver()
    @StateObject private var videoReceiver = VideoReceiver()
    @State private var portText: String = "50001"
    @State private var videoPortText: String = "50002"
    @State private var devices: [AudioDevice] = []
    @State private var selectedDeviceID: AudioDeviceID?
    @State private var testMode: Bool = false
    @State private var gainDb: Double = 0

    var body: some View {
        ScrollView {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VeriodWebcam")
                .font(.largeTitle.bold())

            Text("Receives phone-mic audio over UDP and plays it to the selected output device (use BlackHole 2ch so your Bluetooth earbuds stay on A2DP stereo).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Network") {
                HStack {
                    Text("Port")
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(receiver.isRunning)
                    Spacer()
                    Text("Local IPs: \(NetworkInfo.localIPv4Addresses().joined(separator: ", "))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(8)
            }

            GroupBox("Output device") {
                HStack {
                    Picker("", selection: $selectedDeviceID) {
                        Text("—").tag(AudioDeviceID?.none)
                        ForEach(devices, id: \.id) { d in
                            Text(d.name).tag(Optional(d.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(receiver.isRunning)
                    Button {
                        refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(receiver.isRunning)
                }
                .padding(8)
            }

            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(receiver.isRunning ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(receiver.statusText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.25))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(levelColor(receiver.inputLevel))
                                .frame(width: geo.size.width * CGFloat(min(max(receiver.inputLevel * 1.5, 0), 1)))
                        }
                    }
                    .frame(height: 10)
                    Text("Input level (talk into the phone — this bar should jump)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Voice boost") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gain")
                        Slider(value: $gainDb, in: 0...36, step: 1)
                            .onChange(of: gainDb) { _, newDb in
                                receiver.gain = Float(pow(10.0, newDb / 20.0))
                            }
                        Text(String(format: "+%.0f dB (%.1f×)", gainDb, pow(10.0, gainDb / 20.0)))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 110, alignment: .trailing)
                    }
                    Text("Raise this if your voice sounds quiet on Discord. 0 dB = unchanged. Soft-clipped at the top so loud moments don't distort.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            Toggle(isOn: $testMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test — hear yourself through Mac speakers")
                    Text("Turn this ON to confirm audio is flowing. Turn it OFF for Discord (routes to BlackHole).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: testMode) { _, _ in
                if receiver.isRunning {
                    restart()
                }
            }

            HStack {
                Spacer()
                Button(receiver.isRunning ? "Stop" : "Start") {
                    if receiver.isRunning {
                        receiver.stop()
                    } else {
                        start()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedDeviceID == nil || UInt16(portText) == nil)
            }

            Divider()

            GroupBox("Camera") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Video port")
                        TextField("Port", text: $videoPortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .disabled(videoReceiver.isRunning)
                        Spacer()
                        Button(videoReceiver.isRunning ? "Stop video" : "Start video") {
                            if videoReceiver.isRunning {
                                videoReceiver.stop()
                            } else if let p = UInt16(videoPortText) {
                                videoReceiver.start(port: p)
                            }
                        }
                    }
                    VideoDisplayView(receiver: videoReceiver)
                        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 540)
                        .cornerRadius(8)
                    Text(videoReceiver.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("In OBS → Window Capture → pick this VeriodWebcam window to use as your camera source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Setup")
                    .font(.callout.bold())
                Text("1.  brew install blackhole-2ch").font(.system(.caption, design: .monospaced))
                Text("2.  Pick “BlackHole 2ch” above, click Start").font(.system(.caption, design: .monospaced))
                Text("3.  In Discord / OBS: input → BlackHole 2ch, output → your earbuds").font(.system(.caption, design: .monospaced))
                Text("4.  On phone: enter one of the IPs above + this port, flip Microphone on").font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .onAppear { refreshDevices() }
    }

    private func start() {
        guard let port = UInt16(portText) else { return }
        let targetID: AudioDeviceID?
        if testMode {
            targetID = devices.first(where: { !$0.name.lowercased().contains("blackhole") })?.id
                ?? selectedDeviceID
        } else {
            targetID = selectedDeviceID
        }
        guard let deviceID = targetID else { return }
        receiver.start(port: port, deviceID: deviceID)
    }

    private func restart() {
        receiver.stop()
        start()
    }

    private func levelColor(_ level: Float) -> Color {
        if level < 0.02 { return .gray }
        if level < 0.6 { return .green }
        if level < 0.85 { return .yellow }
        return .red
    }

    private func refreshDevices() {
        devices = AudioDeviceManager.outputDevices()
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first(where: { $0.name.lowercased().contains("blackhole") })?.id
                ?? devices.first?.id
        }
    }
}
