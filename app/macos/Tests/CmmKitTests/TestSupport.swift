import Foundation
import XCTest

/// Fixtures are written by hand from the samples in the spec (anonymized paths under /Users/test); none of them was
/// produced by running the real cmm.
enum Fixture {
    static func url(_ name: String) -> URL {
        let ns = name as NSString
        guard let url = Bundle.module.url(
            forResource: ns.deletingPathExtension,
            withExtension: ns.pathExtension,
            subdirectory: "Fixtures"
        ) else {
            fatalError("missing test fixture \(name)")
        }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

extension XCTestCase {
    /// A fresh folder under the system temporary folder that is removed when the test ends. Tests never create or
    /// delete anything anywhere else.
    func makeTempDirectory(_ label: String = "cmmkit-tests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// POSIX permission bits (for example 0o600) of a file or folder, or nil when it does not exist.
func permissions(of url: URL) -> Int? {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return nil }
    return Int(st.st_mode & 0o7777)
}
