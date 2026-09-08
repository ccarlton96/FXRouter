// FXRouter app shell — in-app driver install/update (F3/F4 remediation).
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.
//
// The HAL driver must live in a root-owned system folder, so it can never be
// drag-and-drop installed. Instead the driver ships INSIDE the app bundle
// (see "Bundle HAL driver" phase in project.yml) and this installer copies it
// into place with a single admin-password prompt — the pattern commercial
// audio tools use. Works identically for source builds and (Stage 2) DMG
// distribution; no Developer ID is required for the install itself.

import AppKit

enum DriverInstaller {
    static let driverDestination = "/Library/Audio/Plug-Ins/HAL/FXRouter.driver"

    /// The driver bundle embedded in this app's Resources.
    static var bundledDriverURL: URL? {
        Bundle.main.url(forResource: "FXRouter", withExtension: "driver")
    }

    /// Copies the bundled driver into the system HAL folder and restarts
    /// coreaudiod, via one osascript admin prompt. Blocks until done (runs
    /// a modal password dialog); call from the main thread only.
    /// Returns true on success. `log` receives progress for the status file.
    @discardableResult
    static func installBundledDriver(log: (String) -> Void) -> Bool {
        guard let src = bundledDriverURL else {
            log("driver install FAILED: no driver bundled in app resources")
            return false
        }

        // Single quoted shell command run as root. Paths are fixed/bundle
        // paths (no user input), so quoting is straightforward.
        // SIP blocks `launchctl kickstart` for coreaudiod on newer macOS;
        // killall works — launchd respawns the daemon immediately.
        let command = """
        rm -rf '\(driverDestination)' && \
        cp -R '\(src.path)' '\(driverDestination)' && \
        chown -R root:wheel '\(driverDestination)' && \
        (launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null \
         || killall coreaudiod)
        """

        // `do shell script ... with administrator privileges` shows the
        // standard macOS password dialog naming this app as the requester.
        let script = "do shell script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSApp.activate(ignoringOtherApps: true)
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)

        if result == nil {
            // -128 = user hit Cancel on the password prompt; not an error.
            let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
            log(code == -128 ? "driver install cancelled by user"
                             : "driver install FAILED: \(error?[NSAppleScript.errorMessage] ?? "unknown")")
            return false
        }
        log("driver installed to \(driverDestination); coreaudiod restarted")
        return true
    }

    /// Launch-time helper: if the driver is absent, offer to install it.
    /// Returns true if an install happened (caller should restart the engine
    /// after the device re-appears — coreaudiod takes a moment to rescan).
    static func offerInstallIfMissing(log: (String) -> Void) -> Bool {
        guard !FXEngineBridge.virtualDeviceInstalled() else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install the FXRouter audio driver?"
        alert.informativeText = """
        FXRouter needs its virtual audio device installed once (admin \
        password required). Audio will pause for a second while the system \
        audio server restarts.
        """
        alert.addButton(withTitle: "Install Driver")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return installBundledDriver(log: log)
    }
}
