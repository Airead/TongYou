import Foundation

/// Global weak-object registry for all active MetalView instances.
/// All access is MainActor-isolated.
@MainActor
final class MetalViewRegistry {
    static let shared = MetalViewRegistry()

    private let table = NSHashTable<MetalView>.weakObjects()

    private init() {}

    /// The raw count including potential stale weak references.
    var count: Int { table.count }

    /// The count of currently alive views.
    var activeCount: Int { table.allObjects.count }

    var allViews: [MetalView] {
        table.allObjects
    }

    func register(_ view: MetalView) {
        table.add(view)
    }

    func unregister(_ view: MetalView) {
        table.remove(view)
    }
}
