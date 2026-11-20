import Foundation

// MARK: - Dual-Host Lifecycle Policy

enum HostLifecyclePolicy {
    static let antigravityBundleID = "com.google.antigravity"
    static let antigravityIDEBundleID = "com.google.antigravity-ide"
    static let geminiBundleID = "com.google.GeminiMacOS"

    static let hostBundleIDs: Set<String> = [
        antigravityBundleID,
        antigravityIDEBundleID,
        geminiBundleID,
    ]

    /// Returns true only when auto-quit is enabled AND NONE of the monitored host apps remain running.
    static func shouldAutoQuit(quitWithHostsEnabled: Bool, runningBundleIDs: Set<String>) -> Bool {
        guard quitWithHostsEnabled else { return false }
        return runningBundleIDs.isDisjoint(with: hostBundleIDs)
    }
}

// MARK: - Gemini.app Incremental Diagnostic Log Monitor

enum GeminiLogEvent: Equatable {
    case videoStarted(detail: String)
    case videoPolling(detail: String)
    case videoPollingError(detail: String, consecutiveErrors: Int)
    case videoCompleted(detail: String)
    case chatStreamChunk(elapsedSinceStreamStart: TimeInterval)
    case chatStreamCompleted
    case chatStreamAborted
}

final class GeminiAppLogMonitor {
    let logsDirectory: URL
    private let startAtEnd: Bool

    private var hasInitialized = false
    private var currentFilePath: String?
    private var currentInode: UInt64?
    private var currentOffset: UInt64 = 0
    private var partialLineBuffer: String = ""

    private(set) var videoActive: Bool = false
    private(set) var consecutiveVideoErrors: Int = 0
    private var lastVideoCompleteAt: Date?
    private(set) var chatStreamStartedAt: Date?

    init(
        logsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.google.GeminiMacOS/Logs"),
        startAtEnd: Bool = true
    ) {
        self.logsDirectory = logsDirectory
        self.startAtEnd = startAtEnd
    }

    func resetTransientState() {
        videoActive = false
        consecutiveVideoErrors = 0
        chatStreamStartedAt = nil
    }

    /// Poll the latest `diagnostic*.log` file for newly appended lines since last poll.
    func poll(now: Date = Date()) -> [GeminiLogEvent] {
        guard let latestURL = findLatestDiagnosticLog() else {
            hasInitialized = true
            return []
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: latestURL.path) else {
            hasInitialized = true
            return []
        }

        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        if !hasInitialized {
            hasInitialized = true
            currentFilePath = latestURL.path
            currentInode = inode
            currentOffset = startAtEnd ? fileSize : 0
            partialLineBuffer = ""
            if startAtEnd {
                return []
            }
        } else if currentInode != inode || currentFilePath != latestURL.path {
            // Log rotated to a newer diagnostic file: read from the beginning of the new file
            currentFilePath = latestURL.path
            currentInode = inode
            currentOffset = 0
            partialLineBuffer = ""
        } else if fileSize < currentOffset {
            // File was truncated in-place
            currentOffset = 0
            partialLineBuffer = ""
        }

        guard fileSize > currentOffset else {
            return []
        }

        guard let handle = FileHandle(forReadingAtPath: latestURL.path) else {
            return []
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: currentOffset)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return []
            }
            currentOffset += UInt64(data.count)
            guard let chunk = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return []
            }
            return processChunk(chunk, now: now)
        } catch {
            return []
        }
    }

    func processChunk(_ chunk: String, now: Date = Date()) -> [GeminiLogEvent] {
        let combined = partialLineBuffer + chunk
        let endsWithNewline = combined.hasSuffix("\n") || combined.hasSuffix("\r")
        var rawLines = combined.components(separatedBy: .newlines)

        if endsWithNewline {
            partialLineBuffer = ""
        } else if let trailing = rawLines.popLast() {
            partialLineBuffer = trailing
        }

        var events: [GeminiLogEvent] = []
        for line in rawLines where !line.isEmpty {
            if let ev = parseLine(line, now: now) {
                events.append(ev)
            }
        }
        return events
    }

    func parseLine(_ line: String, now: Date = Date()) -> GeminiLogEvent? {
        // 1. High-priority Video Generation events
        if line.contains("VideoGenerationPollingService: Video generation complete")
            || line.contains("VideoGeneration: Chat refresh complete") {
            if !videoActive, let lastDone = lastVideoCompleteAt, now.timeIntervalSince(lastDone) < 8.0 {
                return nil
            }
            videoActive = false
            consecutiveVideoErrors = 0
            lastVideoCompleteAt = now
            return .videoCompleted(detail: "视频已生成完成 🎬")
        }

        if line.contains("VideoGenerationPollingService: Polling error") {
            consecutiveVideoErrors += 1
            videoActive = true
            return .videoPollingError(detail: "轮询波动，正在重试…", consecutiveErrors: consecutiveVideoErrors)
        }

        if line.contains("VideoGenerationPollingService: Still generating video") {
            consecutiveVideoErrors = 0
            videoActive = true
            return .videoPolling(detail: "正在生成视频…")
        }

        if line.contains("VideoGeneration: In progress detected")
            || line.contains("VideoGeneration: Starting polling") {
            consecutiveVideoErrors = 0
            let wasActive = videoActive
            videoActive = true
            return wasActive ? .videoPolling(detail: "正在生成视频…") : .videoStarted(detail: "正在生成视频…")
        }

        // 2. Gemini Chat Streaming events
        if line.contains("ClientGenerateResponseStream.endOfData") {
            chatStreamStartedAt = nil
            return .chatStreamCompleted
        }

        if line.contains("AbortGeneration") {
            chatStreamStartedAt = nil
            return .chatStreamAborted
        }

        if line.contains("[RobinProcessQueryStreamer.swift")
            && line.contains("RECV#")
            && !line.contains("endOfData") {
            if chatStreamStartedAt == nil {
                chatStreamStartedAt = now
            }
            let elapsed = now.timeIntervalSince(chatStreamStartedAt ?? now)
            return .chatStreamChunk(elapsedSinceStreamStart: elapsed)
        }

        return nil
    }

    private func findLatestDiagnosticLog() -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var bestURL: URL?
        var bestDate: Date = .distantPast

        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix("diagnostic") && name.hasSuffix(".log") else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let mdate = vals?.contentModificationDate ?? .distantPast
            if mdate > bestDate {
                bestDate = mdate
                bestURL = url
            }
        }
        return bestURL
    }
}
