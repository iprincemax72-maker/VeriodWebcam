import AppKit
import CoreAudio
import ServiceManagement

// below 49152 so macOS never hands it to another app as a random outgoing port
let port: UInt16 = 40001

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let receiver = AudioReceiver()
    let updates = UpdateServer()
    var window: NSWindow!
    var devices: [AudioDevice] = []

    let dot = NSView()
    let statusLabel = NSTextField(labelWithString: "Starting…")
    let detailLabel = NSTextField(labelWithString: "")
    let meter = NSLevelIndicator()
    let ipLabel = NSTextField(labelWithString: "")
    let devicePopup = NSPopUpButton()
    let gainSlider = NSSlider(value: 0, minValue: 0, maxValue: 24, target: nil, action: nil)
    let gainLabel = NSTextField(labelWithString: "+0 dB")
    let testBox = NSButton(checkboxWithTitle: "Hear myself (test through earbuds/speakers)", target: nil, action: nil)
    let loginBox = NSButton(checkboxWithTitle: "Open Veriod when I log in", target: nil, action: nil)

    var timer: Timer?
    var lastStartAttempt = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        refreshDevices()
        gainSlider.doubleValue = UserDefaults.standard.double(forKey: "gainDB")
        gainChanged()
        updates.start()
        start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: audio

    var blackhole: AudioDevice? { devices.first { $0.name.lowercased().contains("blackhole") } }

    func isVirtual(_ d: AudioDevice) -> Bool {
        d.name == "Veriod Mic" || d.name.lowercased().contains("blackhole")
    }

    func targetDevice() -> AudioDevice? {
        if testBox.state == .on {
            return devices.first { !isVirtual($0) }
        }
        let i = devicePopup.indexOfSelectedItem
        return devices.indices.contains(i) ? devices[i] : nil
    }

    func start() {
        lastStartAttempt = Date()
        guard let dev = targetDevice() else { return }
        receiver.start(port: port, deviceID: dev.id)
    }

    func refreshDevices() {
        let prev = devicePopup.titleOfSelectedItem
        devices = AudioDeviceManager.outputDevices()
        if let v = AudioDeviceManager.veriodDevice() { devices.insert(v, at: 0) }
        devicePopup.removeAllItems()
        devicePopup.addItems(withTitles: devices.map(\.name))
        if let prev, devices.contains(where: { $0.name == prev }) {
            devicePopup.selectItem(withTitle: prev)
        } else if devices.first?.name == "Veriod Mic" {
            devicePopup.selectItem(at: 0)
        } else if let bh = blackhole {
            devicePopup.selectItem(withTitle: bh.name)
        }
    }

    // MARK: ui loop

    func tick() {
        // listener died or never came up (e.g. port busy) -> keep retrying
        if !receiver.isRunning && Date().timeIntervalSince(lastStartAttempt) > 3 {
            start()
        }

        let live = receiver.lastPacket.map { Date().timeIntervalSince($0) < 1.5 } ?? false
        let color: NSColor
        if !receiver.isRunning {
            color = .systemRed
            statusLabel.stringValue = "Can't listen"
            detailLabel.stringValue = receiver.statusText + " · retrying…"
        } else if live {
            color = .systemGreen
            statusLabel.stringValue = "Phone connected"
            let lost = receiver.packetsLost
            detailLabel.stringValue = lost == 0 ? "Sending your mic to \(targetDevice()?.name ?? "?")"
                : "Sending your mic to \(targetDevice()?.name ?? "?") · \(lost) packets dropped"
        } else if receiver.lastPacket != nil {
            color = .systemOrange
            statusLabel.stringValue = "Phone stopped sending"
            detailLabel.stringValue = "No packets from the phone. Leave the mic switch on."
        } else {
            color = .systemYellow
            statusLabel.stringValue = "Waiting for phone…"
            detailLabel.stringValue = "Turn on the mic in the Veriod phone app"
        }
        dot.layer?.backgroundColor = color.cgColor
        meter.doubleValue = live ? Double(receiver.inputLevel) * 100 : 0

        let ips = NetworkInfo.localIPv4Addresses()
        ipLabel.stringValue = ips.isEmpty ? "No Wi-Fi" : "\(ips.joined(separator: "  or  "))   port \(port)"
    }

    // MARK: actions

    @objc func deviceChanged() { start() }
    @objc func testChanged() { start() }

    @objc func gainChanged() {
        let db = gainSlider.doubleValue.rounded()
        receiver.gain = Float(pow(10, db / 20))
        gainLabel.stringValue = "+\(Int(db)) dB"
        UserDefaults.standard.set(db, forKey: "gainDB")
    }

    @objc func reloadDevices() {
        refreshDevices()
        start()
    }

    @objc func loginChanged() {
        do {
            if loginBox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    // MARK: layout

    func label(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Veriod"
        window.isReleasedWhenClosed = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 7
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 14), dot.heightAnchor.constraint(equalToConstant: 14)])

        statusLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        let statusRow = NSStackView(views: [dot, statusLabel])
        statusRow.spacing = 10

        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0
        meter.maxValue = 100
        meter.warningValue = 75
        meter.criticalValue = 92

        ipLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        ipLabel.isSelectable = true

        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")!,
                              target: self, action: #selector(reloadDevices))
        reload.bezelStyle = .rounded
        let deviceRow = NSStackView(views: [devicePopup, reload])

        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)
        gainLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let gainRow = NSStackView(views: [gainSlider, gainLabel])

        testBox.target = self
        testBox.action = #selector(testChanged)
        loginBox.target = self
        loginBox.action = #selector(loginChanged)
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let help = label("Discord → Voice & Video:\nInput device: Veriod Mic   ·   Output device: your earbuds",
                         size: 11, color: .secondaryLabelColor)

        let stack = NSStackView(views: [
            statusRow, detailLabel, meter,
            label("PHONE APP CONNECTS TO", size: 10, weight: .semibold, color: .tertiaryLabelColor), ipLabel,
            label("SEND MIC TO", size: 10, weight: .semibold, color: .tertiaryLabelColor), deviceRow,
            label("MIC BOOST", size: 10, weight: .semibold, color: .tertiaryLabelColor), gainRow,
            testBox, loginBox, help,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.setCustomSpacing(14, after: meter)
        stack.setCustomSpacing(14, after: ipLabel)
        stack.setCustomSpacing(14, after: deviceRow)
        stack.setCustomSpacing(14, after: gainRow)
        stack.setCustomSpacing(14, after: loginBox)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for v in [meter, deviceRow, gainRow] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 460),
        ])
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
