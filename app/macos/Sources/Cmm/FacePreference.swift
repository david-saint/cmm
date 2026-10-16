import CmmKit
import Foundation

/// The one thing the app remembers between launches: which face of the Details pane was open last, List or Map.
///
/// One key in the app's own preferences, read when the window is made and written when the person switches. Nothing else
/// is ever stored, and this is the only file that touches the preferences (a source test pins both).
enum FacePreference {
    static let key = "detailsFace"

    static func load() -> DetailsFace {
        DetailsFace.restored(from: UserDefaults.standard.string(forKey: key))
    }

    static func save(_ face: DetailsFace) {
        UserDefaults.standard.set(face.rawValue, forKey: key)
    }
}
