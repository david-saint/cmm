import Foundation

/// The three faces of the Details pane, chosen by the List | Map | History switch under its title.
///
/// The first open shows the map; after that the pane opens on the face the person last chose. (That choice is one of the few
/// things the app remembers between launches; `Settings` is the only place it is stored, and `FacePreference` in the app
/// target hands it over.)
public enum DetailsFace: String, CaseIterable, Sendable {
    case list
    case map
    case history

    /// The face to open on, from what was stored: nothing, or anything that is not one of the other faces' words, is the map.
    public static func restored(from stored: String?) -> DetailsFace {
        switch stored {
        case DetailsFace.list.rawValue: .list
        case DetailsFace.history.rawValue: .history
        default: .map
        }
    }

    public var title: String {
        switch self {
        case .list: "List"
        case .map: "Map"
        case .history: "History"
        }
    }

    /// What VoiceOver says a word of the switch does.
    public var hint: String {
        switch self {
        case .list: "Shows the list of what cmm found"
        case .map: "Shows the map of what cmm found"
        case .history: "Shows what past cleanings freed and how the free space has moved"
        }
    }
}
