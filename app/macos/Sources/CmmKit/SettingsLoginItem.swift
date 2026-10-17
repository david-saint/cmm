import Foundation

/// What the system says about starting cmm when the person logs in (spec R8). The app never keeps this: it asks the system,
/// and the person can change it in System Settings at any time, so what the system says last is what is true.
public enum LoginItemState: Equatable, Sendable {
    case off
    case on
    /// Registered, but the person has to allow it in System Settings > General > Login Items before it does anything.
    case needsApproval
}

/// The system's login item for the app (in the app this is `SMAppService.mainApp`, which is the second phase's).
public protocol LoginItem: Sendable {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
}
