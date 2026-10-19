import WebKit

/// Chrome-style find in page: counts every match ("3 of 17") and highlights them all with the
/// CSS Custom Highlight API (no DOM edits), from an isolated content world the page can't see.
enum FindInPage {
    /// `index` is 0-based; `count` 0 means no match.
    struct Result: Equatable {
        var index: Int
        var count: Int
        var label: String { count == 0 ? "0/0" : "\(index + 1) of \(count)" }
    }

    static let world = WKContentWorld.world(name: "LunaFind")

    /// Pure matcher, also run by unit tests in JavaScriptCore: start offsets of `q` in `text`, case-insensitive.
    // shortcut: toLowerCase can change length for a few characters (e.g. "İ"), shifting offsets; fine for find.
    static let matcherJS = """
    function lunaFindOffsets(text, q) {
      const out = [];
      if (!q) return out;
      const t = text.toLowerCase(), n = q.toLowerCase();
      for (let i = t.indexOf(n); i !== -1 && out.length < 5000; i = t.indexOf(n, i + n.length)) out.push(i);
      return out;
    }
    """

    /// Function body for `callAsyncJavaScript`; arguments `op` ("run" | "step" | "clear"), `q`, `dir`.
    static let script = matcherJS + """

    const F = window.__lunaFind || (window.__lunaFind = { ranges: [], index: -1, q: "" });
    const hasHL = !!(window.CSS && CSS.highlights && window.Highlight);
    const BLOCKS = "p,div,li,td,th,h1,h2,h3,h4,h5,h6,section,article,header,footer,nav,aside,main,blockquote,pre,dd,dt,tr,table,ul,ol,figure,figcaption,form,body";
    const SKIP = "script,style,noscript,template,textarea,select,head,title";
    function search(q) {
      F.q = q; F.ranges = []; F.index = -1;
      if (!q || !document.body) return;
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      const segs = [], seen = new Map();
      let joined = "", lastBlock;
      const visible = el => {
        if (seen.has(el)) return seen.get(el);
        const v = !el.closest(SKIP) && (el.checkVisibility ? el.checkVisibility({ visibilityProperty: true }) : el.getClientRects().length > 0);
        seen.set(el, v);
        return v;
      };
      for (let n; (n = walker.nextNode());) {
        const el = n.parentElement;
        if (!el || !n.data || !visible(el)) continue;
        // Matches may span inline elements ("foo<b>bar</b>") but never two blocks.
        const block = el.closest(BLOCKS);
        if (block !== lastBlock) { joined += "\\n"; lastBlock = block; }
        segs.push({ n, s: joined.length });
        joined += n.data;
      }
      let k = 0;
      const seg = (o, end) => { while (k + 1 < segs.length && (end ? segs[k + 1].s < o : segs[k + 1].s <= o)) k++; return segs[k]; };
      for (const o of lunaFindOffsets(joined, q)) {
        const r = new Range(), a = seg(o, false);
        r.setStart(a.n, o - a.s);
        const b = seg(o + q.length, true);
        r.setEnd(b.n, Math.min(b.n.data.length, o + q.length - b.s));
        F.ranges.push(r);
      }
      // Like Chrome, start at the first match in or below the viewport.
      if (F.ranges.length) F.index = Math.max(0, F.ranges.findIndex(r => r.getBoundingClientRect().bottom >= 0));
    }
    function sheet(on) {
      if (!hasHL || !document.adoptedStyleSheets) return;
      if (!F.sheet) {
        F.sheet = new CSSStyleSheet();
        F.sheet.replaceSync("::highlight(luna-find){background-color:#fde047;color:#000}::highlight(luna-find-current){background-color:#ff9632;color:#000}");
      }
      const rest = document.adoptedStyleSheets.filter(s => s !== F.sheet);
      document.adoptedStyleSheets = on ? [...rest, F.sheet] : rest;
    }
    function paint(scroll) {
      const cur = F.ranges[F.index];
      if (hasHL) {
        sheet(true);
        CSS.highlights.set("luna-find", new Highlight(...F.ranges));
        if (cur) { const h = new Highlight(cur); h.priority = 1; CSS.highlights.set("luna-find-current", h); }
        else CSS.highlights.delete("luna-find-current");
      } else if (cur) {
        const sel = getSelection(); sel.removeAllRanges(); sel.addRange(cur);
      }
      if (scroll && cur) {
        const el = cur.startContainer.parentElement;
        if (el) el.scrollIntoView({ block: "nearest", inline: "nearest" });
        const r = cur.getBoundingClientRect();
        if (r.top < 0 || r.bottom > innerHeight) scrollBy(0, r.top - innerHeight / 2);
      }
    }
    if (op === "clear") {
      F.ranges = []; F.index = -1; F.q = "";
      if (hasHL) { CSS.highlights.delete("luna-find"); CSS.highlights.delete("luna-find-current"); sheet(false); }
      return { index: -1, count: 0 };
    }
    if (op === "run" || (q && (F.q !== q || !F.ranges.length))) search(q);
    else if (F.ranges.length) F.index = (F.index + dir + F.ranges.length) % F.ranges.length;
    paint(true);
    return { index: F.index, count: F.ranges.length };
    """
}

extension WebViewWrapper {
    /// Searches the tab and highlights every match; the result lands in `findResultByTab`.
    func findInPage(query: String, in tabId: UUID) {
        lastFindQueryByTab[tabId] = query
        runFind("run", query: query, dir: 0, in: tabId)
    }

    func findNext(in tabId: UUID) {
        guard let query = lastFindQueryByTab[tabId] else { return }
        runFind("step", query: query, dir: 1, in: tabId)
    }

    func findPrevious(in tabId: UUID) {
        guard let query = lastFindQueryByTab[tabId] else { return }
        runFind("step", query: query, dir: -1, in: tabId)
    }

    func clearFind(in tabId: UUID) {
        lastFindQueryByTab.removeValue(forKey: tabId)
        tabRuntime.setFindResult(nil, for: tabId)
        runFind("clear", query: "", dir: 0, in: tabId)
    }

    private func runFind(_ op: String, query: String, dir: Int, in tabId: UUID) {
        guard let wv = webViewIfLoaded(for: tabId) else { return }
        wv.callAsyncJavaScript(FindInPage.script, arguments: ["op": op, "q": query, "dir": dir],
                               in: nil, in: FindInPage.world) { [weak self] result in
            guard op != "clear", self?.lastFindQueryByTab[tabId] == query else { return }
            let dict = (try? result.get()) as? [String: Any]
            let count = (dict?["count"] as? NSNumber)?.intValue ?? 0
            let index = (dict?["index"] as? NSNumber)?.intValue ?? -1
            self?.tabRuntime.setFindResult(FindInPage.Result(index: max(0, index), count: count), for: tabId)
        }
    }
}
