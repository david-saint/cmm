import XCTest
@testable import CmmKit

/// Safety rule 4: the selection file is created with mode 0600 in the app's temporary folder and removed afterwards.
final class SelectionFileTests: XCTestCase {
    private let sample = ["/Users/test/Library/Caches/go-build", "homebrew: cleanup"]

    func testTheFileIsPrivateAndSitsInAPrivateFolderInsideTheTemporaryFolder() throws {
        let tmp = try makeTempDirectory()
        let file = try SelectionFile.create(paths: sample, in: tmp)

        XCTAssertEqual(permissions(of: file.url), 0o600)
        XCTAssertEqual(permissions(of: file.directory), 0o700)
        XCTAssertEqual(
            file.directory.deletingLastPathComponent().resolvingSymlinksInPath().path,
            tmp.resolvingSymlinksInPath().path
        )
        XCTAssertTrue(file.directory.lastPathComponent.hasPrefix("cmm-selection-"))
        XCTAssertEqual(file.url.deletingLastPathComponent().path, file.directory.path)
    }

    func testTheModeDoesNotDependOnTheUmask() throws {
        let tmp = try makeTempDirectory()
        let old = umask(0o277)  // would leave the file 0400 if the mode were only requested at creation
        defer { umask(old) }
        let file = try SelectionFile.create(paths: sample, in: tmp)
        XCTAssertEqual(permissions(of: file.url), 0o600)
        XCTAssertEqual(permissions(of: file.directory), 0o700)
    }

    func testTheFileIsAJSONArrayOfExactlyTheGivenStrings() throws {
        let tmp = try makeTempDirectory()
        let awkward = [
            "/Users/test/with space/and \"quotes\"",
            "/Users/test/comma,comma",
            "/Users/test/back\\slash",
            "/Users/test/Café 📦",
            "/Users/test/new\nline",
            "homebrew: cleanup",
        ]
        let file = try SelectionFile.create(paths: awkward, in: tmp)
        let data = try Data(contentsOf: file.url)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), awkward)
        XCTAssertEqual(data.first, UInt8(ascii: "["))
    }

    func testAnEmptySelectionIsAnEmptyArray() throws {
        let file = try SelectionFile.create(paths: [], in: try makeTempDirectory())
        XCTAssertEqual(String(decoding: try Data(contentsOf: file.url), as: UTF8.self), "[]")
    }

    func testEachFileGetsItsOwnFolder() throws {
        let tmp = try makeTempDirectory()
        let a = try SelectionFile.create(paths: sample, in: tmp)
        let b = try SelectionFile.create(paths: sample, in: tmp)
        XCTAssertNotEqual(a.directory, b.directory)
    }

    func testRemoveDeletesTheFileAndItsFolderAndNothingElse() throws {
        let tmp = try makeTempDirectory()
        let neighbour = tmp.appendingPathComponent("neighbour.txt")
        try Data("keep".utf8).write(to: neighbour)

        let file = try SelectionFile.create(paths: sample, in: tmp)
        file.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testRemovingTwiceIsHarmless() throws {
        let file = try SelectionFile.create(paths: sample, in: try makeTempDirectory())
        file.remove()
        file.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
    }

    func testRemoveNeverDeletesFilesItDidNotCreate() throws {
        let tmp = try makeTempDirectory()
        let file = try SelectionFile.create(paths: sample, in: tmp)
        let stray = file.directory.appendingPathComponent("stray.txt")
        try Data("not mine".utf8).write(to: stray)

        file.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path), "its own file is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "anything else in the folder is left alone")
    }

    func testAMissingTemporaryFolderIsAClearError() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("cmmkit-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try SelectionFile.create(paths: sample, in: missing)) { error in
            guard case .selectionFileFailed? = error as? CmmError else {
                return XCTFail("expected selectionFileFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "it must not create folders on the way")
    }
}
