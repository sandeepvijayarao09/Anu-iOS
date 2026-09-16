import Foundation
import LiteRTLM

guard CommandLine.arguments.count > 1 else {
  FileHandle.standardError.write(Data("usage: lrtbench <model.litertlm> [prefillTokens] [decodeTokens]\n".utf8))
  exit(1)
}
let modelPath = CommandLine.arguments[1]
let prefill = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 256 : 256
let decode = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 256 : 256

do {
  print("Loading \(modelPath) on GPU and benchmarking (prefill=\(prefill), decode=\(decode))…")
  let info = try await benchmark(
    modelPath: modelPath,
    backend: .gpu,
    prefillTokens: prefill,
    decodeTokens: decode,
    cacheDir: NSTemporaryDirectory()
  )
  print("=== LiteRT-LM · Gemma 4 E4B · Metal GPU ===")
  print(String(format: "init time:   %.2f s", info.initTimeInSecond))
  print(String(format: "TTFT:        %.3f s", info.timeToFirstTokenInSecond))
  print(String(format: "prefill:     %.1f tok/s   (%d tokens)", info.lastPrefillTokensPerSecond, info.lastPrefillTokenCount))
  print(String(format: "decode:      %.1f tok/s   (%d tokens)", info.lastDecodeTokensPerSecond, info.lastDecodeTokenCount))
} catch {
  FileHandle.standardError.write(Data("benchmark failed: \(error)\n".utf8))
  exit(2)
}
