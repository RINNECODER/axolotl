import Network
import XCTest
@testable import Axolotl

/// SSRF guard for web-search page fetches, against a local server (no internet needed).
@MainActor
final class WebSearchGuardTests: XCTestCase {
    func testResolverFlagsNamesThatResolveToPrivateAddresses() async {
        let localhost = await WebSearchService.resolvesToPrivateAddress("localhost")
        XCTAssertTrue(localhost)
        let unresolvable = await WebSearchService.resolvesToPrivateAddress("no-such-host.invalid")
        XCTAssertTrue(unresolvable, "fails closed")
        let publicLiteral = await WebSearchService.resolvesToPrivateAddress("8.8.8.8")
        XCTAssertFalse(publicLiteral)
    }

    func testRedirectToPrivateAddressIsNotFollowedAndBodyIsDiscarded() async throws {
        var paths: [String] = []
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                paths.append(String(line.split(separator: " ").dropFirst().first ?? ""))
                let port = listener.port!.rawValue
                let reply = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let url = URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/start")!
        let isSafe = await WebSearchService.isSafeToFetch(url)
        XCTAssertFalse(isSafe)
        let guarded = await WebSearchService.guardedData(for: URLRequest(url: url))
        XCTAssertNil(guarded)

        // Past the pre-check (as if DNS had rebound to a private address after it): the hop is refused
        // and the connection's remote address marks the response as unusable.
        let fetchGuard = FetchGuard()
        _ = try? await URLSession.shared.data(for: URLRequest(url: url), delegate: fetchGuard)
        XCTAssertEqual(paths, ["/start"], "redirect to the private address was not followed")
        XCTAssertEqual(fetchGuard.remoteAddresses, ["127.0.0.1"], "metrics arrive before the fetch returns")
        XCTAssertFalse(fetchGuard.connectedOnlyToPublicAddresses)
    }
}
