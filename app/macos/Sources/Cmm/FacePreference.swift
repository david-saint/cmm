import CmmKit

/// Which face of the Details pane was open last, List or Map.
///
/// It is kept with the rest of the app's choices in `Settings`, which is the only code that touches the preferences (a source
/// test pins that). This hands the face over: read when the window is made, written when the person switches.
enum FacePreference {
    static func load() -> DetailsFace {
        Settings.standard.detailsFace
    }

    static func save(_ face: DetailsFace) {
        Settings.standard.detailsFace = face
    }
}
