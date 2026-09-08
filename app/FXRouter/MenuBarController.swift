// FXRouter app shell — menu-bar UI (Phase 6: chain management).
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

import AppKit
import CoreAudio

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let engine = FXEngineBridge()
    private let scanManager = PluginScanManager()
    private var heartbeat: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true   // system recolors for light/dark menu bar
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "FX"  // fallback if resource missing
        }
        menu.delegate = self
        statusItem.menu = menu

        // Status log (06-expected-behavior.md observability): truncated per
        // launch; engine events + a heartbeat line per minute. A plain file
        // because the unified log redacts NSLog content as <private>.
        try? "".write(to: Self.statusLogURL, atomically: true, encoding: .utf8)

        // F3: no driver yet (fresh DMG install) — offer the in-app installer,
        // then give coreaudiod a moment to publish the device before starting.
        if DriverInstaller.offerInstallIfMissing(log: { [weak self] in self?.appendLog($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.startEngine(outputID: Self.persistedOrSuggestedOutputID())
            }
        }

        // Phase 7: prefer the persisted output device (by stable UID).
        startEngine(outputID: Self.persistedOrSuggestedOutputID())

        // Phase 5: load the persisted plugin catalog; first run kicks off a
        // background out-of-process scan instead.
        scanManager.onFinished = { [weak self] success in
            guard let self else { return }
            if success, self.engine.loadCatalog(fromFile: PluginScanManager.catalogURL.path) {
                self.appendLog("catalog loaded: \(self.engine.catalogPlugins().count) plugins")
                self.restoreChain()
            }
        }
        if scanManager.catalogExists {
            if engine.loadCatalog(fromFile: PluginScanManager.catalogURL.path) {
                appendLog("catalog loaded: \(engine.catalogPlugins().count) plugins")
            }
            restoreChain()
        } else {
            scanManager.startScan { [weak self] in self?.appendLog($0) }
        }

        heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.appendStatusLine()
        }

        installDeviceListListener()
        Onboarding.runIfNeeded { [weak self] in self?.appendLog($0) }
    }

    // MARK: - Persistence (Phase 7)

    private static func persistedOrSuggestedOutputID() -> UInt32 {
        if let uid = AppSettings.outputDeviceUID {
            let id = FXEngineBridge.deviceID(forUID: uid)
            if id != 0 { return id }
        }
        return FXEngineBridge.suggestedOutputDeviceID()
    }

    private func restoreChain() {
        guard engine.chainSlots().isEmpty else { return }  // don't double-restore
        let restored = engine.restoreChain(fromFile: AppSettings.chainURL.path)
        if restored > 0 {
            appendLog("chain restored: \(restored) slots")
        }
    }

    private func saveChain() {
        if !engine.saveChain(toFile: AppSettings.chainURL.path) {
            appendLog("chain save FAILED")
        }
    }

    /// Called by AppDelegate on any termination path (Cmd-Q, logout, Quit item).
    /// Captures latest plugin knob state, and never leaves the user in silence
    /// (failure mode F1): offers to route the system back to a real device.
    func handleTermination() -> NSApplication.TerminateReply {
        saveChain()
        guard FXEngineBridge.systemOutputIsVirtualDevice() else { return .terminateNow }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Your Mac's output is still set to FXRouter"
        alert.informativeText = """
        If you quit now, system audio will go silent until you change the \
        output device in System Settings → Sound.
        """
        alert.addButton(withTitle: "Switch Output & Quit")
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let fallback = FXEngineBridge.suggestedOutputDeviceID()
            if fallback != 0 {
                _ = FXEngineBridge.routeSystemOutput(toDeviceID: fallback)
                appendLog("quit: system output restored to device \(fallback)")
            }
            engine.stop()
            return .terminateNow
        case .alertSecondButtonReturn:
            engine.stop()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // MARK: - Device list changes (E2: output disappears / returns)

    private func installDeviceListListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handleDeviceListChange()
        }
    }

    private func handleDeviceListChange() {
        let available = FXEngineBridge.outputDevices()
        if engine.running {
            let current = engine.currentOutputDeviceID
            if !available.contains(where: { $0.deviceID == current }) {
                appendLog("output device disappeared — falling back (E2)")
                startEngine(outputID: FXEngineBridge.suggestedOutputDeviceID())
            }
        } else {
            // A device (re)appeared — maybe ours; try to come back to life.
            let preferred = Self.persistedOrSuggestedOutputID()
            if preferred != 0 && FXEngineBridge.virtualDeviceInstalled() {
                appendLog("device list changed — attempting engine restart")
                startEngine(outputID: preferred)
            }
        }
    }

    // MARK: - Engine control

    private func startEngine(outputID: UInt32) {
        engine.stop()
        guard FXEngineBridge.virtualDeviceInstalled() else {
            appendLog("engine not started: virtual device not installed")
            return
        }
        if !engine.start(withOutputDeviceID: outputID, bufferFrames: AppSettings.bufferFrames) {
            appendLog("engine start FAILED (output=\(outputID)): \(engine.lastError)")
        } else {
            appendLog("engine started: output=\(outputID) rate=\(Int(engine.sampleRate)) " +
                      "buffer=\(AppSettings.bufferFrames)")
            installRateListeners()
        }
        updateIcon()
    }

    // MARK: - Sample-rate change handling (E1)

    private var rateListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var rateRestartPending = false

    private static func rateAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func installRateListeners() {
        removeRateListeners()
        let devices = [FXEngineBridge.virtualDeviceID(), engine.currentOutputDeviceID]
            .filter { $0 != 0 }
        for device in devices {
            var addr = Self.rateAddress()
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleRateChange()
            }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(device), &addr,
                                                DispatchQueue.main, block)
            rateListeners.append((AudioObjectID(device), block))
        }
    }

    private func removeRateListeners() {
        for (device, block) in rateListeners {
            var addr = Self.rateAddress()
            AudioObjectRemovePropertyListenerBlock(device, &addr, DispatchQueue.main, block)
        }
        rateListeners = []
    }

    private func handleRateChange() {
        guard engine.running, !rateRestartPending else { return }
        // Our own start() sets the virtual device's rate, which fires this
        // listener too — only rebuild when a device genuinely diverged from
        // the engine's running rate.
        let engineRate = engine.sampleRate
        let virtualRate = FXEngineBridge.nominalRate(forDevice: FXEngineBridge.virtualDeviceID())
        let outputRate = FXEngineBridge.nominalRate(forDevice: engine.currentOutputDeviceID)
        guard virtualRate != engineRate || outputRate != engineRate else { return }

        rateRestartPending = true
        appendLog("sample-rate change detected (\(Int(virtualRate))/\(Int(outputRate)) vs " +
                  "\(Int(engineRate))) — rebuilding engine (E1)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.rateRestartPending = false
            self.startEngine(outputID: Self.persistedOrSuggestedOutputID())
        }
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = !engine.running
    }

    // MARK: - Status log

    private static let statusLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FXRouter.log")

    private func appendLog(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.statusLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.statusLogURL)
        }
    }

    private func appendStatusLine() {
        guard engine.running else { return }
        let names = engine.chainSlots().map { slot -> String in
            let name = slot["name"] as? String ?? "?"
            return (slot["bypassed"] as? Bool == true) ? "(\(name))" : name
        }
        appendLog("rate=\(Int(engine.sampleRate)) drift=\(engine.driftPPM)ppm " +
                  "fill=\(engine.bufferFillFrames)/\(engine.bufferTargetFrames) " +
                  "dropouts=\(engine.dropoutCount) resyncs=\(engine.resyncCount) " +
                  String(format: "in=%.4f out=%.4f mem=%dMB ",
                         engine.inputLevel, engine.outputLevel, Self.memoryFootprintMB()) +
                  "bypass=\(engine.masterBypass) chain=[\(names.joined(separator: " → "))]")
    }

    /// Resident memory footprint in MB (N6 leak tracking), -1 if unavailable.
    private static func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    // MARK: - Menu construction (rebuilt each time it opens)

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        buildStatusSection(menu)
        buildChainSection(menu)
        buildWarningsSection(menu)
        buildOutputSection(menu)
        buildSettingsSection(menu)
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit FXRouter", #selector(quit), key: "q"))
    }

    private func buildStatusSection(_ menu: NSMenu) {
        if !FXEngineBridge.virtualDeviceInstalled() {
            menu.addItem(disabledItem("⚠️ FXRouter driver not installed"))
            menu.addItem(actionItem("Install FXRouter Driver…", #selector(installDriver)))
        } else if engine.running {
            menu.addItem(disabledItem(
                "Running — \(Int(engine.sampleRate)) Hz, dropouts: \(engine.dropoutCount)"))
            let ppm = engine.driftPPM
            menu.addItem(disabledItem("Drift correction: \(ppm >= 0 ? "+" : "")\(ppm) ppm"))
        } else {
            let error = engine.lastError
            menu.addItem(disabledItem("Engine stopped" + (error.isEmpty ? "" : " — \(error)")))
            menu.addItem(actionItem("Restart Engine", #selector(restartEngine)))
        }
    }

    private func buildChainSection(_ menu: NSMenu) {
        guard engine.running else { return }
        menu.addItem(.separator())
        menu.addItem(disabledItem("Effect Chain"))
        let slots = engine.chainSlots()
        if slots.isEmpty {
            menu.addItem(disabledItem("    (empty — audio passes through)"))
        }
        for (i, slot) in slots.enumerated() {
            let name = slot["name"] as? String ?? "?"
            let bypassed = slot["bypassed"] as? Bool ?? false
            let item = NSMenuItem(title: "\(i + 1). \(name)\(bypassed ? "  [bypassed]" : "")",
                                  action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(slotAction("Open Editor", #selector(openEditor(_:)), index: i))
            let bypassItem = slotAction(bypassed ? "Un-bypass" : "Bypass",
                                        #selector(toggleSlotBypass(_:)), index: i)
            sub.addItem(bypassItem)
            if i > 0 {
                sub.addItem(slotAction("Move Up", #selector(moveUp(_:)), index: i))
            }
            if i < slots.count - 1 {
                sub.addItem(slotAction("Move Down", #selector(moveDown(_:)), index: i))
            }
            sub.addItem(.separator())
            sub.addItem(slotAction("Remove from Chain", #selector(removeSlot(_:)), index: i))
            item.submenu = sub
            menu.addItem(item)
        }

        // Add Plugin + Presets get their own menu section.
        menu.addItem(.separator())

        // "Add Plugin" catalog browser, grouped by manufacturer.
        let effects = Self.filteredCatalog(engine.catalogPlugins())
        if !effects.isEmpty {
            let addItem = NSMenuItem(title: "Add Plugin", action: nil, keyEquivalent: "")
            let byManufacturer = Dictionary(grouping: effects) {
                ($0["manufacturer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Other"
            }
            let addMenu = NSMenu()
            for maker in byManufacturer.keys.sorted() {
                let makerItem = NSMenuItem(title: maker, action: nil, keyEquivalent: "")
                let makerMenu = NSMenu()
                let plugins = byManufacturer[maker]!.sorted {
                    ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
                }
                for plugin in plugins {
                    let name = plugin["name"] as? String ?? "?"
                    let format = plugin["format"] as? String ?? "?"
                    // AU is the preferred (default) format; only tag the rest.
                    let title = format == "AudioUnit" ? name : "\(name)  —  \(format)"
                    let item = NSMenuItem(title: title,
                                          action: #selector(addPlugin(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = plugin["identifier"]
                    makerMenu.addItem(item)
                }
                makerItem.submenu = makerMenu
                addMenu.addItem(makerItem)
            }
            addItem.submenu = addMenu
            menu.addItem(addItem)
        }

        buildPresetsMenu(menu)
    }

    /// "Presets": save the whole chain under a name, load or delete saved ones.
    private func buildPresetsMenu(_ menu: NSMenu) {
        let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        sub.addItem(actionItem("+ Save New Preset…", #selector(saveNewPreset)))

        let names = PresetStore.list()
        if !names.isEmpty {
            sub.addItem(.separator())
            for name in names {
                let item = NSMenuItem(title: name, action: #selector(loadPreset(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = name
                sub.addItem(item)
            }
        }

        sub.addItem(.separator())
        sub.addItem(actionItem("Reset Default", #selector(resetChain)))

        if !names.isEmpty {
            let overwriteItem = NSMenuItem(title: "Overwrite", action: nil, keyEquivalent: "")
            let overwriteMenu = NSMenu()
            for name in names {
                let item = NSMenuItem(title: name, action: #selector(overwritePreset(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = name
                overwriteMenu.addItem(item)
            }
            overwriteItem.submenu = overwriteMenu
            sub.addItem(overwriteItem)

            let deleteItem = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu()
            for name in names {
                let item = NSMenuItem(title: name, action: #selector(deletePreset(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = name
                deleteMenu.addItem(item)
            }
            deleteItem.submenu = deleteMenu
            sub.addItem(deleteItem)
        }

        presetsItem.submenu = sub
        menu.addItem(presetsItem)
    }

    private func buildSettingsSection(_ menu: NSMenu) {
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        if engine.running {
            let master = NSMenuItem(title: "Master Bypass",
                                    action: #selector(toggleMasterBypass), keyEquivalent: "b")
            master.target = self
            master.state = engine.masterBypass ? .on : .off
            sub.addItem(master)
            sub.addItem(.separator())
        }

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = AppSettings.launchAtLogin ? .on : .off
        sub.addItem(login)

        let mono = NSMenuItem(title: "Hide Mono Plugin Variants",
                              action: #selector(toggleMonoFilter), keyEquivalent: "")
        mono.target = self
        mono.state = AppSettings.filterMonoPlugins ? .on : .off
        sub.addItem(mono)

        let dedupe = NSMenuItem(title: "Hide VST3 Duplicates (prefer AU)",
                                action: #selector(toggleVST3Filter), keyEquivalent: "")
        dedupe.target = self
        dedupe.state = AppSettings.filterVST3Duplicates ? .on : .off
        sub.addItem(dedupe)

        let bufferItem = NSMenuItem(title: "Buffer Size", action: nil, keyEquivalent: "")
        let bufferMenu = NSMenu()
        for frames: UInt32 in [128, 256, 512, 1024] {
            let item = NSMenuItem(title: "\(frames) frames",
                                  action: #selector(selectBufferSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = frames
            item.state = AppSettings.bufferFrames == frames ? .on : .off
            bufferMenu.addItem(item)
        }
        bufferItem.submenu = bufferMenu
        sub.addItem(bufferItem)

        sub.addItem(.separator())
        if scanManager.scanning {
            sub.addItem(disabledItem("Scanning plugins…"))
        } else {
            let count = engine.catalogPlugins().count
            let rescan = NSMenuItem(title: "Rescan Plugins (\(count) known)",
                                    action: #selector(rescanPlugins), keyEquivalent: "")
            rescan.target = self
            sub.addItem(rescan)
        }

        settingsItem.submenu = sub
        menu.addItem(settingsItem)
    }

    // MARK: - Preset actions

    @objc private func saveNewPreset() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save Chain as Preset"
        alert.informativeText = "Saves the current chain, including each plugin's settings."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        PresetStore.prepare()
        if engine.saveChain(toFile: PresetStore.url(for: name).path) {
            appendLog("preset saved: '\(name)'")
        } else {
            appendLog("preset save FAILED: '\(name)'")
        }
    }

    @objc private func loadPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // Replace the current chain: single bulk clear, then bulk restore —
        // audio stays in dry passthrough during the swap (no buffer pile-up).
        engine.clearChain()
        let restored = engine.restoreChain(fromFile: PresetStore.url(for: name).path)
        appendLog("preset loaded: '\(name)' (\(restored) slots)")
        saveChain()  // the loaded preset becomes the persisted working chain
    }

    @objc private func resetChain() {
        engine.clearChain()
        engine.setMasterBypass(false)
        saveChain()
        appendLog("chain reset to default (empty)")
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        PresetStore.delete(name)
        appendLog("preset deleted: '\(name)'")
    }

    @objc private func overwritePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if engine.saveChain(toFile: PresetStore.url(for: name).path) {
            appendLog("preset overwritten: '\(name)'")
        } else {
            appendLog("preset overwrite FAILED: '\(name)'")
        }
    }

    @objc private func selectBufferSize(_ sender: NSMenuItem) {
        guard let frames = sender.representedObject as? UInt32 else { return }
        AppSettings.bufferFrames = frames
        appendLog("settings: buffer size = \(frames) frames — restarting engine")
        startEngine(outputID: Self.persistedOrSuggestedOutputID())
    }

    @objc private func toggleMonoFilter() {
        AppSettings.filterMonoPlugins.toggle()
        appendLog("settings: filter mono = \(AppSettings.filterMonoPlugins)")
    }

    @objc private func toggleVST3Filter() {
        AppSettings.filterVST3Duplicates.toggle()
        appendLog("settings: filter VST3 duplicates = \(AppSettings.filterVST3Duplicates)")
    }

    /// Driver version this app build expects (matches driver/Info.plist).
    private static let expectedDriverVersion = "0.1.0"

    private static func installedDriverVersion() -> String? {
        let plist = "/Library/Audio/Plug-Ins/HAL/FXRouter.driver/Contents/Info.plist"
        return NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String
    }

    private func buildWarningsSection(_ menu: NSMenu) {
        if FXEngineBridge.virtualDeviceInstalled() && !FXEngineBridge.systemOutputIsVirtualDevice() {
            menu.addItem(.separator())
            menu.addItem(disabledItem("⚠️ System output is not FXRouter"))
            menu.addItem(disabledItem("Select it in System Settings → Sound"))
        }
        // F4: driver on disk doesn't match what this app build expects.
        if let installed = Self.installedDriverVersion(),
           installed != Self.expectedDriverVersion {
            menu.addItem(.separator())
            menu.addItem(disabledItem("⚠️ Driver v\(installed), app expects v\(Self.expectedDriverVersion)"))
            menu.addItem(actionItem("Update FXRouter Driver…", #selector(installDriver)))
        }
    }

    /// F3/F4: install or update the driver bundled inside this app, then
    /// bring the engine up once coreaudiod republishes the device.
    @objc private func installDriver() {
        if DriverInstaller.installBundledDriver(log: { [weak self] in self?.appendLog($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.startEngine(outputID: Self.persistedOrSuggestedOutputID())
            }
        }
    }

    private func buildOutputSection(_ menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(disabledItem("Output Device"))
        let current = engine.currentOutputDeviceID
        for device in FXEngineBridge.outputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(selectOutput(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = (engine.running && device.deviceID == current) ? .on : .off
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? FXOutputDevice else { return }
        AppSettings.outputDeviceUID = device.uid
        startEngine(outputID: device.deviceID)
    }

    @objc private func toggleLaunchAtLogin() {
        AppSettings.setLaunchAtLogin(!AppSettings.launchAtLogin)
        appendLog("launch at login: \(AppSettings.launchAtLogin)")
    }

    @objc private func restartEngine() {
        startEngine(outputID: FXEngineBridge.suggestedOutputDeviceID())
    }

    @objc private func rescanPlugins() {
        scanManager.startScan { [weak self] in self?.appendLog($0) }
    }

    @objc private func toggleMasterBypass() {
        engine.setMasterBypass(!engine.masterBypass)
        appendLog("master bypass: \(engine.masterBypass)")
        saveChain()
    }

    @objc private func addPlugin(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        let index = engine.chainSlots().count
        if engine.addPlugin(withIdentifier: identifier, at: UInt(index)) {
            appendLog("chain: added '\(sender.title)' at \(index)")
            saveChain()
            // Open the plugin's editor right away (user pref, 2026-07-11).
            NSApp.activate(ignoringOtherApps: true)
            _ = engine.openEditor(at: UInt(index))
        } else {
            appendLog("chain: add FAILED: \(engine.pluginError)")
            notifyError(engine.pluginError)
        }
    }

    @objc private func removeSlot(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        _ = engine.removePlugin(at: UInt(index))
        appendLog("chain: removed slot \(index)")
        saveChain()
    }

    @objc private func moveUp(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, index > 0 else { return }
        _ = engine.movePlugin(from: UInt(index), to: UInt(index - 1))
        appendLog("chain: moved \(index) up")
        saveChain()
    }

    @objc private func moveDown(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        _ = engine.movePlugin(from: UInt(index), to: UInt(index + 1))
        appendLog("chain: moved \(index) down")
        saveChain()
    }

    @objc private func toggleSlotBypass(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let slots = engine.chainSlots()
        guard index < slots.count else { return }
        let current = slots[index]["bypassed"] as? Bool ?? false
        engine.setPluginAt(UInt(index), bypassed: !current)
        appendLog("chain: slot \(index) bypassed=\(!current)")
        saveChain()
    }

    @objc private func openEditor(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        NSApp.activate(ignoringOtherApps: true)
        _ = engine.openEditor(at: UInt(index))
        appendLog("chain: opened editor for slot \(index)")
    }

    @objc private func quit() {
        // Runs through applicationShouldTerminate → handleTermination(),
        // which saves the chain and applies the F1 quit warning.
        NSApp.terminate(nil)
    }

    // MARK: - Catalog filtering (user prefs, 2026-07-11)

    /// Effects only, with user-toggleable filtering (Settings menu):
    /// mono-variant hiding and AU-preferred dedup of dual-format plugins.
    static func filteredCatalog(
        _ plugins: [[String: Any]],
        filterMono: Bool = AppSettings.filterMonoPlugins,
        dedupePreferAU: Bool = AppSettings.filterVST3Duplicates
    ) -> [[String: Any]] {
        let monoWord = try! NSRegularExpression(pattern: "\\bmono\\b",
                                                options: [.caseInsensitive])
        let usable = plugins.filter { plugin in
            if plugin["isInstrument"] as? Bool == true { return false }
            guard filterMono else { return true }
            // Hide plugins that report a non-stereo-capable channel count.
            let ins = plugin["numIns"] as? Int ?? 0
            let outs = plugin["numOuts"] as? Int ?? 0
            if (ins > 0 && ins < 2) || (outs > 0 && outs < 2) { return false }
            // Hide explicit "Mono" variants by name (e.g. Waves "CLA-76 Mono").
            let name = plugin["name"] as? String ?? ""
            let range = NSRange(name.startIndex..., in: name)
            if monoWord.firstMatch(in: name, range: range) != nil { return false }
            return true
        }
        guard dedupePreferAU else { return usable }
        // Dedupe by (name, manufacturer), preferring the AudioUnit build.
        var chosen: [String: [String: Any]] = [:]
        for plugin in usable {
            // Waves names its AU and VST3 builds differently, so name-based
            // dedup misses them — their VST3s are dropped outright (every
            // Waves plugin ships as WaveShell-AU too). Exact manufacturer
            // match so e.g. "Wavesfactory" is unaffected.
            let manufacturer = plugin["manufacturer"] as? String ?? ""
            if plugin["format"] as? String == "VST3",
               manufacturer == "Waves" || manufacturer.hasPrefix("Waves Audio") {
                continue
            }
            let key = "\(plugin["name"] as? String ?? "")|\(manufacturer)"
            if let existing = chosen[key] {
                if existing["format"] as? String != "AudioUnit",
                   plugin["format"] as? String == "AudioUnit" {
                    chosen[key] = plugin
                }
            } else {
                chosen[key] = plugin
            }
        }
        return Array(chosen.values)
    }

    // MARK: - Helpers

    private func slotAction(_ title: String, _ action: Selector, index: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = index
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func notifyError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "FXRouter"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
