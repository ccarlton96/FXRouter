// FXRouter app shell — supervises the out-of-process plugin scan (Phase 5).
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.
//
// Launches the app's own binary in `--scan-plugins` worker mode. If the
// worker dies (a plugin crashed while being probed), the dead-man file names
// the culprit: it gets appended to the blacklist and the worker is relaunched
// to continue. The app itself never goes down with a bad plugin (E4).

import AppKit

final class PluginScanManager {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FXRouter")
    static let catalogURL = supportDir.appendingPathComponent("plugins.xml")
    static let deadmanURL = supportDir.appendingPathComponent("scan-deadman.txt")
    static let blacklistURL = supportDir.appendingPathComponent("plugin-blacklist.txt")

    private(set) var scanning = false
    private(set) var lastBlacklisted: [String] = []
    private var process: Process?
    private var relaunchCount = 0
    private let maxRelaunches = 25

    /// Called on the main thread when a scan completes (successfully or not).
    var onFinished: ((_ success: Bool) -> Void)?

    var catalogExists: Bool {
        FileManager.default.fileExists(atPath: Self.catalogURL.path)
    }

    func startScan(log: @escaping (String) -> Void) {
        guard !scanning else { return }
        scanning = true
        relaunchCount = 0
        lastBlacklisted = []
        try? FileManager.default.createDirectory(at: Self.supportDir,
                                                 withIntermediateDirectories: true)
        log("plugin scan started (worker process)")
        launchWorker(log: log)
    }

    private func launchWorker(log: @escaping (String) -> Void) {
        let worker = Process()
        worker.executableURL = Bundle.main.executableURL
        worker.arguments = ["--scan-plugins", Self.catalogURL.path,
                            Self.deadmanURL.path, Self.blacklistURL.path]
        worker.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.workerEnded(status: proc.terminationStatus, log: log)
            }
        }
        do {
            try worker.run()
            process = worker
        } catch {
            scanning = false
            log("plugin scan FAILED to launch worker: \(error.localizedDescription)")
            onFinished?(false)
        }
    }

    private func workerEnded(status: Int32, log: @escaping (String) -> Void) {
        process = nil
        if status == 0 {
            scanning = false
            log("plugin scan finished (blacklisted this run: \(lastBlacklisted.count))")
            onFinished?(true)
            return
        }

        // Worker died — blacklist whatever it was probing and resume.
        let culprit = (try? String(contentsOf: Self.deadmanURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !culprit.isEmpty {
            lastBlacklisted.append(culprit)
            let existing = (try? String(contentsOf: Self.blacklistURL, encoding: .utf8)) ?? ""
            try? (existing + culprit + "\n").write(to: Self.blacklistURL,
                                                   atomically: true, encoding: .utf8)
            log("plugin scan: worker died (status \(status)) probing '\(culprit)' — blacklisted, resuming")
        } else {
            log("plugin scan: worker died (status \(status)) with no culprit recorded")
        }

        relaunchCount += 1
        if relaunchCount <= maxRelaunches {
            launchWorker(log: log)
        } else {
            scanning = false
            log("plugin scan aborted: too many worker crashes")
            onFinished?(false)
        }
    }
}
