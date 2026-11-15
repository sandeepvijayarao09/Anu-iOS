import Foundation

/// Speech-like test audio for "Hey Anu" from the user's samples: a voice is a
/// harmonic source (with vibrato-free pitch that glides) through moving
/// formant resonances, and noise for "h" and "s". It's no real voice, but it
/// has what the features see: a spectral envelope that moves over time, a
/// pitch, pauses and loudness. Deterministic: the same seed gives the same
/// samples.
struct SyntheticSpeech {
    /// One sound: formants (Hz) glide from `from` to `to` over its duration.
    struct Segment {
        var ms: Double
        var from: [Double]
        var to: [Double]
        var gain: Double = 1
        /// Noise instead of a pitched voice ("h", "s").
        var noise = false
        /// A pause.
        var silent = false

        static func vowel(_ ms: Double, _ from: [Double], _ to: [Double]? = nil, gain: Double = 1) -> Segment {
            Segment(ms: ms, from: from, to: to ?? from, gain: gain)
        }
        static func hiss(_ ms: Double, _ formants: [Double], gain: Double = 0.25) -> Segment {
            Segment(ms: ms, from: formants, to: formants, gain: gain, noise: true)
        }
        static func gap(_ ms: Double) -> Segment { Segment(ms: ms, from: [], to: [], silent: true) }
    }

    /// Who is speaking, and how this take differs from the others.
    struct Voice {
        var pitch: Double = 125
        /// Scales every formant (a longer or shorter vocal tract).
        var tract: Double = 1
        var speed: Double = 1
        /// dBFS of the loudest vowel, roughly.
        var level: Double = -18
        /// Background noise, dBFS; nil for none.
        var noise: Double? = -60
        var seed: UInt64 = 1
    }

    // Formants of the sounds used (an adult male voice, Hz).
    static let ey1 = [530.0, 1_840, 2_480], ey2 = [390.0, 2_300, 2_900]
    static let ah = [730.0, 1_090, 2_440], oo = [300.0, 870, 2_240]
    static let nn = [250.0, 1_700, 2_600], ee = [270.0, 2_290, 3_010]
    static let rr = [310.0, 1_060, 1_380], eh = [530.0, 1_840, 2_480]
    static let aw = [570.0, 840, 2_410], ih = [390.0, 1_990, 2_550]
    static let hh = [1_500.0, 2_500, 3_500], ss = [4_500.0, 5_500, 6_500]

    static let heyAnu: [Segment] = [
        .hiss(60, hh), .vowel(200, ey1, ey2), .gap(70),
        .vowel(140, ah), .vowel(70, nn, gain: 0.45), .vowel(210, oo),
    ]
    static let heyAndrew: [Segment] = [
        .hiss(60, hh), .vowel(200, ey1, ey2), .gap(70),
        .vowel(140, ah), .vowel(60, nn, gain: 0.45), .gap(30), .vowel(80, rr, gain: 0.7), .vowel(200, oo),
    ]
    static let heySiri: [Segment] = [
        .hiss(60, hh), .vowel(200, ey1, ey2), .gap(70),
        .hiss(120, ss, gain: 0.3), .vowel(130, ee), .vowel(70, rr, gain: 0.7), .vowel(150, ee),
    ]
    static let aNewMessage: [Segment] = [
        .vowel(110, ah), .vowel(60, nn, gain: 0.45), .vowel(150, ee, oo), .gap(40),
        .vowel(60, nn, gain: 0.45), .vowel(140, eh), .hiss(110, ss, gain: 0.3), .vowel(130, ih), .gap(60),
    ]
    static let goodMorning: [Segment] = [
        .gap(40), .vowel(160, oo, ih), .gap(50), .vowel(60, nn, gain: 0.45), .vowel(190, aw, rr),
        .vowel(60, nn, gain: 0.45), .vowel(150, ih, ee), .vowel(60, nn, gain: 0.45),
    ]

    /// The take, with `leadMs` of the background before it and `trailMs` after.
    static func say(_ segments: [Segment], voice: Voice, leadMs: Double = 500, trailMs: Double = 700) -> [Int16] {
        let rate = 16_000.0
        var random = Random(seed: voice.seed)
        var out: [Double] = Array(repeating: 0, count: Int(leadMs / 1_000 * rate))
        var phase = 0.0
        let total = segments.reduce(0) { $0 + $1.ms }
        var elapsed = 0.0
        var lowpass = 0.0
        for segment in segments {
            let count = Int(segment.ms / voice.speed / 1_000 * rate)
            for n in 0..<count {
                let t = count > 1 ? Double(n) / Double(count - 1) : 0
                let progress = (elapsed + segment.ms * t) / total
                // A falling, then rising pitch contour, as a question-less "Hey Anu".
                let f0 = voice.pitch * (1.08 - 0.16 * progress + 0.06 * sin(progress * .pi))
                phase += 2 * .pi * f0 / rate
                // 10 ms ramps, so segments don't click.
                let ramp = min(1, Double(n) / 160, Double(count - n) / 160)
                if segment.silent { out.append(0); continue }
                let formants = zip(segment.from, segment.to).map { ($0 + ($1 - $0) * t) * voice.tract }
                var value = 0.0
                if segment.noise {
                    // Noise through the formants, roughly: white noise, then the
                    // envelope of its formant band via a resonator bank's weight.
                    let white = random.gaussian()
                    lowpass += 0.6 * (white - lowpass)
                    value = (formants.first ?? 0) > 3_000 ? white - lowpass : white
                    value *= 0.5
                } else {
                    var harmonic = 1
                    while Double(harmonic) * f0 < 7_000 {
                        let f = Double(harmonic) * f0
                        var weight = 0.0
                        for (k, formant) in formants.enumerated() {
                            let width = 60.0 + 30 * Double(k)
                            weight += exp(-pow((f - formant) / width, 2) / 2) / Double(k + 1)
                        }
                        // The glottal source falls 12 dB an octave.
                        weight *= 1 / Double(harmonic) + 0.02
                        value += weight * sin(Double(harmonic) * phase)
                        harmonic += 1
                    }
                }
                out.append(value * segment.gain * ramp)
            }
            elapsed += segment.ms
        }
        out += Array(repeating: 0, count: Int(trailMs / 1_000 * rate))
        // Scale the loudest 10 ms to the voice's level, then add the room.
        var peak = 1e-9
        for start in stride(from: 0, to: out.count - 160, by: 160) {
            let rms = (out[start..<(start + 160)].reduce(0) { $0 + $1 * $1 } / 160).squareRoot()
            peak = max(peak, rms)
        }
        let scale = pow(10, voice.level / 20) * 32_768 / peak
        let noise = voice.noise.map { pow(10, $0 / 20) * 32_768 } ?? 0
        return out.map { sample in
            let value = sample * scale + noise * random.gaussian()
            return Int16(max(-32_768, min(32_767, value.rounded())))
        }
    }

    /// Repeatable gaussian noise (SplitMix64 and Box–Muller).
    struct Random {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(next(), 1e-12)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * next())
        }
    }
}
