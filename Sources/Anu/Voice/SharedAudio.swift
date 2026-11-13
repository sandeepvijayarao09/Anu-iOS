import Foundation
import Security
import CryptoKit
#if canImport(AVFoundation)
import AVFoundation
#endif

// Compiled into the app AND the share extension (SHARE_SHARED_FILES), so a
// recording shared into Anu is decoded, sealed and handed over without the
// extension needing anything else from the app.

/// A voice note's audio: mono 16-bit little-endian PCM, in memory. Written to
/// disk only through `SecureFile`, and only until it has been written down.
struct VoiceRecording: Codable, Equatable, Sendable {
    static let speechRate = 16_000
    /// Voice notes are at most five minutes (Android ADR-078).
    static let maxSeconds = 300

    var id = UUID()
    var pcm: Data
    var sampleRate: Int = VoiceRecording.speechRate
    /// Ended by a call, Siri, or the user leaving Anu, rather than by Stop.
    var interrupted = false
    /// Shared from another app, so it can hold other people's words.
    var shared = false

    var sampleCount: Int { pcm.count / 2 }
    var seconds: Int { sampleRate > 0 ? Int((Double(sampleCount) / Double(sampleRate)).rounded()) : 0 }
    var wav: Data { WAV.encode(pcm: pcm, sampleRate: sampleRate) }

    /// The samples as integers.
    var samples: [Int16] {
        var out = [Int16](repeating: 0, count: sampleCount)
        _ = out.withUnsafeMutableBytes { pcm.prefix(sampleCount * 2).copyBytes(to: $0) }
        return out.map { Int16(littleEndian: $0) }
    }

    static func pcmData(_ samples: [Int16]) -> Data {
        var little = samples.map { $0.littleEndian }
        return Data(bytes: &little, count: little.count * 2)
    }
}

/// The minimal RIFF/WAVE container the speech models take.
enum WAV {
    static func encode(pcm: Data, sampleRate: Int, channels: Int = 1) -> Data {
        var out = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 2)) }
        out.append(Data("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        out.append(Data("data".utf8)); u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }

    /// The PCM and rate of a mono 16-bit WAV, or nil.
    static func decode(_ data: Data) -> (pcm: Data, sampleRate: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 44, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        var at = 12
        var rate: Int?
        while at + 8 <= bytes.count {
            let id = String(bytes: bytes[at..<at + 4], encoding: .ascii)
            let size = u32(at + 4)
            if id == "fmt " {
                guard u16(at + 8) == 1, u16(at + 10) == 1, u16(at + 22) == 16 else { return nil }
                rate = u32(at + 12)
            } else if id == "data", let rate {
                let end = min(bytes.count, at + 8 + size)
                return (Data(bytes[(at + 8)..<end]), rate)
            }
            at += 8 + size + (size % 2)
        }
        return nil
    }
}

/// The data key for files the share extension hands to the app. It lives in
/// the App Group's keychain access group so both processes can use it; the
/// app's own data key stays private to the app.
final class AppGroupDataKey: DataKeyProviding, @unchecked Sendable {
    static let shared = AppGroupDataKey()

    private let service = "com.anu.app.shared"
    private let account = "shared-audio.key"
    private let lock = NSLock()
    private var cached: SymmetricKey?
    private var unavailable = false

    func dataKey() throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if unavailable { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppGroup.id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            cached = SymmetricKey(data: data)
            return cached
        }
        guard status == errSecItemNotFound else {
            // No keychain group in this build (unsigned, tests): the file
            // keeps file protection only, as SecureFile does for the app.
            unavailable = true
            return nil
        }
        let key = SymmetricKey(size: .bits256)
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { unavailable = true; return nil }
        cached = key
        return key
    }
}

/// A recording shared into Anu, waiting in the App Group for the app.
struct SharedVoiceNote: Codable, Equatable {
    var recording: VoiceRecording?
    /// Set instead of `recording` when the shared audio was longer than a
    /// voice note may be, so the app can say why nothing arrived.
    var tooLongSeconds: Int?
    /// Set when the shared file couldn't be decoded.
    var unreadable = false
}

/// The hand-off folder: the extension drops, the app drains.
struct SharedVoiceNoteDrop {
    let directory: URL
    let keys: DataKeyProviding

    init(directory: URL = AppGroup.containerURL.appendingPathComponent("SharedVoiceNotes", isDirectory: true),
         keys: DataKeyProviding = AppGroupDataKey.shared) {
        self.directory = directory
        self.keys = keys
    }

    func drop(_ note: SharedVoiceNote) throws {
        let data = try PropertyListEncoder().encode(note)
        try SecureFile.write(data, to: directory.appendingPathComponent("\(UUID().uuidString).anuaudio"), keys: keys)
    }

    /// Everything waiting, oldest first. Each file is removed once read.
    func drain() -> [SharedVoiceNote] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let sorted = files.filter { $0.pathExtension == "anuaudio" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        return sorted.compactMap { url in
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = SecureFile.read(url, keys: keys) else { return nil }
            return try? PropertyListDecoder().decode(SharedVoiceNote.self, from: data)
        }
    }
}

#if canImport(AVFoundation)
/// Decodes a shared audio file (AAC, MP3, WAV, CAF…) to mono 16 kHz PCM, in
/// one-second pieces so a share extension stays inside its memory limit. One
/// longer than a voice note may be is refused before it is decoded.
enum SharedAudioDecoder {
    static func decode(_ url: URL, maxSeconds: Int = VoiceRecording.maxSeconds) -> SharedVoiceNote {
        guard let file = try? AVAudioFile(forReading: url) else { return SharedVoiceNote(unreadable: true) }
        let input = file.processingFormat
        let seconds = Int((Double(file.length) / input.sampleRate).rounded())
        if seconds > maxSeconds { return SharedVoiceNote(tooLongSeconds: seconds) }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceRecording.speechRate),
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else {
            return SharedVoiceNote(unreadable: true)
        }
        let chunk = AVAudioFrameCount(input.sampleRate)
        var pcm = Data()
        var finished = false
        while !finished {
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else { break }
            do { try file.read(into: inBuffer, frameCount: chunk) } catch { break }
            if inBuffer.frameLength == 0 { break }
            if file.framePosition >= file.length { finished = true }
            let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * output.sampleRate / input.sampleRate) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { break }
            var fed = false
            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return inBuffer
            }
            if error != nil { break }
            if let channel = outBuffer.int16ChannelData?[0] {
                pcm.append(Data(bytes: channel, count: Int(outBuffer.frameLength) * 2))
            }
        }
        guard !pcm.isEmpty else { return SharedVoiceNote(unreadable: true) }
        return SharedVoiceNote(recording: VoiceRecording(pcm: pcm, shared: true))
    }
}
#endif
