import AppKit

/// The sounds for starting and stopping a recording, a report being ready, dictation on and off,
/// and something going wrong: one pack, picked in Settings (Click unless changed, or off).
/// Each sound is synthesized once into a WAV, so there are no audio files.
enum Sounds {
    enum Kind: CaseIterable { case start, stop, done, dictateOn, dictateOff, error }

    enum Pack: String, CaseIterable, Identifiable {
        case click, pop, key, glass, wood, chime, retro
        var id: String { rawValue }

        var name: String {
            switch self {
            case .click: "Click"
            case .pop: "Soft pop"
            case .key: "Mechanical key"
            case .glass: "Glass"
            case .wood: "Wood block"
            case .chime: "Chime"
            case .retro: "Retro"
            }
        }
    }

    /// nil when sounds are off.
    static var pack: Pack? {
        let saved = UserDefaults.standard.string(forKey: "soundPack") ?? Pack.click.rawValue
        return Pack(rawValue: saved)
    }

    @MainActor private static var cache: [Pack: [Kind: NSSound]] = [:]

    @MainActor
    static func play(_ kind: Kind) {
        guard let pack else { return }
        play(kind, in: pack)
    }

    /// A pack's record and report-ready sounds, for choosing one.
    @MainActor
    static func preview(_ pack: Pack) {
        play(.start, in: pack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { play(.done, in: pack) }
    }

    @MainActor
    private static func play(_ kind: Kind, in pack: Pack) {
        if cache[pack] == nil {
            cache[pack] = Dictionary(uniqueKeysWithValues: Kind.allCases.compactMap { k in Synth.render(pack, k).map { (k, $0) } })
        }
        guard let s = cache[pack]?[kind]?.copy() as? NSSound else { return }
        s.volume = 0.6
        s.play()
    }
}

/// The same recipes as the sound lab: pitched voices that glide and decay, and bursts of
/// filtered noise, mixed and gently limited.
private struct Synth {
    static let rate = 44_100.0
    private var samples: [Float] = []

    static func render(_ pack: Sounds.Pack, _ kind: Sounds.Kind) -> NSSound? {
        var s = Synth()
        s.compose(pack, kind)
        return s.wav()
    }

    // MARK: Voices

    enum Wave { case sine, square, saw }

    /// The frequency glides exponentially from f0 to f1 over `glide`; the level rises over
    /// `attack`, then falls exponentially until `dur`.
    mutating func tone(_ at: Double, _ wave: Wave = .sine, f0: Double, f1: Double? = nil, glide: Double = 0.05,
                       dur: Double = 0.15, gain: Double = 0.3, attack: Double = 0.002) {
        let f1 = f1 ?? f0
        let start = Int(at * Self.rate), count = Int(dur * Self.rate)
        grow(to: start + count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / Self.rate
            let f = f1 == f0 ? f0 : f0 * pow(f1 / f0, min(t, glide) / glide)
            phase += f / Self.rate
            let p = phase - floor(phase)
            let v: Double =
                switch wave {
                case .sine: sin(2 * .pi * p)
                case .square: p < 0.5 ? 1 : -1
                case .saw: 2 * p - 1
                }
            samples[start + i] += Float(v * Self.envelope(t, gain: gain, attack: attack, dur: dur))
        }
    }

    enum Filter { case highpass, lowpass, bandpass }

    /// White noise through a filter, starting at `gain` and falling away by `dur`.
    mutating func noise(_ at: Double, _ filter: Filter = .highpass, freq: Double = 3000, q: Double = 0.7,
                        dur: Double = 0.02, gain: Double = 0.4) {
        let start = Int(at * Self.rate), count = Int(dur * Self.rate)
        grow(to: start + count)
        // The usual biquad (Audio EQ Cookbook).
        let w = 2 * Double.pi * freq / Self.rate, alpha = sin(w) / (2 * q), c = cos(w)
        let (b0, b1, b2): (Double, Double, Double) =
            switch filter {
            case .lowpass: ((1 - c) / 2, 1 - c, (1 - c) / 2)
            case .highpass: ((1 + c) / 2, -(1 + c), (1 + c) / 2)
            case .bandpass: (alpha, 0, -alpha)
            }
        let a0 = 1 + alpha, a1 = -2 * c, a2 = 1 - alpha
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<count {
            let x = Double.random(in: -1...1)
            let y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x; y2 = y1; y1 = y
            let t = Double(i) / Self.rate
            samples[start + i] += Float(y * gain * pow(0.0001 / gain, t / dur))
        }
    }

    private static func envelope(_ t: Double, gain: Double, attack: Double, dur: Double) -> Double {
        if t < attack { return 0.0001 * pow(gain / 0.0001, t / attack) }
        return gain * pow(0.0001 / gain, (t - attack) / max(0.001, dur - attack))
    }

    private mutating func grow(to n: Int) {
        if samples.count < n { samples += [Float](repeating: 0, count: n - samples.count) }
    }

    // MARK: Packs

    mutating func click(_ t: Double, _ k: Double = 1, _ g: Double = 1) {
        noise(t, freq: 2600 * k, dur: 0.014, gain: 0.55 * g)
        tone(t, f0: 1900 * k, f1: 900 * k, glide: 0.02, dur: 0.03, gain: 0.12 * g)
    }
    mutating func pop(_ t: Double, _ f: Double, _ g: Double = 1) {
        tone(t, f0: f, f1: f * 0.45, glide: 0.06, dur: 0.11, gain: 0.45 * g, attack: 0.003)
    }
    mutating func key(_ t: Double, _ k: Double = 1, _ g: Double = 1) {
        noise(t, .bandpass, freq: 1300 * k, q: 1.4, dur: 0.03, gain: 0.7 * g)
        tone(t, f0: 150 * k, f1: 110 * k, glide: 0.04, dur: 0.06, gain: 0.35 * g)
        noise(t, freq: 5000, dur: 0.006, gain: 0.25 * g)
    }
    mutating func ting(_ t: Double, _ f: Double, _ g: Double = 1) {
        tone(t, f0: f, dur: 0.7, gain: 0.22 * g, attack: 0.004)
        tone(t, f0: f * 2.01, dur: 0.3, gain: 0.06 * g, attack: 0.004)
        tone(t, f0: f * 3.98, dur: 0.12, gain: 0.03 * g)
    }
    mutating func block(_ t: Double, _ f: Double, _ g: Double = 1) {
        noise(t, .bandpass, freq: f, q: 9, dur: 0.05, gain: 0.9 * g)
        tone(t, f0: f * 1.05, f1: f, glide: 0.02, dur: 0.07, gain: 0.3 * g)
    }
    mutating func mallet(_ t: Double, _ f: Double, _ g: Double = 1) {
        tone(t, f0: f, dur: 0.45, gain: 0.32 * g, attack: 0.003)
        tone(t, f0: f * 4, dur: 0.08, gain: 0.06 * g)
    }
    mutating func blip(_ t: Double, _ f: Double, _ d: Double = 0.07, _ g: Double = 1) {
        tone(t, .square, f0: f, dur: d, gain: 0.12 * g, attack: 0.001)
    }

    mutating func compose(_ pack: Sounds.Pack, _ kind: Sounds.Kind) {
        switch (pack, kind) {
        case (.click, .start): click(0)
        case (.click, .stop): click(0); click(0.075, 1.1, 0.8)
        case (.click, .done): click(0, 1.2, 0.8); click(0.09, 1.5, 0.9)
        case (.click, .dictateOn): click(0, 0.85)
        case (.click, .dictateOff): click(0, 1.25, 0.8)
        case (.click, .error):
            noise(0, .lowpass, freq: 700, dur: 0.04, gain: 0.8)
            tone(0, f0: 230, f1: 150, glide: 0.06, dur: 0.08, gain: 0.25)

        case (.pop, .start): pop(0, 540)
        case (.pop, .stop): pop(0, 380)
        case (.pop, .done): pop(0, 520, 0.8); pop(0.1, 780)
        case (.pop, .dictateOn): pop(0, 460, 0.8)
        case (.pop, .dictateOff): pop(0, 640, 0.7)
        case (.pop, .error): pop(0, 280); pop(0.12, 240)

        case (.key, .start): key(0)
        case (.key, .stop): key(0); key(0.07, 1.25, 0.6)
        case (.key, .done): key(0, 1.1, 0.7); key(0.08, 1.3, 0.8)
        case (.key, .dictateOn): key(0, 0.9, 0.8)
        case (.key, .dictateOff): key(0, 1.2, 0.6)
        case (.key, .error): key(0, 0.6, 1.2)

        case (.glass, .start): ting(0, 1568)
        case (.glass, .stop): ting(0, 1175)
        case (.glass, .done): ting(0, 1568, 0.8); ting(0.12, 2093)
        case (.glass, .dictateOn): ting(0, 1319, 0.7)
        case (.glass, .dictateOff): ting(0, 1760, 0.6)
        case (.glass, .error): ting(0, 784); ting(0.02, 740, 0.8)

        case (.wood, .start): block(0, 1100)
        case (.wood, .stop): block(0, 780)
        case (.wood, .done): block(0, 800, 0.8); block(0.1, 1150)
        case (.wood, .dictateOn): block(0, 950, 0.8)
        case (.wood, .dictateOff): block(0, 1250, 0.7)
        case (.wood, .error): block(0, 480); block(0.11, 430)

        case (.chime, .start): mallet(0, 392); mallet(0.09, 587)
        case (.chime, .stop): mallet(0, 587); mallet(0.09, 392)
        case (.chime, .done): mallet(0, 523, 0.8); mallet(0.09, 659, 0.85); mallet(0.18, 784)
        case (.chime, .dictateOn): mallet(0, 440, 0.8)
        case (.chime, .dictateOff): mallet(0, 659, 0.7)
        case (.chime, .error): mallet(0, 330); mallet(0.12, 262)

        case (.retro, .start): blip(0, 660); blip(0.07, 990)
        case (.retro, .stop): blip(0, 990); blip(0.07, 660)
        case (.retro, .done): blip(0, 660, 0.06); blip(0.07, 880, 0.06); blip(0.14, 1320, 0.1)
        case (.retro, .dictateOn): blip(0, 880, 0.05)
        case (.retro, .dictateOff): blip(0, 1175, 0.05)
        case (.retro, .error): tone(0, .saw, f0: 220, f1: 180, glide: 0.15, dur: 0.18, gain: 0.12)
        }
    }

    // MARK: Out

    /// 16-bit mono WAV, softly limited so stacked voices never clip.
    func wav() -> NSSound? {
        let tail = [Float](repeating: 0, count: Int(0.03 * Self.rate))
        let pcm = (samples + tail).map { Int16(tanh(Double($0) * 1.2) / tanh(1.2) * 0.9 * Double(Int16.max)) }
        var data = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36 + pcm.count * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian)
        put(UInt16(1).littleEndian)
        put(UInt32(Self.rate).littleEndian)
        put(UInt32(Self.rate * 2).littleEndian)
        put(UInt16(2).littleEndian)
        put(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8))
        put(UInt32(pcm.count * 2).littleEndian)
        pcm.forEach { put($0.littleEndian) }
        return NSSound(data: data)
    }
}
