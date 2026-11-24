import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    static let bbWindow = Color(hex: 0x15171B)
    static let bbCard = Color(hex: 0x1C1F24)
    static let bbLine = Color(hex: 0x2A2E35)
    static let bbInput = Color(hex: 0x121418)
    static let bbText = Color(hex: 0xE8EAED)
    static let bbMuted = Color(hex: 0xA3A9B1)
    static let bbAccent = Color(hex: 0xFF8A3D)
    static let bbRed = Color(hex: 0xE5484D)
    static let bbGreen = Color(hex: 0x4ADE80)
    static let bbYellow = Color(hex: 0xFACC15)
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.bbCard))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bbLine, lineWidth: 1))
    }
}

struct WaveIcon: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(3, 12), (6, 12), (9, 5), (15, 19), (18, 12), (21, 12)]
        var p = Path()
        for (i, pt) in pts.enumerated() {
            let q = CGPoint(x: r.minX + pt.0 / 24 * r.width, y: r.minY + pt.1 / 24 * r.height)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }
}

final class HoldTracker {
    var down = false
}

struct ContentView: View {
    @ObservedObject var m = AppModel.shared
    // No @State: the Command Line Tools do not include the SwiftUI macro plugin.
    private let hold = HoldTracker()

    private let sounds: [(String, String)] = [
        ("classic", "Classic 1 kHz"), ("censor", "TV censor"), ("dolphin", "Dolphin"),
        ("quack", "Duck quack"), ("horn", "Air horn"), ("custom", "My sound file")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    micCard
                    waveLinkCard
                }
                .frame(maxWidth: .infinity)
                bleepCard
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            Spacer(minLength: 0)
            footer
        }
        .frame(minWidth: 920, minHeight: 700)
        .background(Color.bbWindow)
        .foregroundColor(.bbText)
        .preferredColorScheme(.dark)
    }

    // MARK: Mic

    private var micCard: some View {
        Card {
            HStack {
                header("MICROPHONE INPUT")
                Spacer()
                Text(micStateText).font(.system(size: 12, weight: .semibold)).foregroundColor(micStateColor)
            }
            label("Device")
            Picker("", selection: $m.deviceUID) {
                Text("Default microphone").tag("default")
                ForEach(m.devices) { d in Text(d.name).tag(d.id) }
            }
            .labelsHidden()
            .onAppear { m.refreshDevices() }
            label("Level")
            meter
            HStack {
                Text("Input gain").font(.system(size: 13)).foregroundColor(.bbMuted)
                Spacer()
                Text("\(Int(m.gain))%").font(.system(size: 13))
            }
            .padding(.top, 14).padding(.bottom, 4)
            Slider(value: $m.gain, in: 0...300, step: 1).tint(.bbAccent)
            if let p = m.problem {
                Text(p).font(.system(size: 12)).foregroundColor(.bbRed).padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var micStateText: String {
        if !m.running { return "OFFLINE" }
        return m.bleeping ? "MIC MUTED" : "LIVE"
    }

    private var micStateColor: Color {
        if !m.running { return .gray }
        return m.bleeping ? .bbRed : .bbGreen
    }

    private var meter: some View {
        let db = m.level > 0.0001 ? 20 * log10(Double(m.level)) : -100
        let lit = max(0, min(30, Int(((db + 60) / 60 * 30).rounded())))
        return HStack(spacing: 3) {
            ForEach(0..<30, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < lit ? (i < 20 ? Color.bbGreen : i < 26 ? Color.bbYellow : Color(hex: 0xF87171)) : Color.bbLine)
            }
        }
        .frame(height: 22)
        .accessibilityLabel("Microphone level")
    }

    // MARK: Wave Link

    private var waveLinkCard: some View {
        Card {
            header("WAVE LINK")
            HStack(spacing: 12) {
                WaveIcon().stroke(Color.bbText, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bleep Box app channel").font(.system(size: 14, weight: .semibold))
                    Text("Wave Link → Create Channel → Add App → Bleep Box")
                        .font(.system(size: 12)).foregroundColor(.bbMuted)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(m.running ? Color.bbGreen : Color.gray).frame(width: 8, height: 8)
                    Text(m.running ? "Sending audio" : "Stopped").font(.system(size: 12)).foregroundColor(.bbMuted)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.bbInput))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.bbLine))
            .padding(.top, 14)
            Toggle("Play the bleep in my headphones (not my voice)", isOn: $m.monitorBleep)
                .toggleStyle(.checkbox)
                .padding(.top, 14)
            if m.monitorBleep {
                label("Headphones")
                Picker("", selection: $m.monitorUID) {
                    Text("Mac default output").tag("default")
                    ForEach(m.outputDevices) { d in Text(d.name).tag(d.id) }
                }
                .labelsHidden()
            }
            label("Stream audio output (mic + bleep)")
            Picker("", selection: $m.outputUID) {
                Text("Mac default output").tag("default")
                ForEach(m.outputDevices) { d in Text(d.name).tag(d.id) }
            }
            .labelsHidden()
            Text("Select an output that you do not listen to. Wave Link still gets this audio from the Bleep Box app.")
                .font(.system(size: 12)).foregroundColor(.bbMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Toggle("Mute mic fully while bleeping", isOn: $m.fullMute)
                .toggleStyle(.checkbox)
                .padding(.top, 14)
            Text("Wave Link: Bleep Box → Stream mix ON, Wave mic → Stream mix OFF. Monitor mix: Bleep Box OFF. Do not add \"Bleep Box Monitor\" to Wave Link.")
                .font(.system(size: 12)).foregroundColor(.bbMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    // MARK: Bleep

    private var bleepCard: some View {
        Card {
            HStack {
                Text("Bleep").font(.system(size: 22, weight: .bold))
                Spacer()
                Picker("", selection: $m.mode) {
                    Text("Hold").tag("hold")
                    Text("Toggle").tag("toggle")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            HStack {
                Spacer()
                bigButton
                Spacer()
            }
            .padding(.top, 24)

            Text(m.mode == "hold" ? "Hold to bleep — or hold your Stream Deck key" : "Click once to start, click again to stop")
                .font(.system(size: 13)).foregroundColor(.bbMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)

            label("Bleep sound").padding(.top, 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(sounds, id: \.0) { s in soundButton(id: s.0, title: s.1) }
            }
            HStack(spacing: 12) {
                Button("Choose sound file…") { m.chooseCustomFile() }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(hex: 0xFF9A4D))
                Text(m.customPath.isEmpty ? "No file selected" : (m.customPath as NSString).lastPathComponent)
                    .font(.system(size: 12)).foregroundColor(.bbMuted).lineLimit(1).truncationMode(.middle)
            }
            .padding(.top, 10)

            HStack {
                Text("Bleep volume").font(.system(size: 13)).foregroundColor(.bbMuted)
                Spacer()
                Text("\(Int(m.volume))%").font(.system(size: 13))
            }
            .padding(.top, 14).padding(.bottom, 4)
            Slider(value: $m.volume, in: 0...100, step: 1).tint(.bbAccent)
        }
    }

    private var bigButton: some View {
        let on = m.bleeping
        return ZStack {
            Circle()
                .fill(on ? Color.bbRed : Color.bbInput)
                .overlay(Circle().stroke(on ? Color(hex: 0xFF8A8D) : Color.bbAccent, lineWidth: 4))
                .shadow(color: on ? Color.bbRed.opacity(0.6) : .clear, radius: 30)
            VStack(spacing: 8) {
                WaveIcon()
                    .stroke(on ? Color.white : Color.bbAccent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 46, height: 46)
                Text(on ? "BLEEPING" : "BLEEP")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(on ? .white : .bbAccent)
            }
        }
        .frame(width: 220, height: 220)
        .scaleEffect(on ? 0.96 : 1)
        .animation(.easeOut(duration: 0.08), value: on)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !hold.down { hold.down = true; m.press() }
                }
                .onEnded { _ in
                    hold.down = false
                    m.release()
                }
        )
        .accessibilityLabel("Bleep")
        .accessibilityAddTraits(.isButton)
    }

    private func soundButton(id: String, title: String) -> some View {
        let selected = m.sound == id
        return Button {
            if id == "custom" && m.customPath.isEmpty {
                m.chooseCustomFile()
            } else {
                m.sound = id
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .white : Color(hex: 0xC9CDD3))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(hex: 0x33241A) : Color.bbInput))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.bbAccent : Color.bbLine, lineWidth: selected ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Circle().fill(m.running ? Color.bbGreen : Color.gray).frame(width: 8, height: 8)
            Text(m.running ? "Stream Deck port 28196 open · v\(AppModel.version)" : "Audio stopped")
                .font(.system(size: 12)).foregroundColor(.bbMuted)
            Spacer()
            Text("Hotkey: Control + Shift + B").font(.system(size: 12)).foregroundColor(.bbMuted)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(Color(hex: 0x101215))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(hex: 0x23262C)), alignment: .top)
    }

    // MARK: Helpers

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundColor(.bbMuted)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).foregroundColor(.bbMuted).padding(.top, 14).padding(.bottom, 6)
    }
}
