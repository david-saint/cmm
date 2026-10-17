import Foundation

/// The file that carries the ticked paths to `cmm apply --select-file`: a UTF-8 JSON array of strings.
///
/// Safety rule 4: it is created with mode 0600 inside a folder of mode 0700 that only this run uses, and it is
/// removed when the run ends. This is the one place the app removes anything, and it removes only what it made
/// itself, with `unlink` on its own file and `rmdir` on its own folder. `rmdir` refuses a folder that still has
/// something in it, so there is no call anywhere that could remove a tree.
struct SelectionFile: Sendable {
    let directory: URL
    let url: URL

    /// Writes `paths` into a fresh private folder inside `parent`, which must already exist.
    static func create(paths: [String], in parent: URL) throws -> SelectionFile {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(paths)
        } catch {
            throw CmmError.selectionFileFailed(error.localizedDescription)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CmmError.selectionFileFailed("the temporary folder \(parent.path) does not exist")
        }

        let directory = parent.appendingPathComponent("cmm-selection-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("selection.json")
        let file = SelectionFile(directory: directory, url: url)

        guard mkdir(directory.path, 0o700) == 0 else {
            throw CmmError.selectionFileFailed("mkdir: \(String(cString: strerror(errno)))")
        }
        // mkdir and open apply the umask; the modes below are what the rule promises, whatever the umask is.
        guard chmod(directory.path, 0o700) == 0 else {
            let reason = String(cString: strerror(errno))
            file.remove()
            throw CmmError.selectionFileFailed("chmod: \(reason)")
        }

        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            file.remove()
            throw CmmError.selectionFileFailed("open: \(reason)")
        }
        defer { close(fd) }

        guard fchmod(fd, 0o600) == 0 else {
            let reason = String(cString: strerror(errno))
            file.remove()
            throw CmmError.selectionFileFailed("chmod: \(reason)")
        }

        var failure: String?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno))
                    return
                }
                offset += written
            }
        }
        if let failure {
            file.remove()
            throw CmmError.selectionFileFailed("write: \(failure)")
        }
        return file
    }

    /// Removes the file and its folder. Harmless to call twice, and it leaves alone anything it did not create.
    func remove() {
        unlink(url.path)
        rmdir(directory.path)
    }
}
