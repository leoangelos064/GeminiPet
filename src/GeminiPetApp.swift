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
        case .xs: return "80px"
        case .sm: return "96px"
        case .gptDefault: return "112px"
        case .md: return "136px"
        case .lg: return "164px"
        }
    }
}

enum MotionStyle: String, CaseIterable {
    case calm
    case still
    case lively

    var title: String {
        switch self {
        case .calm: return "克制微动"
        case .still: return "完全静态"
        case .lively: return "活泼动画"
        }
    }
}

enum AIModelPreset: String, CaseIterable {
    case fast = "gemini-3.5-flash-lite"
    case smart = "gemini-4-hydrogen"

    var title: String {
        switch self {
        case .fast: return "极速 (Flash Lite)"
        case .smart: return "深度 (Gemini 4)"
        }
    }
}

enum ActivePanelMode: Equatable {
    case none
    case workspace
    case voice
}

struct ChatEntry: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
    let hasImage: Bool
    let isVoice: Bool
    let time: Date
}

enum TaskStateKind: String {
    case running
    case done
    case error
    case idle
}

struct TaskStepItem: Identifiable, Decodable {
    var id: String { "\(time)-\(text)" }
    let text: String
    let time: Double
}

struct AgyTaskRecord: Decodable {
    let id: String
    let source: String?
    let title: String
    let workspace: String
    let workspacePath: String?
    let state: String
    let currentAction: String
    let lastReply: String?
    let startedAt: Double
    let updatedAt: Double
    let steps: [TaskStepItem]?
}

struct AgyTasksFile: Decodable {
    let updatedAt: Double?
    let tasks: [AgyTaskRecord]
}

struct PetTaskThread: Identifiable {
    let id: String
    let isAntigravity: Bool
    var title: String
    var workspace: String
    var state: TaskStateKind
    var currentAction: String
    var startedAt: Date
    var updatedAt: Date
    var steps: [TaskStepItem]
    var agyLastReply: String
    var interactionId: String
    var messages: [ChatEntry]
    var unread: Bool
}

struct BridgeResponse: Decodable {
    let ok: Bool
    let text: String?
    let interaction_id: String?
    let audio_path: String?
    let error: String?
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
                // Fall back to system speech
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

// MARK: - LaunchAtLogin Helper (LaunchAgent)

enum LaunchAgentHelper {
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.antigravity.geminipet.plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            let appExec = Bundle.main.executablePath ?? "/Applications/GeminiPet.app/Contents/MacOS/GeminiPet"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.antigravity.geminipet</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appExec)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}

// MARK: - Pet ViewModel

@MainActor
final class PetViewModel: ObservableObject {
    @Published var mood: PetMood = .idle
    @Published var isHovering: Bool = false
    @Published var hoverLeanDegrees: Double = 0
    @Published var hoverPopScale: CGFloat = 1.0
    @Published var activePanel: ActivePanelMode = .none {
        didSet { onPanelModeChanged?(activePanel) }
    }
    @Published var miniMode: Bool = false {
        didSet { onSizeChanged?() }
    }
    @Published var isFacingLeft: Bool = false
    @Published var dragTiltDegrees: Double = 0
    @Published var petSize: PetSizePreset = {
        let saved = UserDefaults.standard.double(forKey: "petSize")
        return PetSizePreset(rawValue: CGFloat(saved)) ?? .md
    }() {
        didSet {
            UserDefaults.standard.set(Double(petSize.rawValue), forKey: "petSize")
            onSizeChanged?()
        }
    }
    @Published var motionStyle: MotionStyle = {
        if let raw = UserDefaults.standard.string(forKey: "motionStyle"),
           let saved = MotionStyle(rawValue: raw) {
            return saved
        }
        return .lively
    }() {
        didSet {
            UserDefaults.standard.set(motionStyle.rawValue, forKey: "motionStyle")
        }
    }
    @Published var modelPreset: AIModelPreset = .fast
    @Published var alwaysOnTop: Bool = true {
        didSet { onAlwaysOnTopChanged?(alwaysOnTop) }
    }
    @Published var wanderEnabled: Bool = false
    @Published var agySyncEnabled: Bool = true
    @Published var quitWithAntigravity: Bool = UserDefaults.standard.object(forKey: "quitWithAntigravity") as? Bool ?? true {
        didSet { UserDefaults.standard.set(quitWithAntigravity, forKey: "quitWithAntigravity") }
    }
    @Published var showTaskBanner: Bool = true
    @Published var launchAtLogin: Bool = LaunchAgentHelper.isEnabled {
        didSet { LaunchAgentHelper.setEnabled(launchAtLogin) }
    }
    @Published var isVisible: Bool = true

    // Unified Task Group
    @Published var tasks: [PetTaskThread] = []
    @Published var selectedTaskId: String = ""
    @Published var inputText: String = ""
    @Published var attachedScreenPath: String? = nil
    @Published var voiceStatusHint: String = "点击麦克风开始说话"
    @Published var quickToast: String? = nil
    @Published var bannerDismissedByUser: Bool = false
    @Published var focusInputTrigger: UUID = UUID()
    @Published var nowTick: Date = Date()

    let voice = VoiceController()

    var sprites: [PetMood: NSImage] = [:]
    var onSizeChanged: (() -> Void)?
    var onAlwaysOnTopChanged: ((Bool) -> Void)?
    var onMoveWindowBy: ((CGFloat, CGFloat) -> Void)?
    var onGetWindowFrame: (() -> NSRect)?
    var onPanelModeChanged: ((ActivePanelMode) -> Void)?

    private var lastInteractionDate = Date()
    private var lastHoverGreetDate: Date = .distantPast
    private var recentPokeTimestamps: [Date] = []
    private var toastDismissTask: Task<Void, Never>?
    private var doneAutoHideTask: Task<Void, Never>?
    private var hoverHideTask: Task<Void, Never>?
    private var moodResetTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var wanderDirection: CGFloat = -1
    private var wanderPauseUntil: Date = .distantPast
    private var lastTasksFileUpdatedAt: Double = 0
    private var isDragging = false
    private var voiceCancellable: AnyCancellable?

    private let happyLines = ["呼噜~ ✦", "摸摸头 💗", "在呢喵~"]
    private let hissLines = ["哈——！💢", "别一直戳啦！", "炸毛了喵 💢"]
    private let hoverGreetLines = [
        "嗨~ 找哈基米吗？✦",
        "在呢喵~ 要聊点什么？",
        "哈基米随时待命 ✦",
        "点一下可以摸摸头哦~"
    ]

    init() {
        loadSprites()
        let defaultId = "pet-main"
        tasks = [
            PetTaskThread(
                id: defaultId,
                isAntigravity: false,
                title: "快捷对话",
                workspace: "哈基米",
                state: .idle,
                currentAction: "",
                startedAt: Date(),
                updatedAt: Date(),
                steps: [],
                agyLastReply: "",
                interactionId: "",
                messages: [],
                unread: false
            )
        ]
        selectedTaskId = defaultId
        pollAgyTasks(initialLoad: true)
        startTimers()
        voiceCancellable = voice.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var runningTasksCount: Int {
        tasks.filter { $0.state == .running }.count
    }

    var unreadCount: Int {
        tasks.filter { $0.unread }.count
    }

    /// Active task to show in the compact top strip (ONLY while running or freshly completed/unread!)
    var activeBannerTask: PetTaskThread? {
        guard showTaskBanner && !bannerDismissedByUser else { return nil }
        if let running = tasks.first(where: { $0.state == .running }) {
            return running
        }
        if let unreadTask = tasks.first(where: { $0.unread }) {
            return unreadTask
        }
        return nil
    }

    var selectedTask: PetTaskThread? {
        tasks.first(where: { $0.id == selectedTaskId }) ?? tasks.first
    }

    var isAnyTaskThinking: Bool {
        runningTasksCount > 0
    }

    func dismissTopBanner() {
        bannerDismissedByUser = true
        for idx in tasks.indices where tasks[idx].unread {
            tasks[idx].unread = false
        }
        quickToast = nil
    }

    private func scheduleDoneBannerAutoHide() {
        doneAutoHideTask?.cancel()
        doneAutoHideTask = Task { [weak self] in
            // After a task finishes, keep the subtle "已完成" pill for 12s (or until user clicks / closes), then vanish cleanly!
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.runningTasksCount == 0 else { return }
                for idx in self.tasks.indices where self.tasks[idx].unread {
                    self.tasks[idx].unread = false
                }
            }
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
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onTick()
            }
        }
    }

    private var tickCount = 0
    private func onTick() {
        tickCount += 1
        let now = Date()

        if tickCount % 10 == 0 && runningTasksCount > 0 {
            nowTick = now
        }

        if !isDragging && abs(dragTiltDegrees) > 0.1 {
            dragTiltDegrees *= 0.78
            if abs(dragTiltDegrees) < 0.15 { dragTiltDegrees = 0 }
        }

        if !isDragging && !isAnyTaskThinking && !voice.isRecording && activePanel == .none
            && mood == .idle && now.timeIntervalSince(lastInteractionDate) > 180 {
            setMood(.sleep, autoResetAfter: nil)
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

        if agySyncEnabled && tickCount % 4 == 0 {
            pollAgyTasks(initialLoad: false)
        }
    }

    private func pollAgyTasks(initialLoad: Bool) {
        let tasksURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/gemini_pet_tasks.json")
        guard let data = try? Data(contentsOf: tasksURL),
              let file = try? JSONDecoder().decode(AgyTasksFile.self, from: data) else {
            return
        }
        let ts = file.updatedAt ?? 0
        if !initialLoad && ts <= lastTasksFileUpdatedAt { return }
        lastTasksFileUpdatedAt = ts

        var sawNewlyRunning = false
        var sawNewlyDone = false
        var sawNewlyError = false

        for rec in file.tasks {
            let kind: TaskStateKind = {
                switch rec.state {
                case "running": return .running
                case "error": return .error
                case "done": return .done
                default: return .idle
                }
            }()

            if let idx = tasks.firstIndex(where: { $0.id == rec.id }) {
                let prevState = tasks[idx].state
                tasks[idx].title = rec.title
                tasks[idx].workspace = rec.workspace
                tasks[idx].state = kind
                tasks[idx].currentAction = rec.currentAction
                tasks[idx].startedAt = Date(timeIntervalSince1970: rec.startedAt)
                tasks[idx].updatedAt = Date(timeIntervalSince1970: rec.updatedAt)
                tasks[idx].steps = rec.steps ?? []
                if let rep = rec.lastReply, !rep.isEmpty {
                    tasks[idx].agyLastReply = rep
                }
                if !initialLoad {
                    if kind == .running { sawNewlyRunning = true }
                    if prevState == .running && kind == .done {
                        sawNewlyDone = true
                        if activePanel != .workspace || selectedTaskId != rec.id {
                            tasks[idx].unread = true
                        }
                    }
                    if prevState != .error && kind == .error {
                        sawNewlyError = true
                        tasks[idx].unread = true
                    }
                }
            } else {
                let thread = PetTaskThread(
                    id: rec.id,
                    isAntigravity: true,
                    title: rec.title,
                    workspace: rec.workspace,
                    state: kind,
                    currentAction: rec.currentAction,
                    startedAt: Date(timeIntervalSince1970: rec.startedAt),
                    updatedAt: Date(timeIntervalSince1970: rec.updatedAt),
                    steps: rec.steps ?? [],
                    agyLastReply: rec.lastReply ?? "",
                    interactionId: "",
                    messages: [],
                    unread: !initialLoad && kind == .done
                )
                tasks.insert(thread, at: 0)
                if !initialLoad {
                    if kind == .running { sawNewlyRunning = true }
                    if kind == .done { sawNewlyDone = true }
                    if kind == .error { sawNewlyError = true }
                }
            }
        }

        tasks.sort { lhs, rhs in
            if (lhs.state == .running) != (rhs.state == .running) {
                return lhs.state == .running
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        if !initialLoad {
            lastInteractionDate = Date()
            if sawNewlyRunning {
                bannerDismissedByUser = false
                doneAutoHideTask?.cancel()
                setMood(.working, autoResetAfter: nil)
            } else if sawNewlyError {
                bannerDismissedByUser = false
                scheduleDoneBannerAutoHide()
                setMood(.hiss, autoResetAfter: 4.0)
            } else if sawNewlyDone {
                bannerDismissedByUser = false
                scheduleDoneBannerAutoHide()
                setMood(.happy, autoResetAfter: 3.5)
            } else if runningTasksCount == 0 && mood == .working {
                setMood(.idle, autoResetAfter: nil)
            }
        }
    }

    // MARK: - Task Group Operations

    func selectTask(_ id: String) {
        selectedTaskId = id
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].unread = false
        }
        focusInputTrigger = UUID()
    }

    func createNewPetTask() {
        let newId = "pet-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
        let count = tasks.filter { !$0.isAntigravity }.count + 1
        let thread = PetTaskThread(
            id: newId,
            isAntigravity: false,
            title: "新对话 #\(count)",
            workspace: "哈基米",
            state: .idle,
            currentAction: "",
            startedAt: Date(),
            updatedAt: Date(),
            steps: [],
            agyLastReply: "",
            interactionId: "",
            messages: [],
            unread: false
        )
        tasks.insert(thread, at: 0)
        selectedTaskId = newId
        attachedScreenPath = nil
        focusInputTrigger = UUID()
    }

    func openWorkspacePanel(focusTaskId: String? = nil) {
        lastInteractionDate = Date()
        if let tid = focusTaskId {
            selectTask(tid)
        } else if let bt = activeBannerTask {
            selectTask(bt.id)
        }
        if activePanel == .workspace && focusTaskId == nil {
            closePanel()
            return
        }
        if voice.isRecording {
            voice.cancelRecording()
        }
        activePanel = .workspace
        focusInputTrigger = UUID()
    }

    func openVoicePanelAndRecord() {
        lastInteractionDate = Date()
        activePanel = .voice
        if !voice.isRecording {
            toggleVoiceRecording()
        }
    }

    func closePanel() {
        if voice.isRecording {
            voice.cancelRecording()
        }
        activePanel = .none
    }

    func setHovering(_ hovering: Bool) {
        hoverHideTask?.cancel()
        if hovering {
            let wasHovering = isHovering
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) {
                isHovering = true
                hoverPopScale = 1.055
            }
            if !wasHovering {
                lastInteractionDate = Date()
                // Wake up gently if sleeping, or greet cheerfully if idle!
                if mood == .sleep {
                    setMood(.happy, autoResetAfter: 2.0)
                    showToast("唔嗯…你来啦 ✦", duration: 2.2)
                    lastHoverGreetDate = Date()
                } else if mood == .idle && activePanel == .none && runningTasksCount == 0 {
                    let now = Date()
                    if now.timeIntervalSince(lastHoverGreetDate) > 8.0 {
                        lastHoverGreetDate = now
                        setMood(.happy, autoResetAfter: 1.8)
                        showToast(timeAwareGreeting(), duration: 2.2)
                    }
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.22)) {
                hoverLeanDegrees = 0
                hoverPopScale = 1.0
            }
            hoverHideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 550_000_000)
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

    func updateHoverPointer(normalizedX: CGFloat) {
        // normalizedX in [-1, 1]: gently lean head toward user's cursor!
        let clamped = max(-1.0, min(1.0, Double(normalizedX)))
        withAnimation(.easeOut(duration: 0.12)) {
            hoverLeanDegrees = clamped * 4.5
        }
    }

    private func timeAwareGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if Bool.random() {
            switch hour {
            case 5..<11: return "早安呀~ ✦"
            case 11..<14: return "中午好喵~ ✦"
            case 14..<18: return "下午好，需要帮忙吗？✦"
            case 18..<23: return "晚上好喵~ ✦"
            default: return "这么晚还在忙呀，注意休息 ✦"
            }
        }
        return hoverGreetLines.randomElement()!
    }

    // MARK: - Inline Send / Modify

    func sendTextPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgPath = attachedScreenPath
        guard !text.isEmpty || imgPath != nil else { return }

        guard let taskIdx = tasks.firstIndex(where: { $0.id == selectedTaskId }) ?? (tasks.isEmpty ? nil : 0) else {
            return
        }
        guard tasks[taskIdx].state != .running || tasks[taskIdx].isAntigravity else { return }

        let taskId = tasks[taskIdx].id
        let displayPrompt = text.isEmpty ? "看看我当前屏幕里的内容" : text

        if !tasks[taskIdx].isAntigravity && tasks[taskIdx].messages.isEmpty {
            let short = displayPrompt.count > 16 ? String(displayPrompt.prefix(16)) + "…" : displayPrompt
            tasks[taskIdx].title = short
        }

        tasks[taskIdx].messages.append(ChatEntry(isUser: true, text: displayPrompt, hasImage: imgPath != nil, isVoice: false, time: Date()))
        inputText = ""
        attachedScreenPath = nil

        var effectivePrompt = text
        if tasks[taskIdx].isAntigravity && tasks[taskIdx].interactionId.isEmpty {
            let ctxSummary = tasks[taskIdx].agyLastReply.isEmpty
                ? tasks[taskIdx].currentAction
                : String(tasks[taskIdx].agyLastReply.prefix(320))
            effectivePrompt = "【工作区：\(tasks[taskIdx].workspace)｜任务：\(tasks[taskIdx].title)｜最新进展：\(ctxSummary)】\n用户修改/追问：\(displayPrompt)"
        }

        callBridge(forTaskId: taskId, prompt: effectivePrompt, audioPath: nil, imagePath: imgPath, speak: false)
    }

    func toggleVoiceRecording() {
        lastInteractionDate = Date()
        if voice.isRecording {
            guard let audioURL = voice.stopRecording() else { return }
            let imgPath = attachedScreenPath
            attachedScreenPath = nil
            voiceStatusHint = "正在听懂并思考回复…"
            let targetId = selectedTask?.id ?? tasks.first?.id ?? "pet-main"
            if let idx = tasks.firstIndex(where: { $0.id == targetId }) {
                tasks[idx].messages.append(ChatEntry(isUser: true, text: "🎙 语音消息（\(max(1, voice.recordingSeconds))s）", hasImage: imgPath != nil, isVoice: true, time: Date()))
            }
            callBridge(forTaskId: targetId, prompt: "", audioPath: audioURL.path, imagePath: imgPath, speak: true)
        } else {
            if activePanel != .voice {
                activePanel = .voice
            }
            voice.startRecording { [weak self] ok, err in
                guard let self else { return }
                if ok {
                    self.voiceStatusHint = "正在聆听… 说完点停止"
                    self.showToast("聆听中… 🎙")
                } else {
                    self.voiceStatusHint = err ?? "无法开启麦克风"
                    self.showToast(err ?? "麦克风权限未开")
                }
            }
        }
    }

    private func callBridge(forTaskId taskId: String, prompt: String, audioPath: String?, imagePath: String?, speak: Bool) {
        bannerDismissedByUser = false
        doneAutoHideTask?.cancel()

        let prevId: String
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            prevId = tasks[idx].interactionId
            tasks[idx].state = .running
            tasks[idx].startedAt = Date()
            tasks[idx].updatedAt = Date()
            tasks[idx].currentAction = speak ? "思考语音回复…" : "思考中…"
        } else {
            prevId = ""
        }

        setMood(.working, autoResetAfter: nil)
        let script = bridgeScriptPath()
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
            if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
                self.tasks[idx].updatedAt = Date()
                if parsed.ok, let reply = parsed.text, !reply.isEmpty {
                    if let nid = parsed.interaction_id, !nid.isEmpty {
                        self.tasks[idx].interactionId = nid
                    }
                    self.tasks[idx].messages.append(ChatEntry(isUser: false, text: reply, hasImage: false, isVoice: speak, time: Date()))
                    self.tasks[idx].state = .done
                    self.tasks[idx].currentAction = "已完成"
                    if self.activePanel == .none || self.selectedTaskId != taskId {
                        self.tasks[idx].unread = true
                        self.scheduleDoneBannerAutoHide()
                    }
                    self.setMood(.happy, autoResetAfter: 3.0)
                    if speak {
                        self.voiceStatusHint = "正在播报回复"
                        self.voice.playAudioOrSpeak(audioPath: parsed.audio_path, fallbackText: reply)
                    }
                } else {
                    let err = parsed.error ?? "未知错误"
                    self.tasks[idx].messages.append(ChatEntry(isUser: false, text: "出错啦：\(err)", hasImage: false, isVoice: false, time: Date()))
                    self.tasks[idx].state = .error
                    self.tasks[idx].currentAction = "出错"
                    self.voiceStatusHint = "出错：\(err)"
                    self.setMood(.hiss, autoResetAfter: 3.5)
                }
            }
        }
    }

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
                showToast("已截取屏幕 📸")
                if activePanel == .none {
                    activePanel = .workspace
                    focusInputTrigger = UUID()
                }
            } else {
                showToast("截屏失败，请检查录屏权限")
            }
        } catch {
            showToast("截屏失败")
        }
    }

    func clearAttachedScreen() {
        if let p = attachedScreenPath {
            try? FileManager.default.removeItem(atPath: p)
        }
        attachedScreenPath = nil
    }

    // MARK: - Click / Drag / Mood

    func selectManualMood(_ newMood: PetMood) {
        lastInteractionDate = Date()
        switch newMood {
        case .idle: setMood(.idle, autoResetAfter: nil)
        case .happy: setMood(.happy, autoResetAfter: 3.0)
        case .working: setMood(.working, autoResetAfter: nil)
        case .hiss: setMood(.hiss, autoResetAfter: 3.0)
        case .sleep: setMood(.sleep, autoResetAfter: nil)
        case .drag: setMood(.drag, autoResetAfter: 2.5)
        }
    }

    func handleSingleClick() {
        lastInteractionDate = Date()
        let now = Date()
        recentPokeTimestamps = recentPokeTimestamps.filter { now.timeIntervalSince($0) < 3.0 }
        recentPokeTimestamps.append(now)

        if recentPokeTimestamps.count >= 5 {
            recentPokeTimestamps.removeAll()
            setMood(.hiss, autoResetAfter: 2.8)
            showToast(hissLines.randomElement()!)
            return
        }

        if mood == .sleep {
            setMood(.idle, autoResetAfter: nil)
            showToast("醒啦 ✦")
            return
        }

        if runningTasksCount > 0 || unreadCount > 0 {
            openWorkspacePanel()
            return
        }

        setMood(.happy, autoResetAfter: 2.2)
        showToast(happyLines.randomElement()!)
    }

    func handleDoubleClick() {
        openWorkspacePanel()
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
        mood = runningTasksCount > 0 ? .working : .idle
    }

    func setMood(_ newMood: PetMood, autoResetAfter seconds: Double?) {
        moodResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.14)) {
            mood = newMood
        }
        if let seconds {
            moodResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if let self, !self.isDragging {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.mood = self.runningTasksCount > 0 ? .working : .idle
                        }
                    }
                }
            }
        }
    }

    func showToast(_ text: String, duration: Double = 2.0) {
        quickToast = text
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.quickToast = nil
                }
            }
        }
    }

    func elapsedString(since start: Date) -> String {
        let secs = max(0, Int(nowTick.timeIntervalSince(start)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    func openApp(named path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - Floating Pet View (Clean Single-Line Active Task Pill + Pet + Hover Controls)

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
                // 1. ULTRA-CLEAN SINGLE-LINE TASK PILL (Only shown when running / just finished / toast, with ✕ close!)
                ZStack {
                    if vm.activePanel == .none, let bt = vm.activeBannerTask {
                        HStack(spacing: 5) {
                            Button {
                                vm.openWorkspacePanel(focusTaskId: bt.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(taskDotColor(bt.state))
                                        .frame(width: 6, height: 6)
                                        .scaleEffect(bt.state == .running ? (1.0 + sin(t * 5.5) * 0.2) : 1.0)

                                    Text(bt.state == .running
                                         ? "\(bt.workspace) · \(bt.currentAction)"
                                         : "已完成 · \(bt.title)")
                                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                        .foregroundColor(.white.opacity(0.94))
                                        .lineLimit(1)

                                    if bt.state == .running {
                                        Text(vm.elapsedString(since: bt.startedAt))
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(Color(red: 0.62, green: 0.84, blue: 1.0))
                                    }

                                    if vm.runningTasksCount > 1 {
                                        Text("+\(vm.runningTasksCount - 1)")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.85))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.white.opacity(0.14)))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help("点击查看或直接修改")

                            Button {
                                vm.dismissTopBanner()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundColor(.white.opacity(0.55))
                                    .frame(width: 15, height: 15)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("关闭任务提示")
                        }
                        .padding(.leading, 9)
                        .padding(.trailing, 6)
                        .padding(.vertical, 5)
                        .frame(maxWidth: 204)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.10, green: 0.09, blue: 0.18).opacity(0.90))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            bt.state == .running
                                                ? Color(red: 0.48, green: 0.74, blue: 1.0).opacity(0.6)
                                                : Color(red: 0.45, green: 0.88, blue: 0.66).opacity(0.5),
                                            lineWidth: 0.85
                                        )
                                )
                                .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    } else if vm.activePanel == .none, let toast = vm.quickToast {
                        Text(toast)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.94))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.10, green: 0.09, blue: 0.18).opacity(0.88))
                                    .overlay(Capsule().strokeBorder(Color(red: 0.62, green: 0.58, blue: 1.0).opacity(0.4), lineWidth: 0.8))
                                    .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                            )
                            .transition(.opacity)
                    }
                }
                .frame(height: 28, alignment: .bottom)

                // 2. PET SPRITE
                if !vm.miniMode {
                    ZStack(alignment: .bottomTrailing) {
                        if let nsImg = vm.currentImage() {
                            Image(nsImage: nsImg)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: s, height: s)
                                .scaleEffect(
                                    x: (vm.isFacingLeft ? -1 : 1) * anim.scaleX * vm.hoverPopScale,
                                    y: anim.scaleY * vm.hoverPopScale
                                )
                                .rotationEffect(.degrees(anim.rotation + vm.dragTiltDegrees + vm.hoverLeanDegrees))
                                .offset(x: anim.offsetX, y: anim.offsetY - (vm.isHovering ? 2.5 : 0))
                                .shadow(
                                    color: vm.isHovering
                                        ? Color(red: 0.62, green: 0.56, blue: 1.0).opacity(0.45)
                                        : Color.black.opacity(0.22),
                                    radius: vm.isHovering ? 8 : 4,
                                    x: 0,
                                    y: vm.isHovering ? 3 : 2.5
                                )
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
                            onRightClick: onContextMenuRequested,
                            onHoverChange: { hovering in vm.setHovering(hovering) },
                            onHoverMove: { nx in vm.updateHoverPointer(normalizedX: nx) }
                        )
                    )
                }

                // 3. CLEAN HOVER CONTROLS (or Mini Mode bar)
                ZStack {
                    if showControls {
                        HStack(spacing: 4) {
                            if vm.miniMode {
                                Text("✦")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(red: 0.72, green: 0.76, blue: 1.0))
                                    .padding(.leading, 4)
                                    .padding(.trailing, 2)
                                    .overlay(
                                        PetMouseOverlay(
                                            onSingleClick: { vm.openWorkspacePanel() },
                                            onDoubleClick: { vm.miniMode = false },
                                            onDragStart: { vm.beginDrag() },
                                            onDragDelta: { dx, dy in vm.onMoveWindowBy?(dx, dy) },
                                            onDragEnd: { vm.endDrag() },
                                            onRightClick: onContextMenuRequested
                                        )
                                    )
                            }

                            HoverIconButton(
                                systemName: "text.bubble.fill",
                                isActive: vm.activePanel == .workspace,
                                tint: Color(red: 0.56, green: 0.52, blue: 1.0),
                                helpText: "快捷对话与任务 (⌥G)"
                            ) {
                                vm.openWorkspacePanel()
                            }

                            HoverIconButton(
                                systemName: vm.voice.isRecording ? "stop.circle.fill" : "waveform",
                                isActive: vm.activePanel == .voice || vm.voice.isRecording,
                                tint: vm.voice.isRecording ? Color(red: 1.0, green: 0.34, blue: 0.42) : Color(red: 0.42, green: 0.76, blue: 1.0),
                                helpText: vm.voice.isRecording ? "停止并发送语音" : "语音对话"
                            ) {
                                if vm.voice.isRecording {
                                    vm.toggleVoiceRecording()
                                } else {
                                    vm.openVoicePanelAndRecord()
                                }
                            }

                            HoverIconButton(
                                systemName: "viewfinder",
                                isActive: vm.attachedScreenPath != nil,
                                tint: Color(red: 0.36, green: 0.85, blue: 0.75),
                                helpText: "看屏幕提问"
                            ) {
                                vm.captureScreenContext()
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
                                .shadow(color: .black.opacity(0.26), radius: 6, y: 2)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
                .frame(height: 32, alignment: .top)
            }
            .padding(.horizontal, 6)
            .onHover { hovering in
                vm.setHovering(hovering)
            }
        }
    }

    private func taskDotColor(_ state: TaskStateKind) -> Color {
        switch state {
        case .running: return Color(red: 0.38, green: 0.78, blue: 1.0)
        case .done: return Color(red: 0.42, green: 0.88, blue: 0.64)
        case .error: return Color(red: 1.0, green: 0.38, blue: 0.48)
        case .idle: return Color(red: 0.66, green: 0.62, blue: 1.0)
        }
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
                return AnimTransform(offsetY: sin(t * 1.55) * 0.8, scaleX: 1 - breath * 0.3, scaleY: 1 + breath)
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

// MARK: - Clean Minimalist Floating Chat & Task Panel (ChatGPT Pet Style)

struct FloatingPanelView: View {
    @ObservedObject var vm: PetViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch vm.activePanel {
            case .workspace:
                compactChatTaskPanel
            case .voice:
                voicePanel
            case .none:
                EmptyView()
            }
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.16).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color(red: 0.58, green: 0.62, blue: 1.0).opacity(0.42), lineWidth: 0.9)
                )
                .shadow(color: .black.opacity(0.36), radius: 14, y: 5)
        )
        .padding(8)
        .onChange(of: vm.focusInputTrigger) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                isInputFocused = true
            }
        }
        .onAppear {
            if vm.activePanel == .workspace {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    isInputFocused = true
                }
            }
        }
    }

    // Ultra-clean 3-part card: 1-line Task Switcher Header + Messages + 1-line Input
    private var compactChatTaskPanel: some View {
        let task = vm.selectedTask

        return VStack(spacing: 0) {
            // 1. Clean Single-Row Header with Dropdown Task Group Switcher
            HStack(spacing: 6) {
                Menu {
                    ForEach(vm.tasks) { t in
                        Button {
                            vm.selectTask(t.id)
                        } label: {
                            let mark = (t.state == .running) ? "● " : (t.unread ? "★ " : "")
                            Text("\(mark)\(t.workspace) · \(t.title)")
                        }
                    }
                    Divider()
                    Button("+ 新建对话") {
                        vm.createNewPetTask()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor(task?.state ?? .idle))
                            .frame(width: 6.5, height: 6.5)
                        Text(task.map { "\($0.workspace) · \($0.title)" } ?? "哈基米")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.94))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                if task?.isAntigravity == true {
                    Button {
                        vm.openApp(named: "/Applications/Antigravity.app")
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.62))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("在 Antigravity 中打开")
                }

                Button {
                    vm.closePanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // 2. Clean Conversation / Live Status Body (only shown when there is content or running)
            if let task, (task.state == .running || !task.agyLastReply.isEmpty || !task.messages.isEmpty) {
                Divider().background(Color.white.opacity(0.09))

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            // Latest Antigravity reply (if this is an Antigravity task)
                            if task.isAntigravity && !task.agyLastReply.isEmpty {
                                Text(task.agyLastReply)
                                    .font(.system(size: 11.5, design: .rounded))
                                    .foregroundColor(.white.opacity(0.90))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                            }

                            // Chat Messages
                            ForEach(task.messages) { msg in
                                HStack {
                                    if msg.isUser { Spacer(minLength: 32) }
                                    VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 3) {
                                        if msg.hasImage {
                                            Text("📸 屏幕截图")
                                                .font(.system(size: 9.5))
                                                .foregroundColor(Color(red: 0.56, green: 0.88, blue: 0.80))
                                        }
                                        Text(msg.text)
                                            .font(.system(size: 12, design: .rounded))
                                            .foregroundColor(.white.opacity(0.94))
                                            .textSelection(.enabled)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6.5)
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
                                                    vm.showToast("已复制")
                                                } label: {
                                                    Image(systemName: "doc.on.doc")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.white.opacity(0.5))
                                                }
                                                .buttonStyle(.plain)
                                                .help("复制回复")

                                                Button {
                                                    vm.voice.speakSystemTTS(msg.text)
                                                } label: {
                                                    Image(systemName: "speaker.wave.2")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.white.opacity(0.5))
                                                }
                                                .buttonStyle(.plain)
                                                .help("朗读回复")
                                            }
                                            .padding(.leading, 4)
                                        }
                                    }
                                    if !msg.isUser { Spacer(minLength: 20) }
                                }
                                .id(msg.id)
                            }

                            // Clean single-line running indicator
                            if task.state == .running {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .scaleEffect(0.58)
                                        .colorScheme(.dark)
                                    Text(task.currentAction.isEmpty ? "思考中…" : task.currentAction)
                                        .font(.system(size: 11.5))
                                        .foregroundColor(Color(red: 0.65, green: 0.84, blue: 1.0))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(vm.elapsedString(since: task.startedAt))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                .id("running-row")
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 195)
                    .onChange(of: task.messages.count) {
                        if let last = task.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            // Attached Screen Chip (only when screen captured)
            if vm.attachedScreenPath != nil {
                HStack(spacing: 5) {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.42, green: 0.88, blue: 0.78))
                    Text("已附带当前屏幕")
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Button { vm.clearAttachedScreen() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(red: 0.20, green: 0.34, blue: 0.36).opacity(0.42))
                .cornerRadius(7)
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }

            Divider().background(Color.white.opacity(0.09))

            // 3. Clean Single-Row Input Bar
            HStack(spacing: 6) {
                Button {
                    vm.captureScreenContext()
                } label: {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 13))
                        .foregroundColor(vm.attachedScreenPath != nil ? Color(red: 0.38, green: 0.90, blue: 0.78) : .white.opacity(0.65))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("附带当前屏幕")

                TextField("问哈基米或直接修改…", text: $vm.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundColor(.white)
                    .focused($isInputFocused)
                    .onSubmit {
                        vm.sendTextPrompt()
                    }

                Button {
                    vm.openVoicePanelAndRecord()
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.52, green: 0.80, blue: 1.0))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("语音对话")

                Button {
                    vm.sendTextPrompt()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(
                            (!vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.attachedScreenPath != nil)
                                ? Color(red: 0.56, green: 0.54, blue: 1.0)
                                : Color.white.opacity(0.24)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // Voice Mode Panel
    private var voicePanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("🎙 语音模式")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.95))
                Spacer()
                Button {
                    vm.activePanel = .workspace
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
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            Button {
                vm.toggleVoiceRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: vm.voice.isRecording
                                    ? [Color(red: 1.0, green: 0.35, blue: 0.45), Color(red: 0.65, green: 0.16, blue: 0.34)]
                                    : [Color(red: 0.46, green: 0.72, blue: 1.0), Color(red: 0.48, green: 0.34, blue: 0.88)],
                                center: .center,
                                startRadius: 6,
                                endRadius: 34
                            )
                        )
                        .frame(width: 62, height: 62)
                        .shadow(color: (vm.voice.isRecording ? Color.red : Color.purple).opacity(0.42), radius: 9)

                    if vm.selectedTask?.state == .running {
                        ProgressView().colorScheme(.dark)
                    } else {
                        Image(systemName: vm.voice.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            Text(vm.voice.isRecording ? "聆听中 \(String(format: "%d:%02d", vm.voice.recordingSeconds / 60, vm.voice.recordingSeconds % 60))" : vm.voiceStatusHint)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.90))

            if let lastReply = vm.selectedTask?.messages.last(where: { !$0.isUser }) {
                Text(lastReply.text)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                Button {
                    vm.captureScreenContext()
                } label: {
                    Label(vm.attachedScreenPath != nil ? "已附带屏幕" : "看屏幕", systemImage: "viewfinder")
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

    private func statusColor(_ st: TaskStateKind) -> Color {
        switch st {
        case .running: return Color(red: 0.38, green: 0.78, blue: 1.0)
        case .done: return Color(red: 0.42, green: 0.88, blue: 0.64)
        case .error: return Color(red: 1.0, green: 0.38, blue: 0.48)
        case .idle: return Color(red: 0.66, green: 0.62, blue: 1.0)
        }
    }
}

// MARK: - Full-Featured Clean Native Settings Window

struct PetSettingsView: View {
    @ObservedObject var vm: PetViewModel
    let onOpenStickers: () -> Void
    let onOpenAntigravity: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
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
            VStack(alignment: .leading, spacing: 5) {
                Text("尺寸大小")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.petSize) {
                    ForEach(PetSizePreset.allCases, id: \.self) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Motion Style
            VStack(alignment: .leading, spacing: 5) {
                Text("动效风格")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.motionStyle) {
                    ForEach(MotionStyle.allCases, id: \.self) { st in
                        Text(st.title).tag(st)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Manual Mood Switcher
            VStack(alignment: .leading, spacing: 5) {
                Text("切换表情 / 状态")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    ForEach([PetMood.idle, .happy, .working, .hiss, .sleep], id: \.self) { m in
                        Button {
                            vm.selectManualMood(m)
                        } label: {
                            HStack(spacing: 3) {
                                Text(m.icon)
                                Text(m.displayName)
                            }
                            .font(.system(size: 11.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(vm.mood == m ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // AI Model
            VStack(alignment: .leading, spacing: 5) {
                Text("快捷对话模型")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.modelPreset) {
                    ForEach(AIModelPreset.allCases, id: \.self) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            // Behavior Toggles
            VStack(alignment: .leading, spacing: 7) {
                Toggle("任务进行时显示头顶状态条（完成后可关闭/自动消失）", isOn: $vm.showTaskBanner)
                Toggle("Mini 模式（隐藏角色，仅保留快捷条）", isOn: $vm.miniMode)
                Toggle("窗口悬浮置顶（点按桌面时也留在前台）", isOn: $vm.alwaysOnTop)
                Toggle("Antigravity 实时任务联动", isOn: $vm.agySyncEnabled)
                Toggle("随 Antigravity 退出自动关闭", isOn: $vm.quitWithAntigravity)
                Toggle("桌面自由散步", isOn: $vm.wanderEnabled)
                Toggle("开机自动启动", isOn: $vm.launchAtLogin)
            }
            .font(.system(size: 12))

            Divider()

            HStack(spacing: 8) {
                Button("表情包文件夹", action: onOpenStickers)
                Button("打开 Antigravity", action: onOpenAntigravity)
                Spacer()
                Button("退出", role: .destructive, action: onQuit)
            }
        }
        .padding(18)
        .frame(width: 380)
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
    var onHoverChange: ((Bool) -> Void)? = nil
    var onHoverMove: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> PetInteractionNSView {
        let v = PetInteractionNSView()
        v.onSingleClick = onSingleClick
        v.onDoubleClick = onDoubleClick
        v.onDragStart = onDragStart
        v.onDragDelta = onDragDelta
        v.onDragEnd = onDragEnd
        v.onRightClick = onRightClick
        v.onHoverChange = onHoverChange
        v.onHoverMove = onHoverMove
        return v
    }

    func updateNSView(_ nsView: PetInteractionNSView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onDragStart = onDragStart
        nsView.onDragDelta = onDragDelta
        nsView.onDragEnd = onDragEnd
        nsView.onRightClick = onRightClick
        nsView.onHoverChange = onHoverChange
        nsView.onHoverMove = onHoverMove
    }
}

final class PetInteractionNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragDelta: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onHoverMove: ((CGFloat) -> Void)?

    private var mouseDownScreenPoint: NSPoint = .zero
    private var lastScreenPoint: NSPoint = .zero
    private var hasMovedBeyondDragThreshold = false
    private var pendingSingleClick: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea {
            removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        onHoverChange?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.width > 1 else { return }
        let normalizedX = ((pt.x / bounds.width) - 0.5) * 2.0
        onHoverMove?(normalizedX)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        onHoverChange?(false)
    }

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
    private var cancellables: Set<AnyCancellable> = []
    private let vm = PetViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupPetWindow()
        setupPanelWindow()
        setupStatusBar()
        bindCallbacks()
        registerGlobalHotKey()
        observeAntigravityLifecycle()
    }

    private func observeAntigravityLifecycle() {
        let agyBundleIDs: Set<String> = [
            "com.google.antigravity",
            "com.google.antigravity-ide"
        ]
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  agyBundleIDs.contains(bid) else {
                return
            }
            Task { @MainActor in
                guard let self, self.vm.quitWithAntigravity else { return }
                let stillRunning = NSWorkspace.shared.runningApplications.contains {
                    guard let id = $0.bundleIdentifier else { return false }
                    return agyBundleIDs.contains(id) && !$0.isTerminated
                }
                if !stillRunning {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func petWindowSize() -> NSSize {
        if vm.miniMode {
            return NSSize(width: 216, height: 72)
        }
        let s = vm.petSize.rawValue
        return NSSize(width: max(216, s + 24), height: s + 72)
    }

    private func setupPetWindow() {
        let size = petWindowSize()
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.maxX - size.width - 18,
            y: screenFrame.minY + 16
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
        petWindow.acceptsMouseMovedEvents = true
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
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 140),
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
        let w = max(336, fitting.width)
        let h = max(108, min(360, fitting.height))

        let petFrame = petWindow.frame
        let screen = petWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var px = petFrame.midX - w / 2
        px = max(screen.minX + 12, min(screen.maxX - w - 12, px))

        var py = petFrame.maxY + 2
        if py + h > screen.maxY - 12 {
            py = max(screen.minY + 12, petFrame.minY - h - 2)
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
                self.positionPanelWindow()
                NSApp.activate(ignoringOtherApps: true)
                self.panelWindow.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.positionPanelWindow()
                }
            }
            self.refreshMenuBar()
        }

        vm.$tasks.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.vm.activePanel != .none else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.positionPanelWindow()
            }
        }.store(in: &cancellables)
    }

    private func registerGlobalHotKey() {
        globalHotKeyCallback = { [weak self] in
            guard let self else { return }
            if !self.vm.isVisible {
                self.vm.isVisible = true
                self.petWindow.orderFrontRegardless()
            }
            if self.vm.activePanel == .workspace {
                self.vm.closePanel()
            } else {
                self.vm.openWorkspacePanel()
            }
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x47504554), id: 1)
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

    /// Minimalist 2-item right-click menu (ChatGPT Pet style)
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

    private func buildStatusBarMenu() -> NSMenu {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: vm.isVisible ? "隐藏哈基米" : "显示哈基米",
            action: #selector(toggleVisibility),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let chatItem = NSMenuItem(title: "快捷对话与任务 (⌥G)", action: #selector(openWorkspaceAction), keyEquivalent: "")
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
            onOpenAntigravity: { [weak self] in self?.vm.openApp(named: "/Applications/Antigravity.app") },
            onQuit: { [weak self] in self?.quitApp() }
        )
        let hosting = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
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

    @objc private func openWorkspaceAction() {
        if !vm.isVisible { toggleVisibility() }
        vm.openWorkspacePanel()
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
