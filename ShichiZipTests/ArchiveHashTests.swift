import Foundation
import XCTest

final class ArchiveHashTests: XCTestCase {
    func testSelectedAndAllMethodsProduceExpectedDigests() throws {
        let url = try makeTemporaryDirectory(named: "hash").appendingPathComponent("payload.txt")
        try Data("abc".utf8).write(to: url)
        let methods = ["CRC32", "CRC64", "XXH64", "MD5", "SHA1", "SHA256", "SHA384",
                       "SHA512", "SHA3-256", "BLAKE2sp"]
        let allHashes = try SZArchive.calculateHash(forPath: url.path, methods: [], session: nil)
        XCTAssertEqual(Set(allHashes.keys), Set(methods))
        XCTAssertEqual(allHashes["CRC32"], "352441C2")
        XCTAssertEqual(allHashes["SHA256"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try SZArchive.calculateHash(forPath: url.path, session: nil), allHashes)
        for method in methods {
            let hashes = try SZArchive.calculateHash(forPath: url.path, methods: [method], session: nil)
            XCTAssertEqual(hashes, try [method: XCTUnwrap(allHashes[method])])
        }
    }
}
