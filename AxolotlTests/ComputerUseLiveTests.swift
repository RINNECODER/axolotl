import AppKit
import WebKit
import XCTest
@testable import Axolotl

/// End-to-end: the real Jev loop drives a local form in an offscreen WKWebView.
/// Needs TYPESAFE_API_KEY in the environment (xcodebuild: TEST_RUNNER_TYPESAFE_API_KEY); skipped otherwise.
/// Typed values come from a stand-in that reads the quoted phrase in the goal, so the run
/// measures Jev's decisions and Axolotl's page driver, not a chat model.
@MainActor
final class ComputerUseLiveTests: XCTestCase {
    static let fixture = """
    <!doctype html><html><head><meta charset="utf-8"><title>Axolotl Library</title>
    <style>body{font:16px -apple-system,sans-serif;margin:24px} label{display:block;margin:10px 0}</style></head>
    <body><main id="app">
      <h1>Axolotl Library</h1>
      <form id="search">
        <label>Search <input id="q" type="search" placeholder="Title"></label>
        <label>Category <select id="cat"><option value="all">All</option><option value="books">Books</option>
          <option value="movies">Movies</option></select></label>
        <button type="submit">Search</button>
      </form>
      <section id="results"></section>
    </main>
    <script>
      const items=[{t:'Dune',c:'books',d:'Novel by Frank Herbert, 1965'},{t:'Dune',c:'movies',d:'Film by Denis Villeneuve, 2021'},
        {t:'Neuromancer',c:'books',d:'Novel by William Gibson, 1984'}];
      const names={all:'All',books:'Books',movies:'Movies'};
      document.getElementById('search').addEventListener('submit',e=>{
        e.preventDefault();
        const q=document.getElementById('q').value.trim().toLowerCase(), c=document.getElementById('cat').value;
        const hits=items.map((it,i)=>({...it,i})).filter(it=>it.t.toLowerCase().includes(q) && (c==='all'||it.c===c));
        document.getElementById('results').innerHTML='<h2>Results for “'+q+'” in '+names[c]+'</h2>'+
          (hits.length ? '<ul>'+hits.map(h=>'<li><a href="#item-'+h.i+'">'+h.t+' ('+names[h.c]+')</a></li>').join('')+'</ul>' : '<p>No results</p>');
      });
      addEventListener('hashchange',()=>{
        const it=items[Number(location.hash.replace('#item-',''))];
        if (it) document.getElementById('app').innerHTML='<h1>'+it.t+'</h1><p>Category: '+names[it.c]+'</p><p>'+it.d+'</p>';
      });
    </script></body></html>
    """

    private struct QuotedGoalText: FieldTextProviding {
        func text(for context: JSONValue) async throws -> String {
            let goal = context["goal"]?.stringValue ?? ""
            let parts = goal.components(separatedBy: "'")
            guard parts.count >= 3 else { throw AgentError.noText("No quoted value in the goal.") }
            return parts[1]
        }
    }

    func testJevCompletesSearchSelectAndOpenOnLocalFixture() async throws {
        guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("TYPESAFE_API_KEY not set")
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.alphaValue = 0.01
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        webView.loadHTMLString(Self.fixture, baseURL: URL(string: "https://fixture.axolotl.test/"))
        let loadDeadline = Date().addingTimeInterval(10)
        repeat { try await Task.sleep(nanoseconds: 50_000_000) } while (webView.isLoading || webView.url == nil) && Date() < loadDeadline

        let driver = PageDriver(webView: webView)
        let agent = ComputerUseAgent(driver: driver, policy: JevPolicy(client: JevClient(apiKey: key)),
                                     textProvider: QuotedGoalText())
        var latencies: [Int] = []
        var lines: [String] = []
        var outcome: AgentOutcome?
        var elapsed = 0
        for await event in agent.run(goal: "Search the library for 'Dune' in the Books category, then open that result's details page.") {
            if case .decided(let d, _) = event { latencies.append(d.latencyMs) }
            if case .finished(let o, _, let ms) = event { outcome = o; elapsed = ms }
            if let line = event.panelLine { lines.append(line) }
        }
        let steps = lines.filter { $0.hasPrefix("  ") }.count
        let sorted = latencies.sorted()
        print("JEV_LIVE outcome=\(String(describing: outcome)) steps=\(steps) decisions=\(latencies.count) wall_ms=\(elapsed) " +
              "jev_ms_median=\(sorted.isEmpty ? 0 : sorted[sorted.count / 2]) jev_ms_max=\(sorted.last ?? 0)")
        print("JEV_LIVE trace:\n" + lines.joined(separator: "\n"))

        XCTAssertEqual(outcome, .done)
        let final = try await driver.read()
        XCTAssertTrue(final.contains("Category: Books"), final)
        XCTAssertTrue(final.contains("Frank Herbert"), final)
    }
}
