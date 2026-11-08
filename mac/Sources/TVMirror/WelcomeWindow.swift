import AppKit

/// Download link for the TV app; `latest` always points at the newest release.
let tvAppURL = "github.com/albepal/TVMirror/releases/latest/download/TVMirror-tv.apk"

/// First-run guide: three steps, each showing whether it's done. Re-opened from "Setup Guide…".
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private let tvs: () -> [TVBrowser.TV]
    private let connect: (TVBrowser.TV) -> Void

    private let permissionStatus = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "Allow…", target: nil, action: nil)
    private let tvStatus = NSTextField(labelWithString: "")
    private let tvButton = NSButton(title: "Mirror", target: nil, action: nil)

    init(tvs: @escaping () -> [TVBrowser.TV], connect: @escaping (TVBrowser.TV) -> Void) {
        self.tvs = tvs
        self.connect = connect
    }

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 425),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to TVMirror"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "Mirror your Mac to your TV")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = wrapping("Three quick steps. You only do this once.", size: 13, color: .secondaryLabelColor)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        let header = NSStackView(views: [icon, titles])
        header.spacing = 14

        // Step 1: TV app.
        let urlField = NSTextField(labelWithString: tvAppURL)
        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        urlField.isSelectable = true
        urlField.lineBreakMode = .byCharWrapping
        urlField.maximumNumberOfLines = 2
        urlField.preferredMaxLayoutWidth = 380
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyURL))
        copy.bezelStyle = .rounded
        let urlRow = NSStackView(views: [urlField, copy])
        urlRow.alignment = .centerY
        let step1 = step(1, "Install TVMirror on your TV", [
            wrapping("On the TV, install the free app “Downloader” from Google Play. Open it, type this address and install:", size: 12),
            urlRow,
            wrapping("Then open TVMirror on the TV. (If the TV asks, allow Downloader to install apps.)", size: 12, color: .secondaryLabelColor),
        ])

        // Step 2: permission.
        permissionButton.target = self
        permissionButton.action = #selector(allowScreenRecording)
        permissionButton.bezelStyle = .rounded
        let step2 = step(2, "Allow screen recording", [statusRow(permissionStatus, permissionButton)])

        // Step 3: pick the TV.
        tvButton.target = self
        tvButton.action = #selector(mirrorFirstTV)
        tvButton.bezelStyle = .rounded
        tvButton.keyEquivalent = "\r"
        let step3 = step(3, "Pick your TV", [
            statusRow(tvStatus, tvButton),
            wrapping("Later, use the TV icon in the menu bar. Press Back on the TV remote to stop.", size: 12, color: .secondaryLabelColor),
        ])

        let stack = NSStackView(views: [header, separator(), step1, step2, step3])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        w.contentView = content
        window = w
    }

    private func refresh() {
        if CGPreflightScreenCaptureAccess() {
            permissionStatus.stringValue = "✅  Allowed"
            permissionButton.isHidden = true
        } else {
            permissionStatus.stringValue = "TVMirror needs to see your screen to send it to the TV."
            permissionButton.isHidden = false
        }
        let found = tvs()
        if let tv = found.first {
            tvStatus.stringValue = found.count == 1 ? "✅  Found “\(tv.name)”" : "✅  Found \(found.count) TVs"
            tvButton.title = "Mirror to \(tv.name)"
            tvButton.isHidden = false
        } else {
            tvStatus.stringValue = "Looking for TVs… open TVMirror on the TV (same Wi-Fi)."
            tvButton.isHidden = true
        }
    }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tvAppURL, forType: .string)
    }

    @objc private func allowScreenRecording() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func mirrorFirstTV() {
        guard let tv = tvs().first else { return }
        window?.close()
        connect(tv)
    }

    // MARK: - Layout helpers

    private func step(_ n: Int, _ title: String, _ body: [NSView]) -> NSView {
        let badge = NSTextField(labelWithString: "\(n)")
        badge.font = .systemFont(ofSize: 13, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 11
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let column = NSStackView(views: [heading] + body)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        let row = NSStackView(views: [badge, column])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func statusRow(_ label: NSTextField, _ button: NSButton) -> NSView {
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 300
        let row = NSStackView(views: [label, button])
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func wrapping(_ text: String, size: CGFloat, color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: size)
        f.textColor = color
        f.preferredMaxLayoutWidth = 450
        return f
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return box
    }
}
