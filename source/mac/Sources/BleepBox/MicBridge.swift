import AVFoundation
import Foundation

/// Single-producer / single-consumer float ring buffer.
final class RingBuffer {
    private let cap: Int
    private let buf: UnsafeMutablePointer<Float>
    private var w = 0
    private var r = 0
    private let lock = NSLock()

    init(capacity: Int) {
        cap = capacity
        buf = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        buf.initialize(repeating: 0, count: capacity)
    }

    deinit { buf.deallocate() }

    func reset() {
        lock.lock(); w = 0; r = 0; lock.unlock()
    }

    func write(_ p: UnsafePointer<Float>, _ n: Int) {
        lock.lock()
        for i in 0..<n {
            buf[w % cap] = p[i]
            w += 1
        }
        if w - r > cap { r = w - cap }
        lock.unlock()
    }

    /// Reads n samples. Keeps the delay near `target` samples (input and output clocks drift).
    func read(into p: UnsafeMutablePointer<Float>, _ n: Int, target: Int) {
        guard lock.try() else {
            for i in 0..<n { p[i] = 0 }
            return
        }
        if w - r > target * 4 { r = w - target }
        for i in 0..<n {
            if r < w {
                p[i] = buf[r % cap]
                r += 1
            } else {
                p[i] = 0
            }
        }
        lock.unlock()
    }
}

/// Moves mic audio from the input engine to the output engine, with gain and mute.
final class MicBridge {
    let ring = RingBuffer(capacity: 96000)
    var gain: Float = 1
    var muted = false
    var muteLevel: Float = 0     // 0 = full mute, 0.2 = duck
    var peak: Float = 0          // read and reset by the UI
    private(set) var rate: Double = 48000
    private var env: Float = 1
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384)

    deinit { scratch.deallocate() }

    func configure(rate: Double) {
        self.rate = rate
        ring.reset()
    }

    /// Input side: average all mic channels to mono and write to the ring.
    func makeSink() -> AVAudioSinkNode {
        AVAudioSinkNode { [unowned self] _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            let n = Int(frameCount)
            guard n > 0, n <= 16384, list.count > 0 else { return noErr }
            var totalCh = 0
            for b in list { totalCh += Int(b.mNumberChannels) }
            guard totalCh > 0 else { return noErr }
            for i in 0..<n { self.scratch[i] = 0 }
            for b in list {
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let nch = Int(b.mNumberChannels)
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<nch { s += d[i * nch + c] }
                    self.scratch[i] += s
                }
            }
            let inv = 1 / Float(totalCh)
            for i in 0..<n { self.scratch[i] *= inv }
            self.ring.write(self.scratch, n)
            return noErr
        }
    }

    /// Output side: read the mic, apply gain and the mute fade.
    lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [unowned self] _, _, frameCount, abl in
        let list = UnsafeMutableAudioBufferListPointer(abl)
        let n = Int(frameCount)
        guard list.count > 0, let out = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        self.ring.read(into: out, n, target: Int(self.rate * 0.02))
        let target: Float = self.muted ? self.muteLevel : 1
        let step = 1 / Float(0.006 * self.rate)
        let g = self.gain
        var pk: Float = 0
        for i in 0..<n {
            if self.env < target {
                self.env = min(target, self.env + step)
            } else if self.env > target {
                self.env = max(target, self.env - step)
            }
            let v = max(-1, min(1, out[i] * g * self.env))
            out[i] = v
            pk = max(pk, abs(v))
        }
        for b in list.dropFirst() {
            if let d = b.mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<n { d[i] = out[i] }
            }
        }
        if pk > self.peak { self.peak = pk }
        return noErr
    }
}
