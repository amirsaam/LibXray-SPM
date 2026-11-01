import XCTest
@testable import CoreXray

final class DNSTests: XCTestCase {
    private let minimalJSON = #"{"inbounds":[],"outbounds":[]}"#

    func testDNSWireMixedServers() throws {
        let session = Xray.Session()
        let config = try session.build(.json(minimalJSON), options: .init(
            // Wire-shape test: the geo references are spellings under test,
            // not files that need to exist.
            geoCheck: false,
            dns: Xray.DNS(
                hosts: ["geosite:malware": "127.0.0.1", "dns.google": "8.8.8.8"],
                queryStrategy: .useIPv4,
                servers: [
                    .detailed(address: "fakedns", domains: ["geosite:category-ir"]),
                    .plain("https://dns.google/dns-query"),
                ]
            )
        ))
        let value = try JSONDecoder().decode(Xray.JSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["dns"]?["hosts"]?["geosite:malware"], .string("127.0.0.1"))
        XCTAssertEqual(value["dns"]?["hosts"]?["dns.google"], .string("8.8.8.8"))
        XCTAssertEqual(value["dns"]?["queryStrategy"], .string("UseIPv4"))
        XCTAssertEqual(value["dns"]?["servers"]?[0]?["address"], .string("fakedns"))
        XCTAssertEqual(value["dns"]?["servers"]?[0]?["domains"], .array([.string("geosite:category-ir")]))
        XCTAssertEqual(value["dns"]?["servers"]?[1], .string("https://dns.google/dns-query"))
    }

    func testFakeDNSWire() throws {
        let session = Xray.Session()
        let config = try session.build(.json(minimalJSON), options: .init(
            fakeDNS: [Xray.FakeDNS(ipPool: "198.18.0.0/16", poolSize: 512)]
        ))
        let value = try JSONDecoder().decode(Xray.JSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["fakedns"]?[0]?["ipPool"], .string("198.18.0.0/16"))
        XCTAssertEqual(value["fakedns"]?[0]?["poolSize"], .int(512))
    }

    func testLogWire() throws {
        let session = Xray.Session()
        let config = try session.build(.json(minimalJSON), options: .init(
            log: Xray.Log(level: .warning, dnsLog: true)
        ))
        let value = try JSONDecoder().decode(Xray.JSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["log"]?["loglevel"], .string("warning"))
        XCTAssertEqual(value["log"]?["dnsLog"], .bool(true))
        XCTAssertNil(value["log"]?["access"])
    }

    func testAbsentSectionsLeaveDocumentAlone() throws {
        let session = Xray.Session()
        let config = try session.build(.json(minimalJSON))
        let value = try JSONDecoder().decode(Xray.JSONValue.self, from: Data(config.json.utf8))
        XCTAssertNil(value["dns"])
        XCTAssertNil(value["fakedns"])
        XCTAssertNil(value["log"])
    }
}
