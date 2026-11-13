import Accelerate
import Foundation

// "Hey Anu" from the user's own samples (Android ADR-121), iOS form.
//
// Android turns every 80 ms of audio into one of openWakeWord's speech
// embeddings on LiteRT. The LiteRT-LM framework Anu vendors on iOS runs
// language models, not arbitrary .tflite graphs, so here each 80 ms becomes a
// log-mel vector computed with Accelerate (`LogMelFeatures`). Everything after
// the features is Android's design, ported as is: open-start dynamic time
// warping against the user's four samples, a threshold from how far the
// samples are from each other, and the enrollment checks. Nothing here keeps
// audio: the features are made and the samples dropped.

/// The audio "Hey Anu" listens to: 16 kHz mono 16-bit, in 80 ms chunks.
enum WakeAudio {
    static let rate = 16_000
    /// 80 ms: one feature vector per chunk.
    static let chunk = 1_280
}

/// Turns audio into one feature vector per `WakeAudio.chunk`, as it streams.
/// The matcher only needs vectors that are unit length (so a dot product is
/// the cosine) and comparable from one recording to the next, so any model, or
/// none, can sit behind this.
protocol WakeFeatures: AnyObject {
    /// The vector for the next chunk of `WakeAudio.chunk` samples.
    func push(_ chunk: [Int16]) -> [Float]
    /// Forgets the stream so far, for a new recording.
    func reset()
}

extension WakeFeatures {
    /// One vector per whole chunk of `audio`, from a fresh stream.
    func vectors(of audio: [Int16]) -> [[Float]] {
        reset()
        let count = audio.count / WakeAudio.chunk
        return (0..<count).map { k in
            push(Array(audio[(k * WakeAudio.chunk)..<((k + 1) * WakeAudio.chunk)]))
        }
    }
}

/// A log-mel spectrogram, one vector per 80 ms, without a model: 25 ms Hann
/// windows every 10 ms (eight per chunk, the first reaching 15 ms back into the
/// previous chunk), a 512-point FFT, 32 triangular mel bands from 60 Hz to
/// 7.6 kHz, the log of each band's energy, averaged over the chunk. Then
/// cepstral-style mean normalisation: the mean of the last `normalisationChunks`
/// vectors is taken away, which removes the room's and the microphone's
/// colouring and the loudness, and the result is made unit length.
final class LogMelFeatures: WakeFeatures {
    static let bands = 32
    static let window = 400
    static let hop = 160
    static let fftSize = 512
    /// The running mean's length: 1.04 s, about the length of "Hey Anu", so a
    /// sample's vectors are normalised much as live audio's are even when the
    /// user starts speaking soon after the recording starts.
    static let normalisationChunks = 13
    /// Added to each band's energy before the log, so silence doesn't go to
    /// minus infinity. Energies are of samples scaled to ±1; this is about
    /// -90 dBFS.
    static let energyFloor: Float = 1e-9

    private static let lookback = window - hop  // 240
    private let frames = (WakeAudio.chunk + lookback - window) / hop + 1  // 8
    private var tail = [Float](repeating: 0, count: lookback)
    private var history: [[Float]] = []
    private let hann: [Float]
    private let filters: [Float]  // bands × bins, row-major
    private let bins = fftSize / 2 + 1
    private let dft: vDSP_DFT_Setup?

    init() {
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.window, isHalfWindow: false)
        filters = Self.melFilters(bands: Self.bands, bins: Self.fftSize / 2 + 1, rate: Float(WakeAudio.rate), low: 60, high: 7_600)
        dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)
    }

    deinit {
        if let dft { vDSP_DFT_DestroySetup(dft) }
    }

    func reset() {
        tail = [Float](repeating: 0, count: Self.lookback)
        history.removeAll()
    }

    func push(_ chunk: [Int16]) -> [Float] {
        precondition(chunk.count == WakeAudio.chunk, "A chunk is \(WakeAudio.chunk) samples")
        var scaled = [Float](repeating: 0, count: chunk.count)
        vDSP.convertElements(of: chunk, to: &scaled)
        vDSP.multiply(1 / 32_768, scaled, result: &scaled)
        let audio = tail + scaled
        tail = Array(audio.suffix(Self.lookback))

        var mean = [Float](repeating: 0, count: Self.bands)
        for f in 0..<frames {
            let bands = logMel(Array(audio[(f * Self.hop)..<(f * Self.hop + Self.window)]))
            vDSP.add(mean, bands, result: &mean)
        }
        vDSP.multiply(1 / Float(frames), mean, result: &mean)

        history.append(mean)
        if history.count > Self.normalisationChunks { history.removeFirst(history.count - Self.normalisationChunks) }
        var running = [Float](repeating: 0, count: Self.bands)
        for vector in history { vDSP.add(running, vector, result: &running) }
        vDSP.multiply(1 / Float(history.count), running, result: &running)
        return WakeVector.unit(vDSP.subtract(mean, running))
    }

    /// The log energy in each mel band of one 25 ms frame.
    private func logMel(_ frame: [Float]) -> [Float] {
        var windowed = vDSP.multiply(frame, hann)
        windowed += [Float](repeating: 0, count: Self.fftSize - Self.window)
        let half = Self.fftSize / 2
        // zrop takes the even samples as the real part and the odd as the imaginary.
        var evenIn = [Float](repeating: 0, count: half)
        var oddIn = [Float](repeating: 0, count: half)
        for k in 0..<half {
            evenIn[k] = windowed[2 * k]
            oddIn[k] = windowed[2 * k + 1]
        }
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        if let dft { vDSP_DFT_Execute(dft, evenIn, oddIn, &re, &im) }
        // Packed: bin 0's real part in re[0], the Nyquist bin's in im[0].
        var power = [Float](repeating: 0, count: bins)
        power[0] = re[0] * re[0]
        power[half] = im[0] * im[0]
        for k in 1..<half { power[k] = re[k] * re[k] + im[k] * im[k] }

        var energies = [Float](repeating: 0, count: Self.bands)
        vDSP_mmul(filters, 1, power, 1, &energies, 1, vDSP_Length(Self.bands), 1, vDSP_Length(bins))
        vDSP.add(Self.energyFloor, energies, result: &energies)
        return energies.map { Foundation.log($0) }
    }

    /// HTK-style triangular mel filters, `bands` rows of `bins` weights.
    static func melFilters(bands: Int, bins: Int, rate: Float, low: Float, high: Float) -> [Float] {
        func mel(_ hz: Float) -> Float { 2_595 * log10(1 + hz / 700) }
        func hz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2_595) - 1) }
        let lowMel = mel(low)
        let highMel = mel(high)
        let edges = (0...(bands + 1)).map { hz(lowMel + (highMel - lowMel) * Float($0) / Float(bands + 1)) }
        let binHz = rate / Float((bins - 1) * 2)
        var weights = [Float](repeating: 0, count: bands * bins)
        for b in 0..<bands {
            let left = edges[b], centre = edges[b + 1], right = edges[b + 2]
            for k in 0..<bins {
                let f = Float(k) * binHz
                let w: Float
                if f > left, f <= centre { w = (f - left) / (centre - left) } else if f > centre, f < right {
                    w = (right - f) / (right - centre)
                } else { w = 0 }
                weights[b * bins + k] = w
            }
        }
        return weights
    }
}

enum WakeVector {
    /// Unit length; a zero vector stays zero.
    static func unit(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vDSP.sumOfSquares(vector))
        return norm == 0 ? vector : vDSP.divide(vector, norm)
    }
}

/// One sample of the user's "Hey Anu": its vectors from the start of speech
/// until just after it.
struct WakeTemplate: Equatable {
    /// Unit length, so a dot product is the cosine.
    let frames: [[Float]]

    init(frames: [[Float]]) { self.frames = frames.map(WakeVector.unit) }
}

/// What Anu keeps of the user's "Hey Anu": a few samples' vectors and how
/// close live audio must come to one of them. It's derived from their voice,
/// so it's stored only through `SecureFile` and never leaves the phone.
struct WakeVoice: Equatable {
    let templates: [WakeTemplate]
    let threshold: Float

    /// Bumped when the features change, so a voice taught on other features is
    /// asked for again instead of matched wrongly. Android's is 1 and holds
    /// openWakeWord embeddings; these are log-mel vectors.
    static let version: Int32 = 2

    /// Big-endian, as Android's DataOutputStream writes it: version, threshold,
    /// then each template's frames.
    func encode() -> Data {
        var out = Data()
        func int(_ value: Int32) { withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) } }
        func float(_ value: Float) { withUnsafeBytes(of: value.bitPattern.bigEndian) { out.append(contentsOf: $0) } }
        int(Self.version)
        float(threshold)
        int(Int32(templates.count))
        for template in templates {
            int(Int32(template.frames.count))
            for frame in template.frames {
                int(Int32(frame.count))
                frame.forEach(float)
            }
        }
        return out
    }

    /// Nil for bytes this version doesn't understand.
    static func decode(_ data: Data) -> WakeVoice? {
        let bytes = [UInt8](data)
        var at = 0
        func int() -> Int32? {
            guard at + 4 <= bytes.count else { return nil }
            let value = bytes[at..<(at + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            at += 4
            return Int32(bitPattern: value)
        }
        func count(_ limit: Int32) -> Int? {
            guard let value = int(), value >= 0, value <= limit else { return nil }
            return Int(value)
        }
        guard int() == version, let bits = int() else { return nil }
        let threshold = Float(bitPattern: UInt32(bitPattern: bits))
        guard threshold.isFinite, let templateCount = count(64) else { return nil }
        var templates: [WakeTemplate] = []
        for _ in 0..<templateCount {
            guard let frameCount = count(1_000) else { return nil }
            var frames: [[Float]] = []
            for _ in 0..<frameCount {
                guard let size = count(4_096) else { return nil }
                var frame: [Float] = []
                for _ in 0..<size {
                    guard let raw = int() else { return nil }
                    frame.append(Float(bitPattern: UInt32(bitPattern: raw)))
                }
                frames.append(frame)
            }
            templates.append(WakeTemplate(frames: frames))
        }
        guard at == bytes.count else { return nil }
        return WakeVoice(templates: templates, threshold: threshold)
    }
}

/// How far a template is from the end of live audio: dynamic time warping with
/// an open start, so the phrase can begin anywhere in `live` but must end at
/// its last frame, at the mean cosine distance along the best path. 0 is the
/// same sound.
enum WakeDistance {
    static func of(_ template: [[Float]], _ live: ArraySlice<[Float]>) -> Float {
        let live = Array(live)
        let rows = template.count
        let cols = live.count
        if rows == 0 || cols == 0 { return .greatestFiniteMagnitude }
        // Cost so far and steps so far, a row at a time. Each step picks the
        // predecessor with the lowest mean.
        var cost = [Float](repeating: 0, count: cols)
        var steps = [Int](repeating: 0, count: cols)
        var nextCost = [Float](repeating: 0, count: cols)
        var nextSteps = [Int](repeating: 0, count: cols)
        for j in 0..<cols {
            cost[j] = distance(template[0], live[j])
            steps[j] = 1
        }
        for i in 1..<rows {
            for j in 0..<cols {
                var best = cost[j]
                var n = steps[j]
                if j > 0 {
                    if cost[j - 1] / Float(steps[j - 1]) < best / Float(n) {
                        best = cost[j - 1]
                        n = steps[j - 1]
                    }
                    if nextCost[j - 1] / Float(nextSteps[j - 1]) < best / Float(n) {
                        best = nextCost[j - 1]
                        n = nextSteps[j - 1]
                    }
                }
                nextCost[j] = best + distance(template[i], live[j])
                nextSteps[j] = n + 1
            }
            swap(&cost, &nextCost)
            swap(&steps, &nextSteps)
        }
        return cost[cols - 1] / Float(steps[cols - 1])
    }

    static func of(_ template: [[Float]], _ live: [[Float]]) -> Float { of(template, live[...]) }

    /// Both are unit length.
    private static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 1 }
        return 1 - vDSP.dot(a, b)
    }
}

/// Matches live vectors against the user's samples. `push` takes each new
/// vector and returns the best distance to any sample, ending at it. Each
/// sample is compared with up to twice its length of the latest audio, so a
/// slower "Hey Anu" still fits.
struct WakeMatcher {
    let voice: WakeVoice
    private let longest: Int
    private var recent: [[Float]] = []

    init(voice: WakeVoice) {
        self.voice = voice
        longest = voice.templates.map(\.frames.count).max() ?? 0
    }

    mutating func push(_ vector: [Float]) -> Float {
        recent.append(WakeVector.unit(vector))
        if recent.count > longest * 2 { recent.removeFirst(recent.count - longest * 2) }
        var best = Float.greatestFiniteMagnitude
        for template in voice.templates {
            let size = template.frames.count
            let window = min(size * 2, recent.count)
            if window < (size + 1) / 2 { continue }
            best = min(best, WakeDistance.of(template.frames, recent[(recent.count - window)...]))
        }
        return best
    }

    mutating func reset() { recent.removeAll() }
}

/// When a run of distances is a wake, as Android's WakeDetector decides it: a
/// distance under the threshold starts a match, which fires at its closest
/// point, at most `settleChunks` chunks later, so the whole phrase is in.
/// Distances under `near` × the threshold that don't wake are near misses, for
/// debug logs (never audio).
struct WakeTrigger {
    enum Event: Equatable {
        case woke(Float)
        case nearMiss(Float)
    }

    let threshold: Float
    var settleChunks = 3
    var near: Float = 1.5

    private var best = Float.greatestFiniteMagnitude
    private var since = -1
    private var nearest = Float.greatestFiniteMagnitude

    init(threshold: Float, settleChunks: Int = 3) {
        self.threshold = threshold
        self.settleChunks = settleChunks
    }

    mutating func push(_ distance: Float) -> Event? {
        if since >= 0 {
            since += 1
            // Android updates `best` before comparing, so it always fires on
            // the next chunk; this waits while the distance still falls.
            if distance < best {
                best = distance
                if since < settleChunks { return nil }
            }
            let woke = best
            reset()
            return .woke(woke)
        }
        if distance < threshold {
            best = distance
            since = 0
        } else if distance < threshold * near {
            nearest = min(nearest, distance)
        } else if nearest < .greatestFiniteMagnitude {
            let miss = nearest
            nearest = .greatestFiniteMagnitude
            return .nearMiss(miss)
        }
        return nil
    }

    mutating func reset() {
        best = .greatestFiniteMagnitude
        since = -1
        nearest = .greatestFiniteMagnitude
    }
}

/// Teaching "Hey Anu" the user's voice. A recording becomes a `WakeTemplate`
/// from where its speech is; the samples' distances from each other set how
/// close live audio must come.
///
/// Android's distance constants (0.2, 0.055 to 0.085) were measured on
/// openWakeWord's embeddings, whose 0.76 s windows make neighbouring frames
/// alike and distances small. Log-mel vectors of 80 ms are far more local:
/// samples spread further from each other, while live audio, matched with an
/// open start against up to twice a sample's length, comes much closer to
/// its nearest sample than the samples are to each other. The values below were picked from
/// distances measured on synthetic, speech-like test audio (harmonic voices
/// with moving formants, `WakeVoiceTests`): they are starting points to be
/// tuned on a device with real voices.
enum WakeEnrollment {
    /// How many samples make a voice.
    static let samples = 4

    /// A sample further than this on average from the others is asked for
    /// again. To be tuned on a device. On five synthetic voices, a "Hey Anu"
    /// said again (±10 % speed, ±4 % pitch, -18 to -24 dBFS, noise) was
    /// 0.064 to 0.188 on average from the samples before it; "Good morning"
    /// in the same voice was 0.385 to 0.483. (Android: 0.2, on embeddings.)
    static let tooDifferent: Float = 0.25

    /// Live audio must come closer to its nearest sample than this share of
    /// the furthest two samples are from each other, within `minThreshold`
    /// and `maxThreshold`. To be tuned on a device. On the synthetic voices
    /// the samples' furthest pair was 0.124 to 0.221 apart; live, a held-out
    /// "Hey Anu" came to 0.017 to 0.097 of its nearest sample, typically a
    /// third of that spread, and the closest look-alike ("Hey Andrew", which
    /// differs only by an "r") to 0.051 to 0.110, about half of it; "Hey
    /// Siri" stayed above 0.23. So 0.4 × the spread, from 0.045 to 0.09.
    /// (Android: 0.8 ×, 0.055 to 0.085, on embeddings.)
    static let margin: Float = 0.4
    static let minThreshold: Float = 0.045
    static let maxThreshold: Float = 0.09

    /// Quieter than about -40 dBFS at its loudest is too quiet to learn from.
    private static let minPeakRMS = 300.0
    private static let frame = 160
    private static let minSpeechMs = 250
    private static let maxSpeechMs = 2_000
    /// 300 ms: longer than the pause between "Hey" and "Anu".
    private static let gapFrames = 30

    enum Sample: Equatable {
        case learned(WakeTemplate)
        case again(String)
    }

    static let quietMessage = "Didn’t hear you. Say “Hey Anu” a little louder."
    static let shortMessage = "That was very short. Say “Hey Anu” again."
    static let longMessage = "There’s other sound around you. Say just “Hey Anu”, close to the phone."
    static let differentMessage = "That sounded different from the others. Say “Hey Anu” as you did before."

    /// The sample in `audio`, given the vectors `WakeFeatures` made of it from
    /// its first sample, one per chunk: those whose chunk is at least half in
    /// the speech. (Android keeps embeddings ending from 0.2 s into the speech
    /// to 0.16 s after it, because each covers the 0.76 s before it; a log-mel
    /// vector covers only its own 80 ms.)
    static func sample(_ audio: [Int16], vectors: [[Float]]) -> Sample {
        guard let span = speech(audio) else { return .again(quietMessage) }
        let millis = span.count * 1_000 / WakeAudio.rate
        if millis < minSpeechMs { return .again(shortMessage) }
        if millis > maxSpeechMs { return .again(longMessage) }
        let frames = vectors.enumerated().filter { k, _ in
            let middle = k * WakeAudio.chunk + WakeAudio.chunk / 2
            return span.contains(middle)
        }.map(\.element)
        if frames.count < 2 { return .again(shortMessage) }
        return .learned(WakeTemplate(frames: frames))
    }

    /// Whether `template` sounds like the samples already kept; the first
    /// always does.
    static func fits(_ template: WakeTemplate, kept: [WakeTemplate]) -> Bool {
        if kept.isEmpty { return true }
        let mean = kept.map { distance(template, $0) }.reduce(0, +) / Float(kept.count)
        return mean <= tooDifferent
    }

    static func voice(_ templates: [WakeTemplate]) -> WakeVoice {
        var furthest: Float = 0
        for (i, a) in templates.enumerated() {
            for (j, b) in templates.enumerated() where i != j {
                furthest = max(furthest, WakeDistance.of(a.frames, b.frames))
            }
        }
        return WakeVoice(templates: templates, threshold: min(max(furthest * margin, minThreshold), maxThreshold))
    }

    /// The larger of the two directions, since an open start isn't symmetric.
    static func distance(_ a: WakeTemplate, _ b: WakeTemplate) -> Float {
        max(WakeDistance.of(a.frames, b.frames), WakeDistance.of(b.frames, a.frames))
    }

    /// The samples of the loudest burst, out to where it falls quiet for
    /// 300 ms, or nil if nothing was loud enough.
    static func speech(_ audio: [Int16]) -> Range<Int>? {
        let count = audio.count / frame
        if count == 0 { return nil }
        let rms: [Double] = (0..<count).map { f in
            var sum = 0.0
            for i in (f * frame)..<((f + 1) * frame) { sum += Double(audio[i]) * Double(audio[i]) }
            return (sum / Double(frame)).squareRoot()
        }
        guard let peak = rms.max(), let top = rms.indices.max(by: { rms[$0] < rms[$1] }) else { return nil }
        // The room's own sound: the quietest fifth of the recording. Speech
        // must stand 12 dB above it.
        let floor = rms.sorted()[count / 5]
        if peak < max(minPeakRMS, floor * 4) { return nil }
        // Out to where it falls quiet, so other voices before or after it are left out.
        let loud = max(peak / 10, floor * 2)
        var first = top
        var quiet = 0
        for f in stride(from: top - 1, through: 0, by: -1) {
            if rms[f] > loud {
                first = f
                quiet = 0
            } else {
                quiet += 1
                if quiet >= gapFrames { break }
            }
        }
        var last = top
        quiet = 0
        for f in (top + 1)..<count {
            if rms[f] > loud {
                last = f
                quiet = 0
            } else {
                quiet += 1
                if quiet >= gapFrames { break }
            }
        }
        return (first * frame)..<((last + 1) * frame)
    }

    /// Whether a sample's recording can end: speech was heard, then
    /// `quietChunks` chunks in a row were quiet, both measured from the
    /// quietest chunk so far, so a noisy room still ends. `levels` are each
    /// chunk's `level`, from 0 to 1, where 0.1 is 6 dB.
    static func ended(_ levels: [Float], quietChunks: Int = 8) -> Bool {
        guard let floor = levels.min() else { return false }
        guard let loud = levels.firstIndex(where: { $0 >= max(minSpeechLevel, floor + 0.2) }),
              levels.count - loud > quietChunks else { return false }
        return levels.suffix(quietChunks).allSatisfy { $0 < floor + 0.1 }
    }

    /// About -39 dBFS on `level`'s scale.
    private static let minSpeechLevel: Float = 0.35

    /// How loud a chunk of 16-bit audio is, from 0 (-60 dBFS or quieter) to
    /// 1 (full scale).
    static func level(_ samples: [Int16]) -> Float {
        if samples.isEmpty { return 0 }
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        if rms < 1 { return 0 }
        return Float(min(max((20 * log10(rms / 32_768) + 60) / 60, 0), 1))
    }
}

/// Collects a sample's recording and says when it can stop. Pure, so the
/// enrollment sheet's recorder only feeds it chunks.
struct WakeSampleTake {
    /// 4 s: long enough to start late and say it slowly.
    static let maxChunks = 50

    private(set) var audio: [Int16] = []
    private(set) var levels: [Float] = []

    /// Adds a chunk and says whether the recording is done.
    mutating func add(_ chunk: [Int16]) -> Bool {
        audio += chunk
        levels.append(WakeEnrollment.level(chunk))
        return levels.count >= Self.maxChunks || WakeEnrollment.ended(levels)
    }
}

/// The four samples being taught, and what to tell the user after each.
struct WakeEnrollmentSession {
    private(set) var kept: [WakeTemplate] = []

    enum Outcome: Equatable {
        case kept(Int)
        case again(String)
    }

    var isComplete: Bool { kept.count >= WakeEnrollment.samples }

    /// Checks one recording and keeps it if it's a good sample.
    mutating func take(_ audio: [Int16], features: WakeFeatures) -> Outcome {
        switch WakeEnrollment.sample(audio, vectors: features.vectors(of: audio)) {
        case .again(let reason):
            return .again(reason)
        case .learned(let template):
            guard WakeEnrollment.fits(template, kept: kept) else { return .again(WakeEnrollment.differentMessage) }
            kept.append(template)
            return .kept(kept.count)
        }
    }

    /// The voice, once all samples are in.
    func voice() -> WakeVoice? { isComplete ? WakeEnrollment.voice(Array(kept.prefix(WakeEnrollment.samples))) : nil }
}
