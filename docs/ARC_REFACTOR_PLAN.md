# Axolotl → Arc-style shell, Helium-level customizability

Status: **approved** · 2026-10-13

## Goal

Rebuild Axolotl's browser shell around an Arc-style sidebar: Spaces, pinned and favorite tabs, nested tab folders, split view, drag and drop everywhere, and a floating command bar. Wrap it all in a settings and theming layer as deep as Helium's (privacy defaults, built-in content blocking, bangs, per-site settings, layout toggles). Keep the AI features (Cmd+E panel, SmartSearch, CommandRouter) and plug them into the new shell.

## Engine decision (decided: WebKit)

Axolotl runs on **WebKit (`WKWebView`)**. Helium runs on Chromium (ungoogled-chromium, C++), so we can't reuse its code. We copy its features and defaults instead.

**Recommendation: stay on WebKit.** It's native, light on battery, and the existing code already depends on it. The cost is no Chrome extensions. We cover the most important extension (an ad blocker) with built-in `WKContentRuleList` blocking and add "Boosts" (user CSS/JS per site) for everything else. Moving to Chromium (CEF) would be a separate, much larger project.

## Current state (audit)

| Area | File | Notes |
|---|---|---|
| Tab model | `Browser/TabManager.swift` (96 lines) | A flat `tabOrder: [UUID]` plus dictionaries for URL and title. No groups, pinning, spaces, or persistence. |
| Shell UI | `Browser/BrowserShellView.swift` (1,929 lines) | One large view: horizontal tab strip, address bar, suggestions, find bar, AI panel, downloads, and the key monitor. 20+ `@State` vars. |
| Web views | `Browser/WebViewWrapper.swift` (1,053 lines) | One `WKWebView` per tab id (good, reusable). It holds "active tab" state for theme and back/forward, which assumes a single visible pane, so split view breaks it. |
| Start page / AI | `SmartSearchView` (1,926), `AI/CommandSurface` (1,280) | Kept as is, rehosted. |
| Profiles | `Profiles/ProfileSession.swift`, `ProfileManager.swift` | Per-profile `WKWebsiteDataStore` and stores, which is solid. `ProfileTabSnapshot` is defined but **never used**, so tabs are lost on quit. |
| Shortcuts | `NSEvent` local monitor inside the shell view | Hard-coded and can't be rebound. |
| Tests | `AxolotlTests/CoreLogicTests.swift` | Covers sessions and CommandRouter against the `TabManager` API. |

## Target architecture

### Data model (`Axolotl/Workspace/`)

```
Workspace (per profile, Codable, persisted)
├── favorites: [TabID]                 // icon grid at top of sidebar, shared across spaces
├── spaces: [Space]
│   ├── id, name, icon, theme (SpaceTheme)
│   ├── pinned: [SidebarNode]           // persistent; pinned tabs "reset" to their saved URL
│   └── today:  [SidebarNode]           // ephemeral; auto-archived after N hours (configurable)
├── tabs: [TabID: Tab]                  // single source of truth for tab state
└── archive: [ArchivedTab]

enum SidebarNode { case tab(TabID), folder(Folder), split(SplitGroup) }
Folder     { id, name, isExpanded, children: [SidebarNode] }      // nestable
SplitGroup { id, panes: [TabID] (2…4), axis, ratios: [CGFloat] }
Tab        { id, url, title, faviconURL, savedURL?, lastActive, isMuted, interactionState: Data? }
```

- `WorkspaceStore` (an `ObservableObject`, one per `ProfileSession`) owns every mutation through **one command API** (`move(node:to:)`, `pin`, `group`, `split`, `close`, `undoClose`). Drag and drop, keyboard shortcuts, the command bar, and the AI CommandRouter all call this API, which also gives us undo for free (`UndoManager`).
- `TabManager` becomes a thin compatibility facade over `WorkspaceStore`, so `CommandRouter` and the existing tests keep compiling. It gets deleted in the final cleanup phase.
- Persistence: JSON per profile (debounced writes). Back/forward history is saved with `WKWebView.interactionState`.

### Web view lifecycle

- `WebViewWrapper` drops the "active tab" singleton state. Theme color, back/forward, and progress move to per-tab `@Published` dictionaries, and the shell reads the *focused pane*.
- Hibernation: unload web views for tabs inactive longer than N minutes (configurable) and restore them from `interactionState`.

### Shell layout (`Axolotl/Shell/`)

```
┌───────────┬──────────────────────────────────────────┬────────┐
│ Sidebar   │  Content card (rounded, inset, shadow)    │ AI     │
│ ─ URL pill│  ┌─────────────┬──────────────┐           │ panel  │
│ ─ Favs ▦▦ │  │ pane A      │ pane B       │  ← split  │ (Cmd+E)│
│ ─ Pinned  │  └─────────────┴──────────────┘           │        │
│ ─ ──────  │                                           │        │
│ ─ Today   │                                           │        │
│ Space dots│                                           │        │
└───────────┴──────────────────────────────────────────┴────────┘
```

- **Sidebar**: an `NSOutlineView` wrapped for SwiftUI, with rows built in SwiftUI (`NSHostingView`). SwiftUI's `List`/`onDrag` can't do Arc-quality nested drag and drop (spring-loaded folders, insertion indicators, multi-select drag), but `NSOutlineView` does all of that natively.
- **Auto-hide sidebar** (Cmd+S): it slides out, and hovering the left edge reveals it as an overlay.
- **Spaces**: a row of dots or icons at the bottom of the sidebar. Two-finger horizontal swipe or Ctrl+1…9 switches spaces. Each space has its own theme gradient.
- **No top toolbar.** The URL pill sits at the top of the sidebar, and back/forward/reload are sidebar buttons or shortcuts. A compact "top bar" layout is available as a setting.

### Command bar (`Axolotl/Shell/CommandBar/`)

- A floating overlay. Cmd+L opens it pre-filled with the current URL to replace it; Cmd+K opens it empty (switch tabs, run commands).
- **Cmd+T keeps opening the SmartSearch AI start page** in a new tab (decided). The command bar never replaces it.
- Unified ranked results: open tabs (switch to), pinned and favorites, history, search suggestions, **commands** ("split with…", "move to space…", "pin", "copy URL", settings toggles), and **bangs** (`!g`, `!yt`, user-defined).
- Hands off to SmartSearch / AI when the query is classified as AI intent (reusing `QueryClassifier`).

### Split view

- Create a split by dragging a tab onto the left or right edge of the content (drop zones appear), with Ctrl+Shift+= or "Split with…", or by selecting multiple tabs in the sidebar.
- A split shows as one grouped row in the sidebar. Panes have draggable dividers, and the focused pane gets an outline and drives the URL pill and theme.

### Customizability (Helium parity and more)

| Category | Settings |
|---|---|
| Layout | Sidebar left/right, auto-hide, width, compact top-bar mode, density, show/hide URL pill and nav buttons |
| Theme | Per-space gradient/color, page-tinted chrome (current behaviour) on/off, light/dark/system, corner radius, content-card inset |
| Privacy (Helium defaults) | Built-in content blocker (EasyList/EasyPrivacy compiled to `WKContentRuleList`, auto-updated), strip tracking params, HTTPS-only, third-party cookie blocking, no telemetry, search engine choice (no Google default), suggestions off by default |
| Search | Bangs (built-in plus user-defined), custom search engines |
| Tabs | Auto-archive Today tabs after N hours, hibernation timeout, pinned tabs reset on close/re-click, new tab placement |
| Per-site | Zoom, content blocker allowlist, JS on/off, autoplay, camera/mic/location permissions |
| Boosts | User CSS/JS per domain (`WKUserScript`), with an editor in settings |
| Keyboard | Rebindable shortcuts (central `ShortcutRegistry` replacing the `NSEvent` monitor) |

Settings move from scattered `@AppStorage` keys into a typed `Preferences` model (Codable, observable), with `@AppStorage` keys migrated once.

## Visual direction

Sleek and native to macOS 27: system Liquid Glass materials, standard controls, SF Symbols, and system fonts and colors. No glowing, rainbow, or animated-gradient effects anywhere; focused inputs get only a hairline accent focus ring.

## Progress

- [x] 0. Baseline
- [x] 1. Workspace model and persistence
- [x] 2. Per-tab page state and hibernation
- [x] 3. Sidebar shell (Top Tabs kept as a layout option)
- [x] A. AI input focus: no blue ring, small shadow
- [x] B. Helium layouts + appearance options + native Settings window
- [x] C. Profiles without the popover (native menus + Settings pane)
- [x] D. AI panel redesign (Desktop AXOLOTL / Siri style) + nicer tab/document attachments
- [x] E. Cloud models: Sign in with ChatGPT, OpenAI and Anthropic API keys
- [x] F. Axolotl Max (Arc Max equivalent)
- [ ] 4. Drag and drop
- [ ] 5. Split view rendering
- [ ] 6. Spaces (swipe, themes, auto-archive)
- [ ] 7. Command bar
- [ ] 8. Remaining customizability (privacy, per-site, Boosts, shortcuts)
- [ ] 9. Cleanup

## Round 2 additions (2026-10-13)

### B. Layouts (from Helium's Appearance settings)

| Layout | Shape |
|---|---|
| Sidebar (default) | Arc-style vertical sidebar (phase 3) |
| Compact | One row: traffic lights, nav, URL field, tabs inline to its right, toolbar icons |
| Dynamic | Row 1: nav + (optionally centered) address bar + icons; row 2: tabs |
| Classic | Row 1: tabs beside the traffic lights; row 2: nav + address bar + icons |

Options: centered address bar, minimal URL (domain only until focused), loading progress in the address bar, frameless mode (chrome hides until you hover the window edge; vertical tab list slides in from the left edge, as in Helium) with "always show top bar", rounded frame around web contents, home button.

Settings becomes a native macOS 27 Settings window: category sidebar (Profiles, Appearance, AI & Models, Privacy, Search, Tabs, Downloads, About), a search field, and grouped rows with toggles and pop-up menus, mirroring Helium's structure.

### C. Profiles
No floating popover. Profiles live in a native menu (sidebar avatar button and a Profiles menu-bar menu: switch, open in new window, new profile, manage) and a Settings → Profiles pane for create/rename/color/delete.

### D. AI panel
Modeled on the Desktop AXOLOTL Safari extension and the Siri app: floating rounded glass panel inset from the window edge, header with circular icon buttons, an animated Siri orb only in the empty state, iMessage-style user bubbles and plain assistant text, a capsule input with a small soft shadow (no colored ring). Context shows as compact capsule chips (favicon + title, × on hover). The + button opens a searchable menu of open tabs (favicons, titles, hosts) and "Choose Files…", with drag-and-drop of files onto the panel.

### E. Cloud models
- **ChatGPT (Sign in with ChatGPT):** OpenAI's official open-source/local-app flow. Authorization code + PKCE (S256) in the system browser, loopback redirect `http://127.0.0.1:<port>/auth/callback`, `client_id=dynamic_agent_client` on first registration with `agent_name_hint=Axolotl` and a persisted `ext_agent_host_id`, scopes `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, resource `https://api.openai.com/v1`. Issued client ID and tokens stored in the Keychain; rotating refresh; revocation on sign-out. Inference via `POST /v1/responses` (`stream: true`, `store: false`), models from `GET /v1/models`. Requires enabling the sandbox's incoming-network entitlement for the loopback listener.
- **OpenAI API key** as an alternative.
- **Anthropic:** API key from the Claude Console (Anthropic offers no third-party sign-in and prohibits reusing Claude subscription logins in other apps). Messages API with streaming.
- Gemini and Ollama stay.

### F. Axolotl Max (Arc Max equivalent)
Ask on Page (hold ⌘F or ⌘⇧F), link previews (hover a link and press Shift for an AI summary), tidy titles for pinned tabs (plus Rename / Tidy Title in the tab menu), tidy downloads (rename files, one-click undo), Tidy Today (✦ on the Today divider groups tabs into folders, undoable). Each feature toggles individually in Settings → Axolotl Max and uses the selected model. Asking AI from the command bar ships with phase 7.

## Phases

Each phase builds, passes tests, and is checked by running the app before the next one starts. Each phase ends in its own commit.

0. **Baseline**: run `setup.sh` and `xcodebuild`, record any existing warnings and bugs, and add a `.claude/launch` run config. *Done when* a clean build and tests pass on main.
1. **Workspace model and persistence**: `WorkspaceStore`, nodes, Codable, undo, `TabManager` facade, and session restore on relaunch. *Done when* the unit tests for move/group/pin/split/close/undo and a save/load round trip pass, and existing tests are untouched and green.
2. **WebViewWrapper de-singletoning**: per-tab state dictionaries and hibernation. *Done when* two web views can render side by side with correct back/forward and theme each.
3. **Sidebar shell**: new `ShellView` with the `NSOutlineView` sidebar, content card, URL pill, auto-hide, and favorites grid. The horizontal tab strip stays as a permanent **"Top tabs" layout option** (decided), driven by the same `WorkspaceStore` (folders shown as tab groups, splits as a joined pill). *Done when* tabs open, switch, close, and pin from the sidebar.
4. **Drag and drop**: reorder, nest into folders, spring-loaded folders, multi-select, drag to favorites, drag between Today and Pinned, drag a link or URL in to create a tab, drag a tab out to a new window. *Done when* every listed gesture works and is undoable.
5. **Split view**: `SplitGroup` rendering, drop zones, dividers, pane focus, and shortcuts. *Done when* a 2–4 pane split works, persists, and restores.
6. **Spaces**: create/rename/theme, swipe and shortcut switching, move tab to space, and Today auto-archive. *Done when* spaces persist and each one keeps its own pinned/Today lists.
7. **Command bar**: unified search, commands, bangs, and AI handoff. Replaces the inline address bar and suggestions list. *Done when* Cmd+L/Cmd+K flows replace the old omnibox suggestions in both layouts; Cmd+T still opens SmartSearch.
8. **Customizability**: `Preferences` model, redesigned settings, content blocker, per-site settings, Boosts, and the shortcut editor. *Done when* every setting in the table above is live.
9. **Cleanup**: rebuild `TabStripView` on `WorkspaceStore`, delete the old address bar code and the `TabManager` facade. Split `BrowserShellView` and `SmartSearchView` into smaller files, then update the README and shortcut table.

Rough size: phases 1–3 are the foundation (largest). Phases 4–7 are feature work that can be done one at a time, and 8 is broad but shallow.

## Out of scope for now

Chrome extensions, sync, Little Arc / Peek windows (good candidates for after phase 9), Study mode (THINGS_TO_DO.md).

## Decisions

1. Engine: WebKit.
2. Horizontal tab strip: kept as a permanent layout option.
3. Cmd+T: opens the SmartSearch AI start page; the command bar lives on Cmd+L / Cmd+K.
