import AppKit
import Network
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State: Equatable {
        case idle
        case connecting(String)
        case mirroring(String)
    }

    private var statusItem: NSStatusItem!
    private let browser = TVBrowser()
    private var session: MirrorSession?
    /// Where the current/last session went, so setting changes can restart it.
    private var lastTarget: (endpoint: NWEndpoint, name: String)?
    private var state: State = .idle { didSet { updateIcon() } }
    private lazy var welcome = WelcomeWindow(tvs: { [weak self] in self?.browser.tvs ?? [] },
                                             connect: { [weak self] tv in self?.connect(to: tv.endpoint, name: tv.name) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioMuter.restore() // in case a previous run crashed while the Mac was muted
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        browser.start()

        let args = CommandLine.arguments
        if !UserDefaults.standard.bool(forKey: "welcomeShown") && !args.contains(where: { $0.hasPrefix("--connect") }) {
            UserDefaults.standard.set(true, forKey: "welcomeShown")
            welcome.show()
        }

        // Testing hook, same path as the menu: `open TVMirror.app --args --connect-name "Smart TV"`
        if let i = args.firstIndex(of: "--connect-name"), i + 1 < args.count {
            let name = args[i + 1]
            browser.onChange = { [weak self] in
                guard let self, self.session == nil, let tv = self.browser.tvs.first(where: { $0.name == name }) else { return }
                self.browser.onChange = nil
                self.connect(to: tv.endpoint, name: tv.name)
            }
        }

        // Testing hook: `open TVMirror.app --args --connect 127.0.0.1:47800`
        if let i = args.firstIndex(of: "--connect"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            let port = parts.count > 1 ? UInt16(parts[1]) ?? tvDefaultPort : tvDefaultPort
            connect(to: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: NWEndpoint.Port(rawValue: port)!),
                    name: String(parts[0]))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
        AudioMuter.restore()
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch state {
        case .idle: symbol = "tv"
        case .connecting: symbol = "tv.badge.wifi"
        case .mirroring: symbol = "tv.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TVMirror")
            ?? NSImage(systemSymbolName: "tv", accessibilityDescription: "TVMirror")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = state == .idle ? nil : .controlAccentColor
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        switch state {
        case .idle:
            menu.addItem(header("Mirror to"))
            if browser.tvs.isEmpty {
                menu.addItem(disabled("Looking for TVs… (open TVMirror on the TV)"))
            }
            for tv in browser.tvs {
                let item = NSMenuItem(title: tv.name, action: #selector(connectToTV(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tv
                item.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.addItem(action("Connect to IP Address…", #selector(connectManually)))
        case .connecting(let name):
            menu.addItem(header("Connecting to \(name)…"))
            menu.addItem(action("Cancel", #selector(stopMirroring), key: "."))
        case .mirroring(let name):
            menu.addItem(header("Mirroring to \(name)"))
            menu.addItem(action("Stop Mirroring", #selector(stopMirroring), key: "."))
        }

        menu.addItem(.separator())

        let screens = NSScreen.screens
        if screens.count > 1 {
            let sub = NSMenu()
            let current = Settings.displayID == 0 ? CGMainDisplayID() : Settings.displayID
            for screen in screens {
                let item = NSMenuItem(title: screen.localizedName, action: #selector(pickDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(screen.displayID)
                item.state = screen.displayID == current ? .on : .off
                sub.addItem(item)
            }
            menu.addItem(submenu("Display", sub))
        }

        for m in Mode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = m == Settings.mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let qualityMenu = NSMenu()
        for q in Quality.allCases {
            let item = NSMenuItem(title: q.title, action: #selector(pickQuality(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q.rawValue
            item.state = q == Settings.quality ? .on : .off
            qualityMenu.addItem(item)
        }
        menu.addItem(submenu("Quality", qualityMenu))

        let codecMenu = NSMenu()
        for c in Codec.allCases {
            let item = NSMenuItem(title: c.title, action: #selector(pickCodec(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.state = c == Settings.codec ? .on : .off
            codecMenu.addItem(item)
        }
        menu.addItem(submenu("Video Codec", codecMenu))

        let audio = action("Play Sound on TV", #selector(toggleAudio))
        audio.state = Settings.sendAudio ? .on : .off
        menu.addItem(audio)
        let mute = action("Mute Mac While Mirroring", #selector(toggleMute))
        mute.state = Settings.muteMac ? .on : .off
        mute.isEnabled = Settings.sendAudio
        menu.addItem(mute)

        menu.addItem(.separator())
        menu.addItem(action("Setup Guide…", #selector(showWelcome)))
        let login = action("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Quit TVMirror", #selector(quit), key: "q"))
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - Actions

    @objc private func connectToTV(_ sender: NSMenuItem) {
        guard let tv = sender.representedObject as? TVBrowser.TV else { return }
        connect(to: tv.endpoint, name: tv.name)
    }

    @objc private func connectManually() {
        let alert = NSAlert()
        alert.messageText = "Connect to IP Address"
        alert.informativeText = "Enter the TV's address, as shown in the TVMirror app on the TV."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "192.168.1.50"
        field.stringValue = Settings.lastManualHost
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var host = field.stringValue.trimmingCharacters(in: .whitespaces)
        var port = tvDefaultPort
        if let colon = host.lastIndex(of: ":"), let p = UInt16(host[host.index(after: colon)...]) {
            port = p
            host = String(host[..<colon])
        }
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        Settings.lastManualHost = field.stringValue
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), name: host)
    }

    private func connect(to endpoint: NWEndpoint, name: String) {
        session?.stop()
        let s = MirrorSession(endpoint: endpoint, name: name)
        session = s
        lastTarget = (endpoint, name)
        state = .connecting(name)
        s.onEvent = { [weak self, weak s] event in
            guard let self, let s, self.session === s else { return }
            switch event {
            case .mirroring:
                self.state = .mirroring(name)
            case .ended(let error):
                self.session = nil
                self.state = .idle
                if let error { self.show(error) }
            }
        }
        s.start()
    }

    @objc private func stopMirroring() {
        session?.stop()
    }

    /// Settings apply immediately: an active session restarts with the new settings.
    private func settingsChanged() {
        guard session != nil, let target = lastTarget else { return }
        connect(to: target.endpoint, name: target.name)
    }

    @objc private func pickDisplay(_ sender: NSMenuItem) {
        Settings.displayID = CGDirectDisplayID(sender.tag)
        settingsChanged()
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) else { return }
        Settings.mode = m
        settingsChanged()
    }

    @objc private func pickQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let q = Quality(rawValue: raw) else { return }
        Settings.quality = q
        settingsChanged()
    }

    @objc private func pickCodec(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = Codec(rawValue: raw) else { return }
        Settings.codec = c
        settingsChanged()
    }

    @objc private func toggleAudio() {
        Settings.sendAudio.toggle()
        settingsChanged()
    }

    @objc private func toggleMute() {
        Settings.muteMac.toggle()
        settingsChanged()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            show(error)
        }
    }

    @objc private func showWelcome() {
        welcome.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "TVMirror"
        alert.informativeText = error.localizedDescription
        let isPermission: Bool
        if case MirrorError.screenPermission = error { isPermission = true } else { isPermission = false }
        if isPermission {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, isPermission,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
