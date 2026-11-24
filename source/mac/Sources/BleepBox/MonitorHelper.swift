import AudioToolbox
import AVFoundation
import Foundation

/// "Bleep Box Monitor": a separate, hidden process that plays ONLY the bleep to your headphones.
/// It is a separate app (own bundle ID), so Wave Link does not mix it into the Bleep Box channel.
/// Commands come from the main app on stdin, one per line:
///   on <soundIndex> <volume 0-100> | off | device <uid> | custom <path>
final class MonitorHelper {
    private let synth = Synth()
    private var engine: AVAudioEngine?
    private var uid = "default"
    private var observer: NSObjectProtocol?

    static func run() {
        let helper = MonitorHelper()
        helper.start()
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                DispatchQueue.main.async { helper.handle(line) }
            }
            exit(0) // main app closed
        }
        dispatchMain()
    }

    private func start() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        engine?.stop()
        let e = AVAudioEngine()
        if uid != "default", let id = AudioDevices.outputDeviceID(forUID: uid), let au = e.outputNode.audioUnit {
            var dev = id
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let src = AVAudioSourceNode(format: fmt, renderBlock: synth.renderBlock)
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: fmt)
        do {
            e.prepare()
            try e.start()
        } catch {
            FileHandle.standardError.write(Data("monitor: \(error)\n".utf8))
        }
        engine = e
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.start() }
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "on":
            let a = arg.split(separator: " ")
            synth.sound = a.count > 0 ? (Int(a[0]) ?? 0) : 0
            synth.volume = a.count > 1 ? Float(Int(a[1]) ?? 80) / 100 : 0.8
            synth.overrideSound = -1
            synth.overrideVolume = -1
            synth.bleeping = true
        case "off":
            synth.bleeping = false
        case "device":
            if arg != uid {
                uid = arg.isEmpty ? "default" : arg
                start()
            }
        case "custom":
            synth.setCustom(Synth.loadAudio(path: arg) ?? [])
        default:
            break
        }
    }
}
