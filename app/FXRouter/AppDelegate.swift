// FXRouter app shell — Phase 0 stub.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    static func main() {
        // Worker mode (Phase 5): the app relaunches itself headless to scan
        // plugins out-of-process, so a crashing plugin can't take down the UI.
        // Usage: FXRouter --scan-plugins <result.xml> <deadman.txt> <blacklist.txt>
        let args = CommandLine.arguments
        if args.count == 5, args[1] == "--scan-plugins" {
            exit(FXEngineBridge.runScanWorker(withResult: args[2], deadman: args[3],
                                              blacklist: args[4]))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Phase 7 (F1): saves the chain and warns if quitting leaves the
        // system output pointed at the (about to go silent) virtual device.
        menuBarController?.handleTermination() ?? .terminateNow
    }
}
