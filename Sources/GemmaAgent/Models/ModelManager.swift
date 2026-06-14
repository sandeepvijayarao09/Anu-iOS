import Foundation
import Combine

/// Owns the user's active-model choice. Decoupled from `ModelFactory` via the
/// shared UserDefaults key `selected_model` (same pattern as `temperature` /
/// `scripted_model`) so the factory can read it without an actor dependency.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    static let selectionKey = "selected_model"

    @Published private(set) var selectedID: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedID = defaults.string(forKey: Self.selectionKey) ?? "automatic"
    }

    /// All catalog options paired with their live availability.
    var options: [(option: ModelOption, availability: ModelAvailability)] {
        ModelCatalog.all.map { ($0, ModelCatalog.availability(of: $0)) }
    }

    var selectedOption: ModelOption {
        ModelCatalog.option(id: selectedID) ?? ModelCatalog.all[0]
    }

    /// Persists a new selection. The caller reloads the active model
    /// (`AgentOrchestrator.switchActiveModel()`).
    func select(_ id: String) {
        guard ModelCatalog.option(id: id) != nil else { return }
        selectedID = id
        defaults.set(id, forKey: Self.selectionKey)
    }
}
