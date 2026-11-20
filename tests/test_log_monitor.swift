import Foundation

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("❌ FAILED: \(message)\n", stderr)
        exit(1)
    }
}

func appendLine(_ line: String, to url: URL) throws {
    let data = (line + "\n").data(using: .utf8)!
    if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } else {
        try data.write(to: url)
    }
}

@main
struct LogMonitorTests {
    static func main() throws {
        // 1. Test Dual-Host Lifecycle Auto-Quit Policy
        expect(
            HostLifecyclePolicy.shouldAutoQuit(quitWithHostsEnabled: true, runningBundleIDs: ["com.google.GeminiMacOS"]) == false,
            "Pet must NOT quit when Gemini.app is still running even after Antigravity quits"
        )
        expect(
            HostLifecyclePolicy.shouldAutoQuit(quitWithHostsEnabled: true, runningBundleIDs: ["com.google.antigravity"]) == false,
            "Pet must NOT quit when Antigravity.app is running"
        )
        expect(
            HostLifecyclePolicy.shouldAutoQuit(quitWithHostsEnabled: true, runningBundleIDs: ["com.google.antigravity-ide"]) == false,
            "Pet must NOT quit when Antigravity IDE.app is running"
        )
        expect(
            HostLifecyclePolicy.shouldAutoQuit(quitWithHostsEnabled: true, runningBundleIDs: ["com.apple.Safari", "com.apple.finder"]) == true,
            "Pet MUST quit when all 3 host apps are closed and auto-quit is enabled"
        )
        expect(
            HostLifecyclePolicy.shouldAutoQuit(quitWithHostsEnabled: false, runningBundleIDs: []) == false,
            "Pet must NOT quit when auto-quit toggle is disabled"
        )

        // 2. Test GeminiAppLogMonitor incremental reading, video lifecycle, deduplication & log rotation
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("geminipet_log_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let log1 = tmpDir.appendingPathComponent("diagnostic20261121-000100-1111.log")
        try appendLine("20261121-000100.000 [ChatServiceImpl.swift] VideoGeneration: In progress detected for chat OLD", to: log1)

        let monitor = GeminiAppLogMonitor(logsDirectory: tmpDir, startAtEnd: true)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // Initial poll must seek to EOF and NOT replay old history
        let initialEvents = monitor.poll(now: t0)
        expect(initialEvents.isEmpty, "Initial poll with startAtEnd=true must not replay historical lines")

        // Append VideoGeneration start -> polling -> transient error -> recovery -> completion -> duplicate refresh
        try appendLine("20261121-000110.000 [ChatServiceImpl.swift] VideoGeneration: In progress detected for chat [REDACTED]", to: log1)
        try appendLine("20261121-000110.005 [ChatServiceImpl.swift] VideoGeneration: Starting polling for conversationID=[REDACTED]", to: log1)
        let ev1 = monitor.poll(now: t0.addingTimeInterval(10))
        expect(ev1 == [.videoStarted(detail: "正在生成视频…"), .videoPolling(detail: "正在生成视频…")], "Video start + starting polling mismatch: \(ev1)")
        expect(monitor.videoActive == true, "videoActive should be true")

        try appendLine("20261121-000125.000 [VideoGenerationPollingServiceImpl.swift] VideoGenerationPollingService: Still generating video for chat [REDACTED]", to: log1)
        try appendLine("20261121-000140.000 [VideoGenerationPollingServiceImpl.swift] VideoGenerationPollingService: Polling error for chat [REDACTED]: code=14", to: log1)
        let ev2 = monitor.poll(now: t0.addingTimeInterval(40))
        expect(ev2 == [.videoPolling(detail: "正在生成视频…"), .videoPollingError(detail: "轮询波动，正在重试…", consecutiveErrors: 1)], "Video polling + transient error mismatch: \(ev2)")

        // Recovery resets consecutive error count, then completes, and duplicate Chat refresh complete 1s later is deduplicated
        try appendLine("20261121-000155.000 [VideoGenerationPollingServiceImpl.swift] VideoGenerationPollingService: Still generating video for chat [REDACTED]", to: log1)
        try appendLine("20261121-000210.000 [VideoGenerationPollingServiceImpl.swift] VideoGenerationPollingService: Video generation complete for chat [REDACTED]", to: log1)
        try appendLine("20261121-000211.000 [ChatServiceImpl.swift] VideoGeneration: Chat refresh complete for chat [REDACTED]", to: log1)
        let ev3 = monitor.poll(now: t0.addingTimeInterval(70))
        expect(ev3 == [.videoPolling(detail: "正在生成视频…"), .videoCompleted(detail: "视频已生成完成 🎬")], "Video completion + dedupe mismatch: \(ev3)")
        expect(monitor.videoActive == false, "videoActive should reset to false on completion")

        // 3. Test Streaming Chat chunks, 2s elapsed tracking, endOfData & AbortGeneration
        try appendLine("20261121-000300.000 [RobinProcessQueryStreamer.swift] [Stream] [0.2s] RECV#1: ClientGenerateResponseStream.data", to: log1)
        let chatEv1 = monitor.poll(now: t0.addingTimeInterval(100))
        expect(chatEv1 == [.chatStreamChunk(elapsedSinceStreamStart: 0)], "First chat chunk should have elapsed=0")

        try appendLine("20261121-000303.000 [RobinProcessQueryStreamer.swift] [Stream] [3.0s] RECV#5: ClientGenerateResponseStream.data", to: log1)
        let chatEv2 = monitor.poll(now: t0.addingTimeInterval(103))
        expect(chatEv2 == [.chatStreamChunk(elapsedSinceStreamStart: 3)], "Second chat chunk should report 3s elapsed")

        try appendLine("20261121-000304.000 [RobinProcessQueryStreamer.swift] [Stream] [4.0s] RECV#6: ClientGenerateResponseStream.endOfData", to: log1)
        let chatEv3 = monitor.poll(now: t0.addingTimeInterval(104))
        expect(chatEv3 == [.chatStreamCompleted], "endOfData should emit chatStreamCompleted")

        try appendLine("20261121-000310.000 [RobinProcessQueryStreamer.swift] RECV#1: data", to: log1)
        try appendLine("20261121-000311.000 [ChatService] AbortGeneration requested", to: log1)
        let chatEv4 = monitor.poll(now: t0.addingTimeInterval(110))
        expect(chatEv4 == [.chatStreamChunk(elapsedSinceStreamStart: 0), .chatStreamAborted], "AbortGeneration should emit chatStreamAborted")

        // 4. Test Log Rotation to a newer diagnostic*.log file (new inode -> reads from offset 0)
        let log2 = tmpDir.appendingPathComponent("diagnostic20261121-000500-2222.log")
        try appendLine("20261121-000500.000 [ChatServiceImpl.swift] VideoGeneration: In progress detected for chat ROTATED", to: log2)
        // Ensure log2 has strictly newer mtime than log1
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: log2.path)
        let rotEv = monitor.poll(now: t0.addingTimeInterval(200))
        expect(rotEv == [.videoStarted(detail: "正在生成视频…")], "Rotated new log file should be read from offset 0: \(rotEv)")

        print("✅ test_log_monitor.swift PASSED (all assertions verified)")
    }
}
