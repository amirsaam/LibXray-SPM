import XCTest
@testable import CoreXray

// Client-side guards for the engine's ping contract: at most five targets,
// positive timeout, absolute HTTP(S) URL, engine stopped, optional tag.

final class PingTests: XCTestCase {
    private func invalidInput(_ expression: @autoclosure () throws -> [Xray.PingResult]) {
        do {
            _ = try expression()
            XCTFail("expected .invalidInput")
        } catch let error as Xray.Error {
            guard case .invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        } catch {
            XCTFail("expected Xray.Error, got \(error)")
        }
    }

    func testEmptyTargetsThrow() {
        invalidInput(try Xray.shared.ping([]))
    }

    func testMoreThanFiveTargetsThrow() {
        let targets = (0..<6).map { _ in Xray.PingTarget(config: #"{"outbounds":[]}"#) }
        invalidInput(try Xray.shared.ping(targets))
    }

    func testNonPositiveTimeoutThrows() {
        let target = Xray.PingTarget(config: #"{"outbounds":[]}"#)
        invalidInput(try Xray.shared.ping([target], options: Xray.PingOptions(timeoutSeconds: 0)))
        invalidInput(try Xray.shared.ping([target], options: Xray.PingOptions(timeoutSeconds: -3)))
    }

    func testBadTestURLThrows() {
        let target = Xray.PingTarget(config: #"{"outbounds":[]}"#)
        invalidInput(try Xray.shared.ping([target], options: Xray.PingOptions(testURL: "not a url")))
        invalidInput(try Xray.shared.ping([target], options: Xray.PingOptions(testURL: "/relative/path")))
        invalidInput(try Xray.shared.ping([target], options: Xray.PingOptions(testURL: "ftp://files.example.com/x")))
    }

    func testNilOutboundTagEncodesAsNull() throws {
        let data = try JSONEncoder().encode(Xray.PingTarget(config: #"{"outbounds":[]}"#))
        let value = try JSONDecoder().decode(Xray.JSONValue.self, from: data)
        // A nil tag is omitted from the wire, which the engine reads as
        // empty and auto-selects from.
        XCTAssertNil(value["outboundTag"])
        XCTAssertEqual(value["xrayJson"], .string(#"{"outbounds":[]}"#))
    }

    func testPingWhileRunningThrowsWithoutDisturbingTheEngine() throws {
        let session = Xray.Session()
        try session.start(.json(#"{"outbounds":[{"protocol":"freedom"}]}"#))
        defer { try? session.stop() }
        let target = Xray.PingTarget(config: #"{"outbounds":[{"protocol":"freedom"}]}"#)
        invalidInput(try Xray.shared.ping([target]))
        XCTAssertTrue(try session.isRunning())
    }

    func testEmptyLinkListDecodesAsEmptyString() throws {
        let list = try JSONDecoder().decode(Xray.LinkList.self, from: Data("{}".utf8))
        XCTAssertEqual(list.text, "")
    }
}
