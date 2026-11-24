import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import UniformTypeIdentifiers

/// App state + audio engine.
/// Mic -> gain -> mute mixer -+-> app output (Wave Link captures the app)
/// Bleep synth --------------+
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let version = "1.0.0"

    private let defaults = UserDefaults.standard
    let synth = Synth()

    @Published var devices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var monitorBleep: Bool {
        didSet { defaults.set(monitorBleep, forKey: "monitorBleep"); if monitorBleep { startHelper() } else { stopHelper() } }
    }
    @Published var monitorUID: String {
        didSet { defaults.set(monitorUID, forKey: "monitorOutput"); sendHelper("device \(monitorUID)") }
    }
    @Published var outputUID: String {
        didSet {
            defaults.set(outputUID, forKey: "output")
            if oldValue != outputUID { startAudio() }
        }
    }
    @Published var deviceUID: String {
        didSet {
            defaults.set(deviceUID, forKey: "device")
            if oldValue != deviceUID { startAudio() }
        }
    }
    @Published var gain: Double {
        didSet { defaults.set(gain, forKey: "gain"); applyGain() }
    }
    @Published var sound: String {
        didSet { defaults.set(sound, forKey: "sound"); synth.sound = max(0, Synth.index(of: sound)) }
    }
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: "volume"); synth.volume = Float(volume / 100) }
    }
    @Published var fullMute: Bool {
        didSet { defaults.set(fullMute, forKey: "fullMute"); applyMute() }
    }
    @Published var mode: String {
        didSet { defaults.set(mode, forKey: "mode"); if mode != "hold" { pressing = false } }
    }
    @Published var customPath: String {
        didSet { defaults.set(customPath, forKey: "custom") }
    }
    @Published private(set) var bleeping = false
    @Published private(set) var level: Float = 0
    @Published private(set) var running = false
    @Published private(set) var problem: String?

    let mic = MicBridge()
    private var inEngine: AVAudioEngine?
    private var outEngine: AVAudioEngine?
    private var pressing = false
    private var observers: [NSObjectProtocol] = []
    private var meterTimer: Timer?
    private var restartPending = false
    private var helper: Process?
    private var helperIn: FileHandle?

    private init() {
        deviceUID = defaults.string(forKey: "device") ?? "default"
        outputUID = defaults.string(forKey: "output") ?? "default"
        monitorBleep = defaults.object(forKey: "monitorBleep") as? Bool ?? true
        monitorUID = defaults.string(forKey: "monitorOutput") ?? "default"
        gain = defaults.object(forKey: "gain") as? Double ?? 100
        sound = defaults.string(forKey: "sound") ?? "classic"
        volume = defaults.object(forKey: "volume") as? Double ?? 80
        fullMute = defaults.object(forKey: "fullMute") as? Bool ?? true
        mode = defaults.string(forKey: "mode") ?? "hold"
        customPath = defaults.string(forKey: "custom") ?? ""
        synth.sound = max(0, Synth.index(of: sound))
        synth.volume = Float(volume / 100)
        if !customPath.isEmpty { loadCustom(path: customPath) }
    }

    // MARK: - Start

    func boot() {
        refreshDevices()
        if monitorBleep { startHelper() }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startAudio()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    if ok { self.startAudio() } else { self.problem = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone." }
                }
            }
        default:
            problem = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        }
    }

    func refreshDevices() {
        devices = AudioDevices.inputDevices()
        outputDevices = AudioDevices.outputDevices()
    }

    func stopAudio() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        inEngine?.stop()
        outEngine?.stop()
        inEngine = nil
        outEngine = nil
        meterTimer?.invalidate()
        meterTimer = nil
        running = false
        level = 0
    }

    /// Two engines: macOS uses one audio unit per engine for input and output,
    /// so one engine fails (-10875) when the mic and the speakers are different devices.
    func startAudio() {
        stopAudio()

        // 1. Input engine: mic -> sink -> ring buffer
        let ie = AVAudioEngine()
        let input = ie.inputNode
        var deviceOK = true
        if deviceUID != "default" {
            if let id = AudioDevices.deviceID(forUID: deviceUID), let au = input.audioUnit {
                var dev = id
                let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
                if st != noErr { deviceOK = false; problem = "Could not open the selected microphone (error \(st))." }
            } else {
                deviceOK = false
                problem = "The selected microphone is not connected. Using the default microphone."
            }
        }
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            problem = "No microphone input found."
            return
        }
        mic.configure(rate: inFmt.sampleRate)
        let sink = mic.makeSink()
        ie.attach(sink)
        ie.connect(input, to: sink, format: inFmt)

        // 2. Output engine: mic (from ring) + bleep -> default output (Wave Link captures the app)
        let oe = AVAudioEngine()
        let micFmt = AVAudioFormat(standardFormatWithSampleRate: inFmt.sampleRate, channels: 1)!
        let micSrc = AVAudioSourceNode(format: micFmt, renderBlock: mic.renderBlock)
        oe.attach(micSrc)
        oe.connect(micSrc, to: oe.mainMixerNode, format: micFmt)
        let bleepFmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let bleepSrc = AVAudioSourceNode(format: bleepFmt, renderBlock: synth.renderBlock)
        oe.attach(bleepSrc)
        oe.connect(bleepSrc, to: oe.mainMixerNode, format: bleepFmt)

        if outputUID != "default" {
            if let id = AudioDevices.outputDeviceID(forUID: outputUID), let au = oe.outputNode.audioUnit {
                var dev = id
                let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
                if st != noErr { deviceOK = false; problem = "Could not open the selected output (error \(st))." }
            } else {
                deviceOK = false
                problem = "The selected output is not connected. Using the default output."
            }
        }

        applyGain()
        applyMute()

        do {
            oe.prepare()
            try oe.start()
        } catch {
            problem = "Audio output could not start: \(error.localizedDescription)"
            return
        }
        do {
            ie.prepare()
            try ie.start()
        } catch {
            oe.stop()
            problem = "Microphone could not start: \(error.localizedDescription)"
            return
        }
        inEngine = ie
        outEngine = oe
        running = true
        if deviceOK { problem = nil }

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = self.mic.peak
            self.mic.peak = 0
            self.level = max(p, self.level * 0.8)
        }

        // Restart when a device is plugged in or out, or a sample rate changes
        for e in [ie, oe] {
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: e, queue: .main
            ) { [weak self] _ in
                guard let self, !self.restartPending else { return }
                self.restartPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.restartPending = false
                    self.refreshDevices()
                    self.startAudio()
                }
            })
        }
    }

    // MARK: - Bleep

    private func applyMute() {
        mic.muteLevel = fullMute ? 0 : 0.2
        mic.muted = bleeping
    }

    private func applyGain() {
        mic.gain = Float(max(0, min(300, gain)) / 100)
    }

    func setBleep(_ on: Bool, sound s: String? = nil, volume v: Int? = nil) {
        if on {
            synth.overrideSound = Synth.index(of: s)
            synth.overrideVolume = v.map { Float($0) / 100 } ?? -1
        }
        synth.bleeping = on
        bleeping = on
        applyMute()
        if on {
            let idx = synth.overrideSound >= 0 ? synth.overrideSound : synth.sound
            let vol = synth.overrideVolume >= 0 ? synth.overrideVolume : synth.volume
            sendHelper("on \(idx) \(Int((vol * 100).rounded()))")
        } else {
            sendHelper("off")
        }
    }

    // MARK: - Headphone bleep (separate "Bleep Box Monitor" process)

    func startHelper() {
        guard helper == nil else { return }
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Bleep Box Monitor.app/Contents/MacOS/BleepBoxMonitor")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            problem = "Bleep Box Monitor is missing. Build and install Bleep Box again."
            return
        }
        let p = Process()
        p.executableURL = url
        p.arguments = ["--monitor-helper"]
        let pipe = Pipe()
        p.standardInput = pipe
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.helper === proc else { return }
                self.helper = nil
                self.helperIn = nil
            }
        }
        do {
            try p.run()
        } catch {
            problem = "Bleep Box Monitor could not start: \(error.localizedDescription)"
            return
        }
        helper = p
        helperIn = pipe.fileHandleForWriting
        sendHelper("device \(monitorUID)")
        if !customPath.isEmpty { sendHelper("custom \(customPath)") }
    }

    func stopHelper() {
        try? helperIn?.close()
        helper?.terminate()
        helper = nil
        helperIn = nil
    }

    private func sendHelper(_ line: String) {
        guard let h = helperIn else { return }
        do {
            try h.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            helper = nil
            helperIn = nil
        }
    }

    func press() {
        if mode == "hold" {
            guard !pressing else { return }
            pressing = true
            setBleep(true)
        } else {
            setBleep(!bleeping)
        }
    }

    func release() {
        guard mode == "hold", pressing else { return }
        pressing = false
        setBleep(false)
    }

    func loadCustom(path: String) {
        sendHelper("custom \(path)")
        if let samples = Synth.loadAudio(path: path) {
            synth.setCustom(samples)
        } else {
            synth.setCustom([])
            problem = "Could not read the sound file."
        }
    }

    func chooseCustomFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a bleep sound"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            loadCustom(path: url.path)
            sound = "custom"
        }
    }

    // MARK: - Control API (same as the Windows OBS plugin)

    func statusJSON() -> [String: Any] {
        [
            "ok": true,
            "version": Self.version,
            "platform": "mac",
            "bleeping": bleeping,
            "level": Double(level),
            "sources": running ? 1 : 0,
            "capturing": running ? 1 : 0,
            "sound": sound,
            "volume": Int(volume),
            "fullMute": fullMute,
            "mode": mode,
            "gain": Int(gain),
            "device": deviceUID,
            "custom": customPath
        ]
    }

    func handle(path: String, query q: [String: String]) -> (Int, [String: Any]) {
        let vol = q["volume"].flatMap { Int($0) }.map { max(0, min(100, $0)) }
        switch path {
        case "/status":
            break
        case "/bleep/on":
            setBleep(true, sound: q["sound"], volume: vol)
        case "/bleep/off":
            pressing = false
            setBleep(false)
        case "/bleep/toggle":
            pressing = false
            if bleeping { setBleep(false) } else { setBleep(true, sound: q["sound"], volume: vol) }
        case "/devices":
            refreshDevices()
            var list: [[String: String]] = [["id": "default", "name": "Default microphone"]]
            list += devices.map { ["id": $0.id, "name": $0.name] }
            return (200, ["ok": true, "devices": list])
        case "/set":
            if let c = q["custom"] { customPath = c; loadCustom(path: c) }
            if let s = q["sound"], Synth.index(of: s) >= 0 { sound = s }
            if let v = vol { volume = Double(v) }
            if let f = q["fullMute"] { fullMute = ["1", "true", "yes", "on"].contains(f) }
            if let m = q["mode"] { mode = (m == "toggle") ? "toggle" : "hold" }
            if let g = q["gain"].flatMap({ Double($0) }) { gain = max(0, min(300, g)) }
            if let dv = q["device"] { deviceUID = dv }
        default:
            return (404, ["ok": false, "error": "unknown path"])
        }
        return (200, statusJSON())
    }
}
