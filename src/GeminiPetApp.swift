import AppKit
import AVFoundation
import Carbon
import Combine
import SwiftUI

// MARK: - Models

enum PetMood: String, CaseIterable {
    case idle
    case happy
    case working
    case hiss
    case sleep
    case drag

    var displayName: String {
        switch self {
        case .idle: return "待机"
        case .happy: return "开心"
        case .working: return "干活"
        case .hiss: return "哈气"
        case .sleep: return "打盹"
        case .drag: return "拎起"
        }
    }

    var icon: String {
        switch self {
        case .idle: return "✦"
        case .happy: return "💗"
        case .working: return "💻"
        case .hiss: return "💢"
        case .sleep: return "💤"
        case .drag: return "🐾"
        }
    }
}

enum PetSizePreset: CGFloat, CaseIterable {
    case xs = 80
    case sm = 96
    case gptDefault = 112
    case md = 136
    case lg = 164

    var title: String {
        switch self {
        case .xs: return "超小 (80px)"
        case .sm: return "偏小 (96px)"
        case .gptDefault: return "GPT 默认同款 (112px)"
        case .md: return "偏大 (136px)"
        case .lg: return "大号 (164px)"
        }
    }
}

enum MotionStyle: String, CaseIterable {
    case calm
    case still
    case lively

    var title: String {
        switch self {
        case .calm: return "克制微动（推荐）"
        case .still: return "完全静态（减少动态）"
        case .lively: return "活泼动画"
        }
    }
}

enum AIModelPreset: String, CaseIterable {
    case fast = "gemini-3.5-flash-lite"
    case smart = "gemini-4-hydrogen"

    var title: String {
        switch self {
        case .fast: return "极速响应 (Flash Lite)"
        case .smart: return "深度思考 (Gemini 4)"
        }
    }
}

enum ActivePanelMode: Equatable {
    case none
    case chat
    case voice
    case activity
}

struct ChatEntry: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
    let hasImage: Bool
    let isVoice: Bool
    let time: Date
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let state: String // working, done, hiss, chat
    let time: Date
}

struct BridgeResponse: Decodable {
    let ok: Bool
    let text: String?
    let interaction_id: String?
    let audio_path: String?
    let error: String?
}

struct AgyStatusPayload: Decodable {
    let state: String
    let message: String?
    let updatedAt: Double?
}

// MARK: - Voice Recorder & Audio Player

@MainActor
final class VoiceController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var recordingSeconds: Int = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var recordTimer: Timer?
    private var currentRecordURL: URL?

    func startRecording(completion: @escaping (Bool, String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginActualRecording(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        self.beginActualRecording(completion: completion)
                    } else {
                        completion(false, "请在系统设置中允许麦克风权限")
                    }
                }
            }
        default:
            completion(false, "未获得麦克风权限，请在系统设置→隐私→麦克风中开启")
        }
    }

    private func beginActualRecording(completion: @escaping (Bool, String?) -> Void) {
        stopPlayback()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("geminipet_voice_\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.prepareToRecord()
            guard rec.record() else {
                completion(false, "麦克风启动失败")
                return
            }
            self.recorder = rec
            self.currentRecordURL = url
            self.isRecording = true
            self.recordingSeconds = 0
            self.recordTimer?.invalidate()
            self.recordTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.recordingSeconds += 1
                }
            }
            completion(true, nil)
        } catch {
            completion(false, "录音初始化失败：\(error.localizedDescription)")
        }
    }

    func stopRecording() -> URL? {
        recordTimer?.invalidate()
        recordTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        let url = currentRecordURL
        currentRecordURL = nil
        return url
    }

    func cancelRecording() {
        if let url = stopRecording() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func playAudioOrSpeak(audioPath: String?, fallbackText: String) {
        stopPlayback()
        if let path = audioPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                if p.play() {
                    self.player = p
                    self.isSpeaking = true
                    return
                }
            } catch {
                // Fall through to system speech
            }
        }
        speakSystemTTS(fallbackText)
    }

    func speakSystemTTS(_ text: String) {
        stopPlayback()
        let clean = text
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
        let utter = AVSpeechUtterance(string: clean)
        utter.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utter.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        isSpeaking = true
        synthesizer.speak(utter)
        // Reset speaking indicator cleanly after estimated duration
        let approxSec = max(1.8, min(20.0, Double(clean.count) * 0.22))
        Task {
            try? await Task.sleep(nanoseconds: UInt64(approxSec * 1_000_000_000))
            if !self.synthesizer.isSpeaking {
                self.isSpeaking = false
            }
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}

// MARK: - Pet ViewModel

@MainActor
final class PetViewModel: ObservableObject {
    @Published var mood: PetMood = .idle
    @Published var bubbleText: String? = "哈基米已就位 · 悬停或 ⌥G 对话 ✦"
    @Published var showBubble: Bool = true
    @Published var isHovering: Bool = false
    @Published var activePanel: ActivePanelMode = .none {
        didSet { onPanelModeChanged?(activePanel) }
    }
    @Published var miniMode: Bool = false {
        didSet { onSizeChanged?() }
    }
    @Published var isFacingLeft: Bool = false
    @Published var dragTiltDegrees: Double = 0
    @Published var petSize: PetSizePreset = .gptDefault {
        didSet { onSizeChanged?() }
    }
    @Published var motionStyle: MotionStyle = .calm
    @Published var modelPreset: AIModelPreset = .fast
    @Published var alwaysOnTop: Bool = true {
        didSet { onAlwaysOnTopChanged?(alwaysOnTop) }
    }
    @Published var wanderEnabled: Bool = false
    @Published var agySyncEnabled: Bool = true
    @Published var isVisible: Bool = true

    // Quick Chat & Screen & Voice & Activity state
    @Published var inputText: String = ""
    @Published var isThinking: Bool = false
    @Published var attachedScreenPath: String? = nil
    @Published var messages: [ChatEntry] = []
    @Published var activities: [ActivityEntry] = [
        ActivityEntry(title: "哈基米桌宠已启动", detail: "悬停可快速输入、语音对话或看屏幕提问", state: "done", time: Date())
    ]
    @Published var unreadCount: Int = 0
    @Published var voiceStatusHint: String = "点击麦克风开始说话"
    @Published var focusInputTrigger: UUID = UUID()

    let voice = VoiceController()

    var sprites: [PetMood: NSImage] = [:]
    var onSizeChanged: (() -> Void)?
    var onAlwaysOnTopChanged: ((Bool) -> Void)?
    var onMoveWindowBy: ((CGFloat, CGFloat) -> Void)?
    var onGetWindowFrame: (() -> NSRect)?
    var onPanelModeChanged: ((ActivePanelMode) -> Void)?

    private var lastInteractionDate = Date()
    private var recentPokeTimestamps: [Date] = []
    private var bubbleDismissTask: Task<Void, Never>?
    private var hoverHideTask: Task<Void, Never>?
    private var moodResetTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var wanderDirection: CGFloat = -1
    private var wanderPauseUntil: Date = .distantPast
    private var lastAgyUpdatedAt: Double = 0
    private var isDragging = false
    private var previousInteractionId: String = ""
    private var voiceCancellable: AnyCancellable?

    private let happyLines = ["呼噜~ ✦", "摸摸头 💗", "在呢喵~", "随时听候差遣 ✦"]
    private let hissLines = ["哈——！💢", "别一直戳啦！", "炸毛了喵 💢"]

    init() {
        loadSprites()
        startTimers()
        scheduleBubbleDismiss(after: 3.0)
        // Forward voice observable changes so SwiftUI re-renders cleanly
        voiceCancellable = voice.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func loadSprites() {
        let dir: URL
        if let bundleRes = Bundle.main.resourceURL?.appendingPathComponent("sprites"),
           FileManager.default.fileExists(atPath: bundleRes.path) {
            dir = bundleRes
        } else {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            dir = cwd.appendingPathComponent("sprites")
        }
        for m in PetMood.allCases {
            let url = dir.appendingPathComponent("\(m.rawValue).png")
            if let img = NSImage(contentsOf: url) {
                sprites[m] = img
            }
        }
    }

    private func bridgeScriptPath() -> String {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("pet_ai_bridge.py"),
           FileManager.default.fileExists(atPath: res.path) {
            return res.path
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/pet_ai_bridge.py").path
    }

    func currentImage() -> NSImage? {
        sprites[mood] ?? sprites[.idle]
    }

    private func startTimers() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onTick()
            }
        }
    }

    private var tickCount = 0
    private func onTick() {
        tickCount += 1
        let now = Date()

        if !isDragging && abs(dragTiltDegrees) > 0.1 {
            dragTiltDegrees *= 0.78
            if abs(dragTiltDegrees) < 0.15 { dragTiltDegrees = 0 }
        }

        if !isDragging && !isThinking && !voice.isRecording && activePanel == .none
            && mood == .idle && now.timeIntervalSince(lastInteractionDate) > 180 {
            setMood(.sleep, autoResetAfter: nil, speech: nil)
        }

        if wanderEnabled && !miniMode && !isDragging && activePanel == .none && mood == .idle && now > wanderPauseUntil {
            if let frame = onGetWindowFrame?(), let screen = NSScreen.main?.visibleFrame {
                let speed: CGFloat = 0.85
                var dx = wanderDirection * speed
                if frame.minX + dx < screen.minX + 10 {
                    wanderDirection = 1
                    dx = speed
                    wanderPauseUntil = now.addingTimeInterval(Double.random(in: 3.0...6.0))
                } else if frame.maxX + dx > screen.maxX - 10 {
                    wanderDirection = -1
                    dx = -speed
                    wanderPauseUntil = now.addingTimeInterval(Double.random(in: 3.0...6.0))
                } else if Int.random(in: 0..<300) == 0 {
                    wanderPauseUntil = now.addingTimeInterval(Double.random(in: 4.0...8.0))
                }
                isFacingLeft = wanderDirection < 0
                onMoveWindowBy?(dx, 0)
            }
        }

        if agySyncEnabled && tickCount % 6 == 0 {
            pollAgyStatus()
        }
    }

    private func pollAgyStatus() {
        let statusURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/gemini_pet_status.json")
        guard let data = try? Data(contentsOf: statusURL),
              let payload = try? JSONDecoder().decode(AgyStatusPayload.self, from: data) else {
            return
        }
        let ts = payload.updatedAt ?? 0
        guard ts > lastAgyUpdatedAt else { return }
        lastAgyUpdatedAt = ts

        if Date().timeIntervalSince1970 - ts > 60 { return }

        lastInteractionDate = Date()
        let msg = payload.message ?? ""
        switch payload.state {
        case "working":
            if !isThinking {
                setMood(.working, autoResetAfter: 45, speech: "思考中… ✦")
            }
            pushActivity(title: "Antigravity 运行中", detail: msg.isEmpty ? "正在执行任务" : msg, state: "working", markUnread: false)
        case "done":
            if !isThinking {
                setMood(.happy, autoResetAfter: 4.0, speech: "任务完成 ✦")
            }
            pushActivity(title: "Antigravity 任务完成", detail: msg.isEmpty ? "可以切回去查看结果啦" : msg, state: "done", markUnread: true)
        case "hiss":
            if !isThinking {
                setMood(.hiss, autoResetAfter: 3.5, speech: "出错了 💢")
            }
            pushActivity(title: "Antigravity 遇到错误", detail: msg.isEmpty ? "请检查最近一次操作" : msg, state: "hiss", markUnread: true)
        default:
            if !isThinking {
                setMood(.idle, autoResetAfter: nil, speech: nil)
            }
        }
    }

    private func pushActivity(title: String, detail: String, state: String, markUnread: Bool) {
        let entry = ActivityEntry(title: title, detail: detail, state: state, time: Date())
        activities.insert(entry, at: 0)
        if activities.count > 20 { activities.removeLast() }
        if markUnread && activePanel != .activity {
            unreadCount += 1
        }
    }

    // MARK: - Hover & Panel Controls

    func setHovering(_ hovering: Bool) {
        hoverHideTask?.cancel()
        if hovering {
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = true
            }
        } else {
            hoverHideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if let self, self.activePanel == .none && !self.voice.isRecording {
                        withAnimation(.easeOut(duration: 0.18)) {
                            self.isHovering = false
                        }
                    }
                }
            }
        }
    }

    func openPanel(_ mode: ActivePanelMode) {
        lastInteractionDate = Date()
        if mode == .activity {
            unreadCount = 0
        }
        if activePanel == mode {
            closePanel()
            return
        }
        if voice.isRecording && mode != .voice {
            voice.cancelRecording()
        }
        activePanel = mode
        if mode == .chat {
            focusInputTrigger = UUID()
        }
    }

    func closePanel() {
        if voice.isRecording {
            voice.cancelRecording()
        }
        activePanel = .none
    }

    // MARK: - Quick Chat / Screen Capture / Voice Mode

    func captureScreenContext() {
        lastInteractionDate = Date()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("geminipet_screen_\(Int(Date().timeIntervalSince1970)).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", outURL.path]
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: outURL.path) {
                attachedScreenPath = outURL.path
                say("已截取当前屏幕 📸", duration: 2.0)
                if activePanel == .none {
                    activePanel = .chat
                    focusInputTrigger = UUID()
                }
            } else {
                say("截屏失败，请检查录屏权限", duration: 2.6)
            }
        } catch {
            say("截屏失败", duration: 2.4)
        }
    }

    func clearAttachedScreen() {
        if let p = attachedScreenPath {
            try? FileManager.default.removeItem(atPath: p)
        }
        attachedScreenPath = nil
    }

    func startNewChat() {
        previousInteractionId = ""
        messages.removeAll()
        clearAttachedScreen()
        say("已开启新对话 ✦", duration: 1.8)
    }

    func sendTextPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgPath = attachedScreenPath
        guard !text.isEmpty || imgPath != nil else { return }
        guard !isThinking else { return }

        let displayPrompt = text.isEmpty ? "看看我当前屏幕里的内容" : text
        messages.append(ChatEntry(isUser: true, text: displayPrompt, hasImage: imgPath != nil, isVoice: false, time: Date()))
        inputText = ""
        attachedScreenPath = nil

        callBridge(prompt: text, audioPath: nil, imagePath: imgPath, speak: false)
    }

    func toggleVoiceRecording() {
        lastInteractionDate = Date()
        if voice.isRecording {
            guard let audioURL = voice.stopRecording() else { return }
            let imgPath = attachedScreenPath
            attachedScreenPath = nil
            voiceStatusHint = "正在听懂并思考回复…"
            messages.append(ChatEntry(isUser: true, text: "🎙 语音消息（\(max(1, voice.recordingSeconds))s）", hasImage: imgPath != nil, isVoice: true, time: Date()))
            callBridge(prompt: "", audioPath: audioURL.path, imagePath: imgPath, speak: true)
        } else {
            if activePanel != .voice {
                activePanel = .voice
            }
            voice.startRecording { [weak self] ok, err in
                guard let self else { return }
                if ok {
                    self.voiceStatusHint = "正在聆听… 说完点「停止并发送」"
                    self.setMood(.idle, autoResetAfter: nil, speech: "聆听中… 🎙")
                } else {
                    self.voiceStatusHint = err ?? "无法开启麦克风"
                    self.say(err ?? "麦克风权限未开", duration: 3.0)
                }
            }
        }
    }

    private func callBridge(prompt: String, audioPath: String?, imagePath: String?, speak: Bool) {
        isThinking = true
        setMood(.working, autoResetAfter: nil, speech: speak ? "思考语音回复…" : "思考中… ✦")

        let script = bridgeScriptPath()
        let prevId = previousInteractionId
        let model = modelPreset.rawValue

        Task { [weak self] in
            let parsed: BridgeResponse = await Task.detached {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                var args = [script, "--model", model]
                if !prompt.isEmpty { args += ["--prompt", prompt] }
                if let a = audioPath { args += ["--audio", a] }
                if let img = imagePath { args += ["--image", img] }
                if !prevId.isEmpty { args += ["--prev-id", prevId] }
                if speak { args += ["--speak"] }
                proc.arguments = args

                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe

                var outputStr = ""
                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    outputStr = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    outputStr = "{\"ok\":false,\"error\":\"\(error.localizedDescription)\"}"
                }

                if let a = audioPath { try? FileManager.default.removeItem(atPath: a) }
                if let img = imagePath { try? FileManager.default.removeItem(atPath: img) }

                if let line = outputStr.split(separator: "\n").last,
                   let d = line.data(using: .utf8),
                   let r = try? JSONDecoder().decode(BridgeResponse.self, from: d) {
                    return r
                } else {
                    return BridgeResponse(ok: false, text: nil, interaction_id: nil, audio_path: nil, error: outputStr.isEmpty ? "请求失败" : String(outputStr.prefix(160)))
                }
            }.value

            guard let self else { return }
            self.isThinking = false
            if parsed.ok, let reply = parsed.text, !reply.isEmpty {
                if let nid = parsed.interaction_id, !nid.isEmpty {
                    self.previousInteractionId = nid
                }
                self.messages.append(ChatEntry(isUser: false, text: reply, hasImage: false, isVoice: speak, time: Date()))
                self.pushActivity(title: speak ? "语音回复" : "快捷对话回复", detail: reply, state: "chat", markUnread: self.activePanel == .none)
                self.setMood(.happy, autoResetAfter: 3.5, speech: speak ? "播报中… 🔊" : "回复好啦 ✦")
                if speak {
                    self.voiceStatusHint = "正在播报回复（可随时打断再说）"
                    self.voice.playAudioOrSpeak(audioPath: parsed.audio_path, fallbackText: reply)
                }
            } else {
                let err = parsed.error ?? "未知错误"
                self.messages.append(ChatEntry(isUser: false, text: "出错啦：\(err)", hasImage: false, isVoice: false, time: Date()))
                self.voiceStatusHint = "出错：\(err)"
                self.setMood(.hiss, autoResetAfter: 3.5, speech: "请求失败 💢")
            }
        }
    }

    // MARK: - Pet Click / Drag Interactions

    func handleSingleClick() {
        lastInteractionDate = Date()
        let now = Date()
        recentPokeTimestamps = recentPokeTimestamps.filter { now.timeIntervalSince($0) < 3.0 }
        recentPokeTimestamps.append(now)

        if recentPokeTimestamps.count >= 5 {
            recentPokeTimestamps.removeAll()
            setMood(.hiss, autoResetAfter: 2.8, speech: hissLines.randomElement()!)
            return
        }

        if mood == .sleep {
            setMood(.idle, autoResetAfter: nil, speech: "醒啦 ✦")
            return
        }

        setMood(.happy, autoResetAfter: 2.2, speech: happyLines.randomElement()!)
    }

    func handleDoubleClick() {
        openPanel(.chat)
    }

    func beginDrag() {
        isDragging = true
        lastInteractionDate = Date()
        moodResetTask?.cancel()
        if !miniMode && mood != .drag {
            mood = .drag
        }
    }

    func updateDragVelocity(dx: CGFloat) {
        guard motionStyle != .still && !miniMode else { return }
        let maxTilt = (motionStyle == .lively) ? 16.0 : 6.0
        let factor = (motionStyle == .lively) ? 1.0 : 0.4
        let clamped = max(-maxTilt, min(maxTilt, Double(-dx * factor)))
        dragTiltDegrees = dragTiltDegrees * 0.7 + clamped * 0.3
    }

    func endDrag() {
        isDragging = false
        lastInteractionDate = Date()
        if !isThinking {
            mood = .idle
        }
    }

    func selectManualMood(_ newMood: PetMood) {
        lastInteractionDate = Date()
        switch newMood {
        case .idle: setMood(.idle, autoResetAfter: nil, speech: nil)
        case .happy: setMood(.happy, autoResetAfter: 3.0, speech: happyLines.randomElement()!)
        case .working: setMood(.working, autoResetAfter: nil, speech: "干活中 ✦")
        case .hiss: setMood(.hiss, autoResetAfter: 3.0, speech: hissLines.randomElement()!)
        case .sleep: setMood(.sleep, autoResetAfter: nil, speech: "Zzz")
        case .drag: setMood(.drag, autoResetAfter: 2.5, speech: nil)
        }
    }

    func setMood(_ newMood: PetMood, autoResetAfter seconds: Double?, speech: String? = nil) {
        moodResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.14)) {
            mood = newMood
        }
        if let text = speech {
            say(text, duration: 2.4)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                showBubble = false
            }
        }
        if let seconds {
            moodResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if self?.isDragging == false && self?.isThinking == false {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self?.mood = .idle
                        }
                    }
                }
            }
        }
    }

    func say(_ text: String, duration: Double = 2.2) {
        bubbleText = text
        withAnimation(.easeOut(duration: 0.15)) {
            showBubble = true
        }
        scheduleBubbleDismiss(after: duration)
    }

    private func scheduleBubbleDismiss(after seconds: Double) {
        bubbleDismissTask?.cancel()
        bubbleDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.22)) {
                    self?.showBubble = false
                }
            }
        }
    }

    func openApp(named path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - Floating Pet View (Character + Hover Controls + Mini Mode)

struct PetContentView: View {
    @ObservedObject var vm: PetViewModel
    let onContextMenuRequested: (NSEvent) -> Void

    var body: some View {
        let s = vm.petSize.rawValue
        let showControls = vm.isHovering || vm.activePanel != .none || vm.voice.isRecording || vm.miniMode

        TimelineView(.animation(minimumInterval: vm.motionStyle == .still ? 0.25 : 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let anim = computeAnimation(t: t, mood: vm.mood, style: vm.motionStyle)

            VStack(spacing: 3) {
                if !vm.miniMode {
                    // Compact Status Bubble (hidden when PanelWindow is open to avoid overlap)
                    ZStack {
                        if vm.activePanel == .none && vm.showBubble, let text = vm.bubbleText {
                            Text(text)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(
                                    Capsule()
                                        .fill(Color(red: 0.10, green: 0.10, blue: 0.18).opacity(0.88))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color(red: 0.62, green: 0.58, blue: 1.0).opacity(0.45), lineWidth: 0.8)
                                        )
                                        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                                )
                                .transition(.opacity)
                        }
                    }
                    .frame(height: 24, alignment: .bottom)

                    // Pet Sprite + Status Dot
                    ZStack(alignment: .bottomTrailing) {
                        if let nsImg = vm.currentImage() {
                            Image(nsImage: nsImg)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: s, height: s)
                                .scaleEffect(x: (vm.isFacingLeft ? -1 : 1) * anim.scaleX, y: anim.scaleY)
                                .rotationEffect(.degrees(anim.rotation + vm.dragTiltDegrees))
                                .offset(x: anim.offsetX, y: anim.offsetY)
                                .shadow(color: Color.black.opacity(0.22), radius: 4, x: 0, y: 2.5)
                        }

                        // Subtle ChatGPT-style live status dot
                        if let dotColor = liveStatusDotColor() {
                            Circle()
                                .fill(dotColor)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color(red: 0.1, green: 0.1, blue: 0.18), lineWidth: 1.5))
                                .shadow(color: dotColor.opacity(0.8), radius: 4)
                                .scaleEffect(1.0 + sin(t * 5.0) * 0.15)
                                .offset(x: -8, y: -6)
                        }
                    }
                    .frame(width: s + 8, height: s + 4)
                    .contentShape(Rectangle())
                    .overlay(
                        PetMouseOverlay(
                            onSingleClick: { vm.handleSingleClick() },
                            onDoubleClick: { vm.handleDoubleClick() },
                            onDragStart: { vm.beginDrag() },
                            onDragDelta: { dx, dy in
                                vm.updateDragVelocity(dx: dx)
                                vm.onMoveWindowBy?(dx, dy)
                            },
                            onDragEnd: { vm.endDrag() },
                            onRightClick: onContextMenuRequested
                        )
                    )
                }

                // Hover Controls / Mini Mode Bar (ChatGPT Pet signature attached controls!)
                ZStack {
                    if showControls {
                        HStack(spacing: 4) {
                            if vm.miniMode {
                                // Drag grip in Mini Mode
                                Text("✦")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(red: 0.72, green: 0.76, blue: 1.0))
                                    .padding(.leading, 4)
                                    .padding(.trailing, 2)
                                    .overlay(
                                        PetMouseOverlay(
                                            onSingleClick: { vm.openPanel(.chat) },
                                            onDoubleClick: { vm.miniMode = false },
                                            onDragStart: { vm.beginDrag() },
                                            onDragDelta: { dx, dy in vm.onMoveWindowBy?(dx, dy) },
                                            onDragEnd: { vm.endDrag() },
                                            onRightClick: onContextMenuRequested
                                        )
                                    )
                            }

                            // 1. Quick Chat Input button
                            HoverIconButton(
                                systemName: "text.bubble.fill",
                                isActive: vm.activePanel == .chat,
                                tint: Color(red: 0.56, green: 0.52, blue: 1.0),
                                helpText: "快捷对话 (⌥G)"
                            ) {
                                vm.openPanel(.chat)
                            }

                            // 2. Voice Mode button
                            HoverIconButton(
                                systemName: vm.voice.isRecording ? "stop.circle.fill" : "waveform",
                                isActive: vm.activePanel == .voice || vm.voice.isRecording,
                                tint: vm.voice.isRecording ? Color(red: 1.0, green: 0.34, blue: 0.42) : Color(red: 0.42, green: 0.76, blue: 1.0),
                                helpText: vm.voice.isRecording ? "停止并发送语音" : "语音对话模式"
                            ) {
                                if vm.voice.isRecording {
                                    vm.toggleVoiceRecording()
                                } else {
                                    vm.activePanel = .voice
                                    vm.toggleVoiceRecording()
                                }
                            }

                            // 3. Screen Context button
                            HoverIconButton(
                                systemName: "viewfinder",
                                isActive: vm.attachedScreenPath != nil,
                                tint: Color(red: 0.36, green: 0.85, blue: 0.75),
                                helpText: "看屏幕提问"
                            ) {
                                vm.captureScreenContext()
                            }

                            // 4. Activity Tray bell button
                            ZStack(alignment: .topTrailing) {
                                HoverIconButton(
                                    systemName: "bell.fill",
                                    isActive: vm.activePanel == .activity,
                                    tint: Color(red: 1.0, green: 0.76, blue: 0.36),
                                    helpText: "活动与任务托盘"
                                ) {
                                    vm.openPanel(.activity)
                                }
                                if vm.unreadCount > 0 {
                                    Circle()
                                        .fill(Color(red: 1.0, green: 0.36, blue: 0.45))
                                        .frame(width: 7, height: 7)
                                        .offset(x: -1, y: 1)
                                }
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.11, green: 0.10, blue: 0.19).opacity(0.90))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color(red: 0.62, green: 0.58, blue: 1.0).opacity(0.42), lineWidth: 0.9)
                                )
                                .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
                .frame(height: 32, alignment: .top)
            }
            .padding(.horizontal, 8)
            .onHover { hovering in
                vm.setHovering(hovering)
            }
        }
    }

    private func liveStatusDotColor() -> Color? {
        if vm.voice.isRecording { return Color(red: 1.0, green: 0.32, blue: 0.40) }
        if vm.isThinking || vm.mood == .working { return Color(red: 0.45, green: 0.72, blue: 1.0) }
        if vm.unreadCount > 0 { return Color(red: 1.0, green: 0.78, blue: 0.32) }
        if vm.mood == .hiss { return Color(red: 1.0, green: 0.40, blue: 0.52) }
        return nil
    }

    private struct AnimTransform {
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: Double = 0
    }

    private func computeAnimation(t: TimeInterval, mood: PetMood, style: MotionStyle) -> AnimTransform {
        if style == .still { return AnimTransform() }
        if style == .calm {
            switch mood {
            case .idle:
                let breath = sin(t * 1.55) * 0.006
                let floatY = sin(t * 1.55) * 0.8
                return AnimTransform(offsetY: floatY, scaleX: 1 - breath * 0.3, scaleY: 1 + breath)
            case .happy:
                return AnimTransform(offsetY: -abs(sin(t * 2.8)) * 1.6, scaleX: 1.008, scaleY: 1.008)
            case .working:
                return AnimTransform(offsetY: sin(t * 1.9) * 1.2)
            case .hiss:
                return AnimTransform(offsetX: sin(t * 20.0) * 0.9)
            case .sleep:
                let b = sin(t * 0.9) * 0.008
                return AnimTransform(offsetY: 0.6, scaleX: 1 + b, scaleY: 1 - b * 0.5)
            case .drag:
                return AnimTransform(rotation: sin(t * 4.2) * 1.2)
            }
        }
        switch mood {
        case .idle:
            let b = sin(t * 2.3 - 0.5) * 0.014
            return AnimTransform(offsetY: sin(t * 2.3) * 2.2, scaleX: 1 - b * 0.5, scaleY: 1 + b)
        case .happy:
            return AnimTransform(offsetY: -abs(sin(t * 5.8)) * 6.5, scaleX: 1.018, scaleY: 1.018, rotation: sin(t * 8.5) * 2.5)
        case .working:
            return AnimTransform(offsetY: sin(t * 2.6) * 3.2 - 1.5, rotation: sin(t * 1.5) * 1.2)
        case .hiss:
            return AnimTransform(offsetX: sin(t * 30.0) * 2.2, offsetY: -abs(sin(t * 11.0)) * 2.0)
        case .sleep:
            let b = sin(t * 1.2) * 0.018
            return AnimTransform(offsetY: 1.5, scaleX: 1 + b, scaleY: 1 - b * 0.7)
        case .drag:
            return AnimTransform(offsetY: -1, rotation: sin(t * 6.0) * 2.2)
        }
    }
}

struct HoverIconButton: View {
    let systemName: String
    let isActive: Bool
    let tint: Color
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isActive ? .white : .white.opacity(0.84))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isActive ? tint.opacity(0.92) : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

// MARK: - Floating Panel View (Quick Chat / Voice Mode / Activity Tray)

struct FloatingPanelView: View {
    @ObservedObject var vm: PetViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch vm.activePanel {
            case .chat:
                chatPanel
            case .voice:
                voicePanel
            case .activity:
                activityPanel
            case .none:
                EmptyView()
            }
        }
        .frame(width: 332)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.10, green: 0.09, blue: 0.18).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.56, green: 0.66, blue: 1.0).opacity(0.55),
                                    Color(red: 0.80, green: 0.52, blue: 0.98).opacity(0.45)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.36), radius: 14, y: 6)
        )
        .padding(8)
        .onChange(of: vm.focusInputTrigger) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                isInputFocused = true
            }
        }
        .onAppear {
            if vm.activePanel == .chat {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    isInputFocused = true
                }
            }
        }
    }

    // 1. Quick Chat Panel
    private var chatPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("✦ 哈基米快捷对话")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.95))
                Spacer()
                Button {
                    vm.startNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("开启新对话")

                Button {
                    vm.closePanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Message History (compact scrollable)
            if !vm.messages.isEmpty || vm.isThinking {
                Divider().background(Color.white.opacity(0.10))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(vm.messages) { msg in
                                HStack {
                                    if msg.isUser { Spacer(minLength: 36) }
                                    VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 3) {
                                        if msg.hasImage {
                                            Text("📸 已附带屏幕截图")
                                                .font(.system(size: 10))
                                                .foregroundColor(Color(red: 0.58, green: 0.88, blue: 0.82))
                                        }
                                        Text(msg.text)
                                            .font(.system(size: 12, design: .rounded))
                                            .foregroundColor(.white.opacity(0.94))
                                            .textSelection(.enabled)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(
                                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                    .fill(msg.isUser
                                                          ? Color(red: 0.45, green: 0.42, blue: 0.90).opacity(0.85)
                                                          : Color.white.opacity(0.09))
                                            )
                                        if !msg.isUser {
                                            HStack(spacing: 8) {
                                                Button {
                                                    NSPasteboard.general.clearContents()
                                                    NSPasteboard.general.setString(msg.text, forType: .string)
                                                    vm.say("已复制 ✦", duration: 1.4)
                                                } label: {
                                                    Label("复制", systemImage: "doc.on.doc")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.white.opacity(0.58))
                                                }
                                                .buttonStyle(.plain)

                                                Button {
                                                    vm.voice.speakSystemTTS(msg.text)
                                                } label: {
                                                    Label("朗读", systemImage: "speaker.wave.2")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.white.opacity(0.58))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.leading, 4)
                                        }
                                    }
                                    if !msg.isUser { Spacer(minLength: 24) }
                                }
                                .id(msg.id)
                            }
                            if vm.isThinking {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .colorScheme(.dark)
                                    Text("哈基米思考中…")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.white.opacity(0.68))
                                }
                                .id("thinking")
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 200)
                    .onChange(of: vm.messages.count) {
                        if let last = vm.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            // Attached Screen Chip
            if vm.attachedScreenPath != nil {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(red: 0.42, green: 0.88, blue: 0.78))
                    Text("已附带当前屏幕截图")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.86))
                    Spacer()
                    Button {
                        vm.clearAttachedScreen()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0.20, green: 0.35, blue: 0.36).opacity(0.45))
                .cornerRadius(8)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            Divider().background(Color.white.opacity(0.10)).padding(.top, 6)

            // Input Row
            HStack(spacing: 6) {
                Button {
                    vm.captureScreenContext()
                } label: {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 13))
                        .foregroundColor(vm.attachedScreenPath != nil ? Color(red: 0.38, green: 0.90, blue: 0.78) : .white.opacity(0.68))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("截取当前屏幕一起问")

                TextField("问哈基米任何事… (回车发送)", text: $vm.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundColor(.white)
                    .focused($isInputFocused)
                    .onSubmit {
                        vm.sendTextPrompt()
                    }

                Button {
                    vm.activePanel = .voice
                    vm.toggleVoiceRecording()
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.52, green: 0.80, blue: 1.0))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("切到语音模式")

                Button {
                    vm.sendTextPrompt()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundColor(
                            (!vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.attachedScreenPath != nil) && !vm.isThinking
                                ? Color(red: 0.56, green: 0.54, blue: 1.0)
                                : Color.white.opacity(0.25)
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.isThinking)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }

    // 2. Voice Mode Panel
    private var voicePanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("🎙 哈基米语音模式")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.95))
                Spacer()
                Button {
                    vm.activePanel = .chat
                } label: {
                    Text("切文字")
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)

                Button {
                    vm.voice.stopPlayback()
                    vm.closePanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }

            // Voice Orb Button
            Button {
                vm.toggleVoiceRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: vm.voice.isRecording
                                    ? [Color(red: 1.0, green: 0.35, blue: 0.45), Color(red: 0.65, green: 0.16, blue: 0.34)]
                                    : (vm.isThinking
                                       ? [Color(red: 0.48, green: 0.58, blue: 1.0), Color(red: 0.30, green: 0.24, blue: 0.72)]
                                       : [Color(red: 0.46, green: 0.72, blue: 1.0), Color(red: 0.48, green: 0.34, blue: 0.88)]),
                                center: .center,
                                startRadius: 6,
                                endRadius: 36
                            )
                        )
                        .frame(width: 66, height: 66)
                        .shadow(color: (vm.voice.isRecording ? Color.red : Color.purple).opacity(0.45), radius: 10)

                    if vm.isThinking {
                        ProgressView().colorScheme(.dark)
                    } else {
                        Image(systemName: vm.voice.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.isThinking)

            VStack(spacing: 4) {
                Text(vm.voice.isRecording ? "正在聆听 \(String(format: "%d:%02d", vm.voice.recordingSeconds / 60, vm.voice.recordingSeconds % 60))" : vm.voiceStatusHint)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))

                if let lastReply = vm.messages.last(where: { !$0.isUser }) {
                    Text(lastReply.text)
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.74))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }

            HStack(spacing: 8) {
                Button {
                    vm.captureScreenContext()
                } label: {
                    Label(vm.attachedScreenPath != nil ? "已附带屏幕" : "同时看屏幕", systemImage: "viewfinder")
                        .font(.system(size: 11))
                        .foregroundColor(vm.attachedScreenPath != nil ? Color(red: 0.42, green: 0.92, blue: 0.80) : .white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)

                if vm.voice.isSpeaking {
                    Button {
                        vm.voice.stopPlayback()
                    } label: {
                        Label("停止播报", systemImage: "speaker.slash.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
    }

    // 3. Activity Tray Panel
    private var activityPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("🔔 活动与任务托盘")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.95))
                Spacer()
                Button {
                    vm.closePanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.10))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.activities) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(activityColor(item.state))
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.92))
                                    Spacer()
                                    Text(Self.timeFmt.string(from: item.time))
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.45))
                                }
                                Text(item.detail)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.68))
                                    .lineLimit(2)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 190)

            Divider().background(Color.white.opacity(0.10))

            HStack(spacing: 8) {
                Button {
                    vm.openApp(named: "/Applications/Antigravity.app")
                } label: {
                    Label("打开 Antigravity", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.42, green: 0.40, blue: 0.88).opacity(0.75)))
                }
                .buttonStyle(.plain)

                Button {
                    vm.openApp(named: "/Applications/Gemini.app")
                } label: {
                    Label("打开 Gemini", systemImage: "star.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.11)))
                }
                .buttonStyle(.plain)
            }
            .padding(10)
        }
    }

    private func activityColor(_ state: String) -> Color {
        switch state {
        case "working": return Color(red: 0.45, green: 0.72, blue: 1.0)
        case "done": return Color(red: 0.42, green: 0.88, blue: 0.65)
        case "hiss": return Color(red: 1.0, green: 0.40, blue: 0.50)
        default: return Color(red: 0.72, green: 0.60, blue: 1.0)
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Compact Native Settings Window View

struct PetSettingsView: View {
    @ObservedObject var vm: PetViewModel
    let onOpenStickers: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("✦ 哈基米桌宠设置")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Text("快捷键 ⌥G")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
            }

            Divider()

            // Size
            VStack(alignment: .leading, spacing: 6) {
                Text("尺寸大小")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.petSize) {
                    Text("80px").tag(PetSizePreset.xs)
                    Text("96px").tag(PetSizePreset.sm)
                    Text("112px").tag(PetSizePreset.gptDefault)
                    Text("136px").tag(PetSizePreset.md)
                    Text("164px").tag(PetSizePreset.lg)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Motion Style
            VStack(alignment: .leading, spacing: 6) {
                Text("动效风格")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.motionStyle) {
                    Text("克制微动").tag(MotionStyle.calm)
                    Text("完全静态").tag(MotionStyle.still)
                    Text("活泼动画").tag(MotionStyle.lively)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // AI Model
            VStack(alignment: .leading, spacing: 6) {
                Text("对话模型")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.modelPreset) {
                    Text("极速 (Flash Lite)").tag(AIModelPreset.fast)
                    Text("深度 (Gemini 4)").tag(AIModelPreset.smart)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            // Toggles
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Mini 模式（隐藏角色，仅保留快捷条）", isOn: $vm.miniMode)
                Toggle("窗口悬浮置顶", isOn: $vm.alwaysOnTop)
                Toggle("Antigravity 后台状态联动", isOn: $vm.agySyncEnabled)
                Toggle("桌面自由散步", isOn: $vm.wanderEnabled)
            }
            .font(.system(size: 12.5))

            Divider()

            HStack {
                Button("打开表情包文件夹", action: onOpenStickers)
                Spacer()
                Button("退出桌宠", role: .destructive, action: onQuit)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

// MARK: - AppKit Mouse Overlay

struct PetMouseOverlay: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    let onDragStart: () -> Void
    let onDragDelta: (CGFloat, CGFloat) -> Void
    let onDragEnd: () -> Void
    let onRightClick: (NSEvent) -> Void

    func makeNSView(context: Context) -> PetInteractionNSView {
        let v = PetInteractionNSView()
        v.onSingleClick = onSingleClick
        v.onDoubleClick = onDoubleClick
        v.onDragStart = onDragStart
        v.onDragDelta = onDragDelta
        v.onDragEnd = onDragEnd
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: PetInteractionNSView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onDragStart = onDragStart
        nsView.onDragDelta = onDragDelta
        nsView.onDragEnd = onDragEnd
        nsView.onRightClick = onRightClick
    }
}

final class PetInteractionNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragDelta: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    private var mouseDownScreenPoint: NSPoint = .zero
    private var lastScreenPoint: NSPoint = .zero
    private var hasMovedBeyondDragThreshold = false
    private var pendingSingleClick: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenPoint = NSEvent.mouseLocation
        lastScreenPoint = mouseDownScreenPoint
        hasMovedBeyondDragThreshold = false
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - lastScreenPoint.x
        let dy = current.y - lastScreenPoint.y
        lastScreenPoint = current

        let totalDist = hypot(current.x - mouseDownScreenPoint.x, current.y - mouseDownScreenPoint.y)
        if !hasMovedBeyondDragThreshold && totalDist > 4 {
            hasMovedBeyondDragThreshold = true
            pendingSingleClick?.cancel()
            onDragStart?()
        }

        if hasMovedBeyondDragThreshold {
            onDragDelta?(dx, dy)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if hasMovedBeyondDragThreshold {
            hasMovedBeyondDragThreshold = false
            onDragEnd?()
            return
        }

        if event.clickCount == 2 {
            pendingSingleClick?.cancel()
            onDoubleClick?()
        } else if event.clickCount == 1 {
            pendingSingleClick?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onSingleClick?()
            }
            pendingSingleClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.19, execute: work)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

// MARK: - Windows & Global Hotkey (Option + G)

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FloatingInputPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private var globalHotKeyCallback: (() -> Void)?

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        globalHotKeyCallback?()
    }
    return noErr
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var petWindow: PetWindow!
    private var panelWindow: FloatingInputPanel!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private let vm = PetViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupPetWindow()
        setupPanelWindow()
        setupStatusBar()
        bindCallbacks()
        registerGlobalHotKey()
    }

    private func petWindowSize() -> NSSize {
        if vm.miniMode {
            return NSSize(width: 170, height: 48)
        }
        let s = vm.petSize.rawValue
        return NSSize(width: max(148, s + 28), height: s + 66)
    }

    private func setupPetWindow() {
        let size = petWindowSize()
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.maxX - size.width - 20,
            y: screenFrame.minY + 18
        )

        petWindow = PetWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        petWindow.isOpaque = false
        petWindow.backgroundColor = .clear
        petWindow.hasShadow = false
        petWindow.hidesOnDeactivate = false
        petWindow.canHide = false
        petWindow.level = .statusBar
        petWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        petWindow.isMovableByWindowBackground = false

        let contentView = PetContentView(vm: vm) { [weak self] event in
            self?.showContextMenu(with: event)
        }
        let hosting = NSHostingView(rootView: contentView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        petWindow.contentView = hosting
        petWindow.orderFrontRegardless()
    }

    private func setupPanelWindow() {
        panelWindow = FloatingInputPanel(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panelWindow.isOpaque = false
        panelWindow.backgroundColor = .clear
        panelWindow.hasShadow = false
        panelWindow.canHide = false
        panelWindow.level = .statusBar
        panelWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panelWindow.hidesOnDeactivate = false
        panelWindow.onEscape = { [weak self] in
            self?.vm.closePanel()
        }

        let panelView = FloatingPanelView(vm: vm)
        let hosting = NSHostingView(rootView: panelView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panelWindow.contentView = hosting
    }

    private func positionPanelWindow() {
        guard let hosting = panelWindow.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let w = max(348, fitting.width)
        let h = max(120, min(390, fitting.height))

        let petFrame = petWindow.frame
        let screen = petWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var px = petFrame.midX - w / 2
        px = max(screen.minX + 12, min(screen.maxX - w - 12, px))

        // Prefer directly above the pet; if near top edge, place below
        var py = petFrame.maxY + 4
        if py + h > screen.maxY - 12 {
            py = max(screen.minY + 12, petFrame.minY - h - 4)
        }

        panelWindow.setFrame(NSRect(x: px, y: py, width: w, height: h), display: true)
    }

    private func bindCallbacks() {
        vm.onSizeChanged = { [weak self] in
            guard let self else { return }
            let oldFrame = self.petWindow.frame
            let newSize = self.petWindowSize()
            let newOrigin = NSPoint(
                x: oldFrame.midX - newSize.width / 2,
                y: oldFrame.minY
            )
            self.petWindow.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: true)
            if self.vm.activePanel != .none {
                self.positionPanelWindow()
            }
        }

        vm.onAlwaysOnTopChanged = { [weak self] onTop in
            let lvl: NSWindow.Level = onTop ? .statusBar : .normal
            self?.petWindow.level = lvl
            self?.panelWindow.level = lvl
        }

        vm.onMoveWindowBy = { [weak self] dx, dy in
            guard let self else { return }
            var origin = self.petWindow.frame.origin
            origin.x += dx
            origin.y += dy
            self.petWindow.setFrameOrigin(origin)
            if self.vm.activePanel != .none {
                self.positionPanelWindow()
            }
        }

        vm.onGetWindowFrame = { [weak self] in
            self?.petWindow.frame ?? .zero
        }

        vm.onPanelModeChanged = { [weak self] mode in
            guard let self else { return }
            if mode == .none {
                self.panelWindow.orderOut(nil)
            } else {
                // Re-layout twice (immediately + next runloop) so dynamic content height snaps cleanly
                self.positionPanelWindow()
                NSApp.activate(ignoringOtherApps: true)
                self.panelWindow.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.positionPanelWindow()
                }
            }
            self.refreshMenuBar()
        }

        // Also keep panel height updated when chat messages arrive
        vm.$messages.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.vm.activePanel != .none else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.positionPanelWindow()
            }
        }.store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    private func registerGlobalHotKey() {
        // Option + G (keyCode 5 = 'G') — avoids conflicting with Spotlight / ChatGPT Option+Space
        globalHotKeyCallback = { [weak self] in
            guard let self else { return }
            if !self.vm.isVisible {
                self.vm.isVisible = true
                self.petWindow.orderFrontRegardless()
            }
            if self.vm.activePanel == .chat {
                self.vm.closePanel()
            } else {
                self.vm.openPanel(.chat)
            }
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x47504554), id: 1) // 'GPET'
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "✦"
            button.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            button.toolTip = "Gemini 哈基米桌宠 (⌥G 快捷对话)"
        }
        statusItem.menu = buildStatusBarMenu()
    }

    /// Ultra-clean 2-item right-click menu on the pet (just like ChatGPT Desktop Pet)
    private func buildPetContextMenu() -> NSMenu {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsWindow), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let hideItem = NSMenuItem(title: "隐藏桌宠", action: #selector(toggleVisibility), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        return menu
    }

    /// Clean compact menu for the top macOS Menu Bar icon
    private func buildStatusBarMenu() -> NSMenu {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: vm.isVisible ? "隐藏哈基米" : "显示哈基米",
            action: #selector(toggleVisibility),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let chatItem = NSMenuItem(title: "快捷对话 (⌥G)", action: #selector(openChatAction), keyEquivalent: "")
        chatItem.target = self
        menu.addItem(chatItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func showContextMenu(with event: NSEvent) {
        let menu = buildPetContextMenu()
        if let contentView = petWindow.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        }
    }

    private func refreshMenuBar() {
        statusItem.menu = buildStatusBarMenu()
    }

    @objc private func openSettingsWindow() {
        if let win = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let view = PetSettingsView(
            vm: vm,
            onOpenStickers: { [weak self] in self?.openStickersFolder() },
            onQuit: { [weak self] in self?.quitApp() }
        )
        let hosting = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "哈基米桌宠设置"
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.center()
        self.settingsWindow = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func openChatAction() {
        if !vm.isVisible { toggleVisibility() }
        vm.openPanel(.chat)
    }

    @objc private func toggleVisibility() {
        vm.isVisible.toggle()
        if vm.isVisible {
            petWindow.orderFrontRegardless()
        } else {
            vm.closePanel()
            petWindow.orderOut(nil)
        }
        refreshMenuBar()
    }

    @objc private func openStickersFolder() {
        if let resStickers = Bundle.main.resourceURL?.appendingPathComponent("stickers"),
           FileManager.default.fileExists(atPath: resStickers.path) {
            NSWorkspace.shared.open(resStickers)
            return
        }
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let stickersDir = appDir.appendingPathComponent("stickers")
        if FileManager.default.fileExists(atPath: stickersDir.path) {
            NSWorkspace.shared.open(stickersDir)
        } else if let resSprites = Bundle.main.resourceURL?.appendingPathComponent("sprites") {
            NSWorkspace.shared.open(resSprites)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

@main
struct GeminiPetLauncher {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
