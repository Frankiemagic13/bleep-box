import AVFoundation
import Foundation

/// Makes the bleep sound. The audio thread calls `renderBlock`.
final class Synth {
    static let soundIDs = ["classic", "censor", "dolphin", "quack", "horn", "custom"]

    static func index(of id: String?) -> Int {
        guard let id else { return -1 }
        return soundIDs.firstIndex(of: id) ?? -1
    }

    // Settings (set on the main thread, read on the audio thread)
    var bleeping = false
    var sound = 0
    var volume: Float = 0.8
    var overrideSound = -1
    var overrideVolume: Float = -1

    private let customLock = NSLock()
    private var custom: [Float] = []

    // Render state (audio thread only)
    private let rate = 48000.0
    private var env: Float = 0
    private var wasOn = false
    private var t = 0.0
    private var p1 = 0.0, p2 = 0.0, p3 = 0.0
    private var customPos = 0

    func setCustom(_ samples: [Float]) {
        customLock.lock()
        custom = samples
        customLock.unlock()
    }

    lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [unowned self] _, _, frameCount, abl in
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let on = self.bleeping
        let snd = self.overrideSound >= 0 ? self.overrideSound : self.sound
        let vol = self.overrideVolume >= 0 ? self.overrideVolume : self.volume
        if on && !self.wasOn {
            self.t = 0
            self.p1 = 0; self.p2 = 0; self.p3 = 0
            self.customPos = 0
        }
        self.wasOn = on

        // Never wait on the audio thread: if the lock is busy, the custom sound is silent for one buffer.
        let haveLock = snd == 5 ? self.customLock.try() : false
        let fade: Float = 1.0 / Float(0.006 * self.rate)
        let target: Float = on ? 1 : 0

        for i in 0..<Int(frameCount) {
            if self.env < target {
                self.env = min(target, self.env + fade)
            } else if self.env > target {
                self.env = max(target, self.env - fade)
            }
            var v: Float = 0
            if self.env > 0 {
                v = self.next(snd, haveLock) * vol * self.env
            }
            for b in buffers {
                b.mData?.assumingMemoryBound(to: Float.self)[i] = v
            }
        }
        if haveLock { self.customLock.unlock() }
        return noErr
    }

    @inline(__always) private func wrap(_ p: Double) -> Double { p - p.rounded(.down) }

    private func next(_ snd: Int, _ haveLock: Bool) -> Float {
        let ts = t / rate
        t += 1
        var v = 0.0
        switch snd {
        case 0: // classic 1 kHz
            p1 = wrap(p1 + 1000 / rate)
            v = 0.5 * sin(2 * .pi * p1)
        case 1: // TV censor (square-ish 1 kHz)
            p1 = wrap(p1 + 1000 / rate)
            let p = 2 * .pi * p1
            v = 0.4 * (sin(p) + sin(3 * p) / 3 + sin(5 * p) / 5)
        case 2: // dolphin
            let f = 2600 + 1800 * sin(2 * .pi * 7 * ts)
            p1 = wrap(p1 + f / rate)
            let am = 0.6 + 0.4 * sin(2 * .pi * 23 * ts)
            v = 0.4 * am * sin(2 * .pi * p1)
        case 3: // duck quack
            let per = 0.32, len = 0.2
            let pos = ts.truncatingRemainder(dividingBy: per)
            if pos < len {
                let f = 380 - 150 * pos / len
                p1 = wrap(p1 + f / rate)
                let saw = 2 * p1 - 1
                let e = sin(.pi * pos / len)
                v = 0.35 * e * (0.7 * saw + 0.3 * sin(2 * .pi * p1 * 3))
            }
        case 4: // air horn
            p1 = wrap(p1 + 440 / rate)
            p2 = wrap(p2 + 554.37 / rate)
            p3 = wrap(p3 + 659.25 / rate)
            let x = ((2 * p1 - 1) + (2 * p2 - 1) + (2 * p3 - 1)) * 0.5
            v = 0.35 * tanh(x * 1.5)
        case 5: // custom file
            if haveLock && !custom.isEmpty {
                let s = custom[customPos % custom.count]
                customPos += 1
                return s
            }
        default:
            break
        }
        return Float(v)
    }

    /// Reads any audio file macOS can open (wav, aiff, mp3, m4a) as 48 kHz mono.
    static func loadAudio(path: String) -> [Float]? {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, frames < 48000 * 120,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        guard let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        let chans = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chans {
            let p = ch[c]
            for i in 0..<n { mono[i] += p[i] / Float(chans) }
        }
        let sr = fmt.sampleRate
        if abs(sr - 48000) < 1 { return mono }
        let ratio = sr / 48000
        let outN = Int(Double(n) / ratio)
        var out = [Float](repeating: 0, count: outN)
        for i in 0..<outN {
            let s = Double(i) * ratio
            let a = Int(s)
            let f = Float(s - Double(a))
            let va = mono[min(a, n - 1)]
            let vb = mono[min(a + 1, n - 1)]
            out[i] = va + (vb - va) * f
        }
        return out
    }
}
