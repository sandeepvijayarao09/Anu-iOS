import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Settings → Voice: the voice Anu speaks with. Lists the installed voices for
/// the user's language, best first, each with a sample; "Automatic" lets Anu
/// pick (VoicePick). Better voices are a free download in iOS Settings, which
/// apps can't start themselves, so the footer says where.
struct VoicePickerView: View {
    @AppStorage(SpeechSynthesizer.voiceKey) private var chosen = ""
    @State private var voices: [TTSVoiceCandidate] = []
    #if canImport(AVFoundation)
    @State private var sampler = AVSpeechSynthesizer()
    #endif

    var body: some View {
        List {
            Section {
                row(title: "Automatic", detail: automaticDetail, id: "")
            } footer: {
                Text("Anu picks the most natural voice installed.")
            }
            Section {
                ForEach(voices, id: \.identifier) { voice in
                    row(title: voice.name, detail: detail(voice), id: voice.identifier)
                }
            } header: {
                Text("Installed voices")
            } footer: {
                Text("For a much more natural voice, download one for free: iOS Settings → Accessibility → Read & Speak → Voices → English, then pick a Premium or Enhanced voice such as Ava or Zoe. It shows up here once it's downloaded.")
            }
        }
        .navigationTitle("Voice")
        .onAppear { voices = SpeechSynthesizer.choosableVoices() }
        .onDisappear { stopSample() }
    }

    private var automaticDetail: String {
        voices.first.map { "Now: \($0.name)" } ?? ""
    }

    private func detail(_ voice: TTSVoiceCandidate) -> String {
        let quality = voice.quality >= 3 ? "Premium" : voice.quality == 2 ? "Enhanced" : voice.isSiri ? "Siri" : voice.isRobotic ? "Classic" : "Standard"
        return voice.country.isEmpty ? quality : "\(quality) · \(voice.country)"
    }

    private func row(title: String, detail: String, id: String) -> some View {
        Button {
            chosen = id
            sample(id.isEmpty ? voices.first?.identifier : id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if chosen == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id.isEmpty ? "voiceAutomatic" : "voice_\(title)")
    }

    /// Says a line in the voice, so the user can hear it before keeping it.
    private func sample(_ identifier: String?) {
        #if canImport(AVFoundation)
        stopSample()
        guard let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) else { return }
        let line = AVSpeechUtterance(string: "Hi, I'm Anu. This is how I'll sound.")
        line.voice = voice
        line.rate = AVSpeechUtteranceDefaultSpeechRate
        sampler.speak(line)
        #endif
    }

    private func stopSample() {
        #if canImport(AVFoundation)
        if sampler.isSpeaking { sampler.stopSpeaking(at: .immediate) }
        #endif
    }
}
