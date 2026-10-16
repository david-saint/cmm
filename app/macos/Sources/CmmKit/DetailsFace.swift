import Foundation

/// The two faces of the Details pane, chosen by the List | Map switch under its title.
///
/// The first open shows the map; after that the pane opens on the face the person last chose. (That choice is the one
/// thing the app remembers between launches; `FacePreference` in the app target is the only place it is stored.)
public enum DetailsFace: String, CaseIterable, Sendable {
    case list
    case map

    /// The face to open on, from what was stored: nothing, or anything but `list`, is the map.
    public static func restored(from stored: String?) -> DetailsFace {
        stored == DetailsFace.list.rawValue ? .list : .map
    }

    public var title: String {
        switch self {
        case .list: "List"
        case .map: "Map"
        }
    }
}
