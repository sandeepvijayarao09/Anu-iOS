import Foundation
import JavaScriptCore
import os

/// Runs a skill's JavaScript in a bare JavaScriptCore context (ADR-120's
/// `run_js`, adapted to iOS). What the script gets:
/// - **No network and no files.** A plain `JSContext` has no `fetch`,
///   `XMLHttpRequest`, `WebSocket`, `require`, timers or DOM, and Anu exposes
///   no native objects to it. The only thing passed in is the data, as a
///   string argument, never as code.
/// - **Limits.** The script and the data have a maximum size; the result is
///   cut to `maxResultCharacters`. A CPU-time limit stops runaway loops inside
///   the engine, and a wall-clock timeout ends the call either way.
///
/// The entry point is Gallery's `ai_edge_gallery_get_result(data)` or a plain
/// `run(data)`. It may return a string, any JSON value, or a Promise of one.
struct JSSandbox: Sendable {
    struct Limits: Sendable {
        var maxScriptBytes = SkillLibrary.maxScriptBytes
        var maxDataCharacters = 4_000
        var maxResultCharacters = 4_000
        /// CPU time inside the engine, enforced by JavaScriptCore.
        var cpuSeconds: Double = 2
        /// The whole call, enforced here.
        var wallTimeout: Duration = .seconds(5)
    }

    enum Failure: LocalizedError, Equatable {
        case scriptTooLarge(Int)
        case dataTooLarge(Int)
        case noEntryPoint
        case exception(String)
        case timedOut
        case unsettled

        var errorDescription: String? {
            switch self {
            case .scriptTooLarge(let limit): return "the script is larger than \(limit / 1000) KB"
            case .dataTooLarge(let limit): return "the data is longer than \(limit) characters"
            case .noEntryPoint: return "the script defines no ai_edge_gallery_get_result(data) or run(data) function"
            case .exception(let message): return "the script failed: \(message)"
            case .timedOut: return "the script took too long and was stopped"
            case .unsettled: return "the script's promise never finished"
            }
        }
    }

    static let entryPoints = ["ai_edge_gallery_get_result", "run"]

    var limits = Limits()

    /// Whether this build can cap the engine's CPU time. Without it the wall
    /// clock still ends the call, but a runaway loop keeps its thread busy.
    static var enforcesCPULimit: Bool { setTimeLimit != nil }

    func run(script: String, data: String) async throws -> String {
        guard script.utf8.count <= limits.maxScriptBytes else { throw Failure.scriptTooLarge(limits.maxScriptBytes) }
        guard data.count <= limits.maxDataCharacters else { throw Failure.dataTooLarge(limits.maxDataCharacters) }

        let once = Once()
        let limits = self.limits
        return try await withCheckedThrowingContinuation { continuation in
            // A thread of its own: JavaScriptCore runs synchronously, and a
            // long script must not hold a cooperative-pool thread.
            let thread = Thread {
                let result = Self.evaluate(script: script, data: data, limits: limits)
                if once.claim() { continuation.resume(with: result) }
            }
            thread.name = "anu.skill.js"
            thread.start()
            Task {
                try? await Task.sleep(for: limits.wallTimeout)
                if once.claim() { continuation.resume(throwing: Failure.timedOut) }
            }
        }
    }

    // MARK: - Engine

    private static func evaluate(script: String, data: String, limits: Limits) -> Result<String, Error> {
        let group = JSContextGroupCreate()
        defer { JSContextGroupRelease(group) }
        if let setTimeLimit, let group {
            // A nil callback means: terminate unconditionally at the limit.
            setTimeLimit(group, limits.cpuSeconds, nil, nil)
        }
        guard let global = JSGlobalContextCreateInGroup(group, nil) else {
            return .failure(Failure.exception("the engine didn't start"))
        }
        defer { JSGlobalContextRelease(global) }
        guard let context = JSContext(jsGlobalContextRef: global) else {
            return .failure(Failure.exception("the engine didn't start"))
        }
        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "unknown error"
        }

        context.evaluateScript(script)
        if let thrown { return .failure(classify(thrown)) }

        guard let entry = entryPoints.first(where: {
            context.evaluateScript("typeof \($0)")?.toString() == "function"
        }), let function = context.objectForKeyedSubscript(entry) else {
            return .failure(Failure.noEntryPoint)
        }

        let returned = function.call(withArguments: [data])
        if let thrown { return .failure(classify(thrown)) }
        guard let returned else { return .failure(Failure.exception("no result")) }

        // A Promise: its jobs run when the call above returns to the engine's
        // outermost level, so by the time `then` returns it has settled — or it
        // never will, since a sandbox has no timers or I/O to wait on.
        if isThenable(returned, in: context) {
            var settled: Result<String, Error>?
            let fulfilled: @convention(block) (JSValue?) -> Void = { value in
                settled = .success(text(of: value, in: context))
            }
            let rejected: @convention(block) (JSValue?) -> Void = { reason in
                settled = .failure(Failure.exception(reason?.toString() ?? "rejected"))
            }
            returned.invokeMethod("then", withArguments: [
                JSValue(object: fulfilled, in: context) as Any,
                JSValue(object: rejected, in: context) as Any,
            ])
            if let thrown { return .failure(classify(thrown)) }
            guard let settled else { return .failure(Failure.unsettled) }
            return settled.map { clip($0, limits) }
        }
        return .success(clip(text(of: returned, in: context), limits))
    }

    private static func isThenable(_ value: JSValue, in context: JSContext) -> Bool {
        guard value.isObject,
              let check = context.evaluateScript("(function (v) { return typeof v.then === 'function'; })")
        else { return false }
        return check.call(withArguments: [value])?.toBool() ?? false
    }

    /// A string as itself; anything else as JSON; undefined and null as "".
    private static func text(of value: JSValue?, in context: JSContext) -> String {
        guard let value, !value.isUndefined, !value.isNull else { return "" }
        if value.isString { return value.toString() }
        if let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value]),
           json.isString {
            return json.toString()
        }
        return value.toString() ?? ""
    }

    private static func clip(_ text: String, _ limits: Limits) -> String {
        text.count > limits.maxResultCharacters ? String(text.prefix(limits.maxResultCharacters)) + "…" : text
    }

    /// JavaScriptCore reports a CPU-limit stop as an exception.
    private static func classify(_ message: String) -> Failure {
        message.localizedCaseInsensitiveContains("execution terminated") ? .timedOut : .exception(message)
    }

    // MARK: - CPU limit

    private typealias SetTimeLimit = @convention(c) (
        JSContextGroupRef, Double, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void

    /// `JSContextGroupSetExecutionTimeLimit`, which JavaScriptCore exports but
    /// declares only in its private header, looked up at run time.
    /// DEBUG builds only: App Review rejects private API use (guideline
    /// 2.5.1), so release builds rely on the wall-clock timeout alone (a
    /// runaway script then keeps its background thread busy until it ends).
    private static let setTimeLimit: SetTimeLimit? = {
        #if DEBUG
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetTimeLimit.self)
        #else
        return nil
        #endif
    }()

    /// Resumes a continuation exactly once.
    private final class Once: Sendable {
        private let claimed = OSAllocatedUnfairLock(initialState: false)
        func claim() -> Bool {
            claimed.withLock { done in
                if done { return false }
                done = true
                return true
            }
        }
    }
}
