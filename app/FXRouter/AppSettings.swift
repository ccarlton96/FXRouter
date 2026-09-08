// FXRouter app shell — settings persistence & first-run onboarding (Phase 7).
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

import AppKit
import ServiceManagement

enum AppSettings {
    private static let defaults = UserDefaults.standard

    static let chainURL = PluginScanManager.supportDir.appendingPathComponent("chain.xml")

    /// UID (stable across reboots) of the user's chosen real output device.
    static var outputDeviceUID: String? {
        get { defaults.string(forKey: "outputDeviceUID") }
        set { defaults.set(newValue, forKey: "outputDeviceUID") }
    }

    static var firstRunDone: Bool {
        get { defaults.bool(forKey: "firstRunDone") }
        set { defaults.set(newValue, forKey: "firstRunDone") }
    }

    /// Device IO buffer size in frames (E5): smaller = lower latency,
    /// larger = more headroom for heavy chains. Default 256.
    static var bufferFrames: UInt32 {
        get {
            let value = defaults.integer(forKey: "bufferFrames")
            return value == 0 ? 256 : UInt32(value)
        }
        set { defaults.set(Int(newValue), forKey: "bufferFrames") }
    }

    /// Hide Mono plugin variants from the Add Plugin list (default on).
    static var filterMonoPlugins: Bool {
        get { defaults.object(forKey: "filterMonoPlugins") == nil
                ? true : defaults.bool(forKey: "filterMonoPlugins") }
        set { defaults.set(newValue, forKey: "filterMonoPlugins") }
    }

    /// Hide the VST3 build when the same plugin also exists as AU (default on).
    static var filterVST3Duplicates: Bool {
        get { defaults.object(forKey: "filterVST3Duplicates") == nil
                ? true : defaults.bool(forKey: "filterVST3Duplicates") }
        set { defaults.set(newValue, forKey: "filterVST3Duplicates") }
    }

    // Launch-at-login is owned by the OS (SMAppService), not UserDefaults.
    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setLaunchAtLogin(_ enable: Bool) -> Bool {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("FXRouter: launch-at-login change failed: %@", "\(error)")
            return false
        }
    }
}

/// Whole-chain presets: each is a chain XML (same format as chain.xml) in
/// Application Support/FXRouter/Presets/<name>.xml.
enum PresetStore {
    static let dir = PluginScanManager.supportDir.appendingPathComponent("Presets")

    static func url(for name: String) -> URL {
        dir.appendingPathComponent(sanitize(name) + ".xml")
    }

    /// Preset display names, sorted, from the files on disk.
    static func list() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "xml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    static func prepare() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// First-run onboarding (05-app-shell.md): the routing model is non-obvious,
/// so walk the user to flowing audio in two clicks.
enum Onboarding {
    /// Runs the flow if this is the first launch. Returns true if it ran.
    @discardableResult
    static func runIfNeeded(log: (String) -> Void) -> Bool {
        guard !AppSettings.firstRunDone else { return false }
        AppSettings.firstRunDone = true
        NSApp.activate(ignoringOtherApps: true)

        // Step 1 — route the system into FXRouter.
        let route = NSAlert()
        route.messageText = "Welcome to FXRouter"
        route.informativeText = """
        FXRouter processes everything your Mac plays through your own audio \
        plugins, then sends it to your speakers or interface.

        To start, your system sound output needs to be set to the "FXRouter" \
        device. FXRouter can do that for you now.
        """
        route.addButton(withTitle: "Set FXRouter as System Output")
        route.addButton(withTitle: "I'll Do It Later")
        if route.runModal() == .alertFirstButtonReturn {
            let virtualID = FXEngineBridge.virtualDeviceID()
            if virtualID != 0, FXEngineBridge.routeSystemOutput(toDeviceID: virtualID) {
                log("onboarding: system output set to FXRouter")
            } else {
                log("onboarding: FAILED to set system output (driver installed?)")
            }
        }

        // Step 2 — keep FXRouter running so audio never goes silent (F1).
        let login = NSAlert()
        login.messageText = "Start FXRouter at Login?"
        login.informativeText = """
        While your system output is set to FXRouter, audio only plays when \
        FXRouter is running. Starting it automatically at login is strongly \
        recommended.
        """
        login.addButton(withTitle: "Start at Login")
        login.addButton(withTitle: "Not Now")
        if login.runModal() == .alertFirstButtonReturn {
            AppSettings.setLaunchAtLogin(true)
            log("onboarding: launch-at-login enabled")
        }

        // Step 3 — where the processed sound comes out.
        let done = NSAlert()
        done.messageText = "You're Set"
        done.informativeText = """
        Pick where processed audio comes out under FX menu → Output Device, \
        and build your effect chain with Add Plugin. Enjoy!
        """
        done.addButton(withTitle: "Done")
        done.runModal()
        return true
    }
}
