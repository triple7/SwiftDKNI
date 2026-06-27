import Foundation
import SceneKit

// MARK: - Core Singleton
final public class SwiftDKNI: Sendable {
    
    private static let lock = NSLock()
    
    // Tell the strict concurrency checker we are handling thread safety manually via the lock
    nonisolated(unsafe) private static var _shared: SwiftDKNI?
    
    /// Access the shared instance. Must call `configure(apiKey:)` first.
    public static var shared: SwiftDKNI {
        lock.lock()
        defer { lock.unlock() }
        guard let instance = _shared else {
            fatalError("SwiftDKNI must be configured via configure(apiKey:) before accessing 'shared'.")
        }
        return instance
    }
    
    /// Inject your API key at the application's entry point to initialize the singleton.
    public static func configure(apiKey: String) {
        lock.lock()
        defer { lock.unlock() }
        guard _shared == nil else { return }
        _shared = SwiftDKNI(apiKey: apiKey)
    }
    
    private let apiKey: String
    
    // Hold references to our pipeline services
    private let donkiService = DONKIService()
    private let renderer = CMEFluxRopeRenderer()
    
    private init(apiKey: String) {
        self.apiKey = apiKey
    }
}
