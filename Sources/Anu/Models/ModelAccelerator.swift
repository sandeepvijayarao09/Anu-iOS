import Foundation

/// Where Gemma runs (AI Edge Gallery's accelerator choice): the GPU is
/// fastest; the CPU leaves the GPU free and can be steadier when the phone is
/// warm. The iOS Simulator can only use the CPU (its Metal can't build
/// LiteRT-LM's GPU kernels). Changing it reloads the model.
enum ModelAccelerator: String, CaseIterable, Identifiable, Sendable {
    case gpu, cpu

    static let key = "model_accelerator"

    var id: String { rawValue }
    var label: String { self == .gpu ? "GPU" : "CPU" }

    /// Whether this device can choose (the simulator can't).
    static var choosable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// The one to use now.
    static func current(_ defaults: UserDefaults = .standard) -> ModelAccelerator {
        guard choosable else { return .cpu }
        return defaults.string(forKey: key).flatMap(ModelAccelerator.init(rawValue:)) ?? .gpu
    }
}
