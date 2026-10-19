// Axolotl — the page side of built-in passkeys. A page-world script wraps navigator.credentials.create/get for
// `publicKey` requests and forwards them here; everything else stays WebKit's. The origin always comes from
// WebKit's frame info, never from the page. Private windows can sign in with saved passkeys but never create one.
import AppKit
import WebKit

final class PasskeyBridge: NSObject, WKScriptMessageHandlerWithReply {
    let profileId: UUID
    let isPrivate: Bool
    private let store: PasskeyStoring
    /// The open sheet per web view, so an AbortSignal or timeout can close it.
    /// The user closed the account picker: an autofill-style request stops offering until the page asks again.
    private struct Dismissed: Error {}
    private var pending: [ObjectIdentifier: (id: Int, cancel: () -> Void)] = [:]

    init(profileId: UUID, isPrivate: Bool, store: PasskeyStoring = KeychainPasskeyStore.shared) {
        self.profileId = profileId
        self.isPrivate = isPrivate
        self.store = store
    }

    static func install(_ bridge: PasskeyBridge, in controller: WKUserContentController) {
        guard PasskeyPrefs.isOn() else { return }
        // Page world and document start (like GPC): the wrapper must exist before page scripts call navigator.credentials.
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: "axolotlPasskeys")
        let off = (try? JSONSerialization.data(withJSONObject: PasskeyPrefs.offSites())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        controller.addUserScript(WKUserScript(source: script.replacingOccurrences(of: "__OFF_SITES__", with: off),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String, let id = body["id"] as? Int,
              let webView = message.webView else { return (nil, nil) }
        let key = ObjectIdentifier(webView)
        if op == "cancel" {
            if pending[key]?.id == id { pending.removeValue(forKey: key)?.cancel() }
            return (nil, nil)
        }
        let conditional = body["conditional"] as? Bool == true
        do {
            let so = message.frameInfo.securityOrigin
            let origin = WebOrigin(scheme: so.protocol, host: so.host, port: so.port)
            // Same-origin frames only (crossOrigin is always false); a cross-origin iframe falls back to the site's other options.
            if !message.frameInfo.isMainFrame {
                guard let top = webView.url, top.scheme == origin.scheme, top.host == origin.host,
                      (top.port ?? 0) == origin.port || top.port == nil && [0, 80, 443].contains(origin.port) else { throw WebAuthnError.notAllowed }
            }
            guard PasskeyPrefs.isOn(host: origin.host), pending[key] == nil, let window = webView.window,
                  let json = (body["request"] as? String)?.data(using: .utf8),
                  let request = try? JSONDecoder().decode(PasskeyRequest.self, from: json) else { throw WebAuthnError.notAllowed }
            let rpId = try WebAuthn.relyingParty(request.rpId, for: origin)
            let auth = PasskeyAuthenticator(store: store, profile: profileId)
            let credential = op == "create"
                ? try await create(request, origin: origin, rpId: rpId, auth: auth, window: window, key: key, id: id)
                : try await get(request, origin: origin, rpId: rpId, auth: auth, window: window, key: key, id: id,
                                conditional: conditional, page: webView.url)
            return (["credential": credential], nil)
        } catch is Dismissed {
            return (["error": WebAuthnError.notAllowed.rawValue, "message": Self.message(.notAllowed), "dismissed": true], nil)
        } catch let error as WebAuthnError {
            return (["error": error.rawValue, "message": Self.message(error)], nil)
        } catch {
            return (["error": WebAuthnError.notAllowed.rawValue, "message": Self.message(.notAllowed)], nil)
        }
    }

    private func create(_ request: PasskeyRequest, origin: WebOrigin, rpId: String, auth: PasskeyAuthenticator,
                        window: NSWindow, key: ObjectIdentifier, id: Int) async throws -> [String: Any] {
        guard !isPrivate else { throw WebAuthnError.notAllowed } // a private window never stores anything
        try auth.validateCreate(request)
        let user = request.user?.name.flatMap { $0.isEmpty ? nil : $0 } ?? request.user?.displayName ?? "your account"
        let alert = NSAlert()
        alert.messageText = "Create a passkey for \(rpId)?"
        alert.informativeText = "You'll sign in to \(rpId) as \(user) with Touch ID or your Mac password. The passkey is saved in Axolotl on this Mac."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard await present(alert, in: window, key: key, id: id) == .alertFirstButtonReturn,
              await PasskeyAuthenticator.verifyUser(reason: "create a passkey for \(rpId)") else { throw WebAuthnError.notAllowed }
        return try auth.create(request, origin: origin, rpId: rpId) // excludeCredentials is checked after consent, as CTAP does
    }

    private func get(_ request: PasskeyRequest, origin: WebOrigin, rpId: String, auth: PasskeyAuthenticator, window: NSWindow,
                     key: ObjectIdentifier, id: Int, conditional: Bool, page: URL?) async throws -> [String: Any] {
        let found = auth.candidates(request, rpId: rpId)
        if found.isEmpty {
            if conditional { throw WebAuthnError.notAllowed } // autofill: nothing to offer, stay quiet
            await offerOtherBrowser(rpId: rpId, page: page, window: window, key: key, id: id)
            throw WebAuthnError.notAllowed
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(rpId) with a passkey?"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: found.map(Self.label))
        if found.count > 1 { alert.accessoryView = popup } else {
            alert.informativeText = "Sign in as \(Self.label(found[0])) with Touch ID or your Mac password."
        }
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: conditional ? "Not Now" : "Cancel")
        guard await present(alert, in: window, key: key, id: id) == .alertFirstButtonReturn else { throw Dismissed() }
        guard await PasskeyAuthenticator.verifyUser(reason: "sign in to \(rpId)") else { throw WebAuthnError.notAllowed }
        return try auth.assert(request, origin: origin, rpId: rpId, with: found[max(popup.indexOfSelectedItem, 0)])
    }

    /// The site wants a passkey Axolotl doesn't have (likely in Apple Passwords, which only entitled browsers reach).
    private func offerOtherBrowser(rpId: String, page: URL?, window: NSWindow, key: ObjectIdentifier, id: Int) async {
        let browser = Self.otherBrowser()
        let alert = NSAlert()
        alert.messageText = "This passkey is in Apple Passwords."
        alert.informativeText = "Axolotl can't reach it yet. Use the site's other sign-in options"
            + (browser.map { ", or open this page in \($0.name)." } ?? ".")
        if let browser { alert.addButton(withTitle: "Open in \(browser.name)") }
        alert.addButton(withTitle: browser == nil ? "OK" : "Cancel")
        if await present(alert, in: window, key: key, id: id) == .alertFirstButtonReturn, let browser, let page {
            NSWorkspace.shared.open([page], withApplicationAt: browser.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    static func otherBrowser() -> (name: String, url: URL)? {
        for (id, name) in [("com.brave.Browser", "Brave"), ("com.google.Chrome", "Chrome"), ("org.chromium.Chromium", "Chromium")] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return (name, url) }
        }
        return nil
    }

    private func present(_ alert: NSAlert, in window: NSWindow, key: ObjectIdentifier, id: Int) async -> NSApplication.ModalResponse {
        pending[key] = (id, { [weak window, weak alert] in if let alert { window?.endSheet(alert.window, returnCode: .cancel) } })
        defer { if pending[key]?.id == id { pending[key] = nil } }
        return await withCheckedContinuation { cont in alert.beginSheetModal(for: window) { cont.resume(returning: $0) } }
    }

    static func label(_ p: PasskeyRecord) -> String {
        p.displayName.isEmpty || p.displayName == p.userName ? (p.userName.isEmpty ? "Passkey" : p.userName) : "\(p.displayName) (\(p.userName))"
    }

    static func message(_ error: WebAuthnError) -> String {
        switch error {
        case .notAllowed: return "The operation either timed out or was not allowed."
        case .invalidState: return "A passkey for this account is already saved in Axolotl."
        case .security: return "The relying party ID is not valid for this origin."
        case .notSupported: return "Axolotl passkeys support only ES256 platform credentials."
        }
    }

    // Wraps navigator.credentials for publicKey requests only. Converts buffers to base64url for the native side and
    // builds PublicKeyCredential-shaped results (with toJSON) from the reply.
    static let script = #"""
    (function () {
        if (!window.isSecureContext || !navigator.credentials || window.__axolotlPasskeys) return;
        var host = location.hostname.replace(/^www\./, '');
        if (__OFF_SITES__.some(function (s) { return host === s || host.endsWith('.' + s); })) return;
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.axolotlPasskeys;
        if (!h) return;
        Object.defineProperty(window, '__axolotlPasskeys', { value: true });
        var post = h.postMessage.bind(h), stringify = JSON.stringify, creds = navigator.credentials;
        var nativeCreate = creds.create.bind(creds), nativeGet = creds.get.bind(creds), seq = 0;
        function b64(v) {
            var b = v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength), s = '';
            for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
            return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        }
        function buf(s) {
            if (s == null) return null;
            s = s.replace(/-/g, '+').replace(/_/g, '/');
            while (s.length % 4) s += '=';
            var bin = atob(s), b = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) b[i] = bin.charCodeAt(i);
            return b.buffer;
        }
        function ids(list) { return (list || []).map(function (c) { return b64(c.id); }); }
        function request(op, pk) {
            var r = { challenge: b64(pk.challenge) };
            if (op === 'create') {
                var sel = pk.authenticatorSelection || {};
                r.rpId = pk.rp && pk.rp.id;
                r.user = { id: b64(pk.user.id), name: pk.user.name, displayName: pk.user.displayName };
                r.algs = (pk.pubKeyCredParams || []).map(function (p) { return p.alg; });
                r.exclude = ids(pk.excludeCredentials);
                r.attachment = sel.authenticatorAttachment;
            } else {
                r.rpId = pk.rpId;
                r.allow = ids(pk.allowCredentials);
            }
            return stringify(r);
        }
        function wrap(o, C) {
            var t = C ? Object.create(C.prototype) : {};
            Object.keys(o).forEach(function (k) { Object.defineProperty(t, k, { value: o[k], enumerable: true }); });
            return t;
        }
        function credential(c) {
            var r = c.response, resp = { clientDataJSON: buf(r.clientDataJSON) }, created = !!r.attestationObject;
            if (created) {
                resp.attestationObject = buf(r.attestationObject);
                resp.getTransports = function () { return r.transports.slice(); };
                resp.getAuthenticatorData = function () { return buf(r.authenticatorData); };
                resp.getPublicKey = function () { return buf(r.publicKey); };
                resp.getPublicKeyAlgorithm = function () { return r.publicKeyAlgorithm; };
            } else {
                resp.authenticatorData = buf(r.authenticatorData);
                resp.signature = buf(r.signature);
                resp.userHandle = buf(r.userHandle);
            }
            return wrap({
                id: c.id, rawId: buf(c.id), type: 'public-key', authenticatorAttachment: c.authenticatorAttachment,
                response: wrap(resp, created ? window.AuthenticatorAttestationResponse : window.AuthenticatorAssertionResponse),
                getClientExtensionResults: function () { return {}; },
                toJSON: function () {
                    return { id: c.id, rawId: c.id, type: 'public-key', authenticatorAttachment: c.authenticatorAttachment,
                             response: r, clientExtensionResults: {} };
                }
            }, window.PublicKeyCredential);
        }
        function aborted(signal) { return signal.reason || new DOMException('The operation was aborted.', 'AbortError'); }
        function send(op, req, conditional) {
            var id = ++seq;
            return { id: id, reply: post({ op: op, id: id, request: req, conditional: conditional }) };
        }
        function modal(op, pk, signal) {
            var req = request(op, pk);
            return new Promise(function (resolve, reject) {
                var done = false, call = send(op, req, false);
                function finish(f, v) { if (!done) { done = true; clearTimeout(timer); f(v); } }
                function cancel(err) { post({ op: 'cancel', id: call.id }); finish(reject, err); }
                var timer = setTimeout(function () {
                    cancel(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'));
                }, Math.min(Math.max(pk.timeout || 300000, 30000), 600000));
                if (signal) signal.addEventListener('abort', function () { cancel(aborted(signal)); });
                call.reply.then(function (res) {
                    if (res && res.credential) finish(resolve, credential(res.credential));
                    else finish(reject, new DOMException(res && res.message || 'Not allowed.', res && res.error || 'NotAllowedError'));
                }, function () { finish(reject, new DOMException('Not allowed.', 'NotAllowedError')); });
            });
        }
        // mediation: "conditional" — offer saved passkeys when the user focuses a field marked autocomplete="… webauthn".
        function conditional(pk, signal) {
            var req = request('get', pk);
            return new Promise(function (resolve, reject) {
                var busy = null;
                function stop() { document.removeEventListener('focusin', onFocus, true); }
                function onFocus(e) {
                    var el = e.target;
                    if (busy || !el || !/\bwebauthn\b/i.test(el.getAttribute && el.getAttribute('autocomplete') || '')) return;
                    busy = send('get', req, true);
                    busy.reply.then(function (res) {
                        busy = null;
                        if (res && res.credential) { stop(); resolve(credential(res.credential)); }
                        else if (res && res.dismissed) stop();
                    }, function () { busy = null; });
                }
                document.addEventListener('focusin', onFocus, true);
                if (signal) signal.addEventListener('abort', function () {
                    stop();
                    if (busy) post({ op: 'cancel', id: busy.id });
                    reject(aborted(signal));
                });
            });
        }
        function run(op, options) {
            var signal = options.signal;
            if (signal && signal.aborted) return Promise.reject(aborted(signal));
            try {
                return op === 'get' && options.mediation === 'conditional' ? conditional(options.publicKey, signal)
                    : modal(op, options.publicKey, signal);
            } catch (e) { return Promise.reject(new TypeError('Invalid publicKey options.')); }
        }
        creds.create = function (options) { return options && options.publicKey ? run('create', options) : nativeCreate(options); };
        creds.get = function (options) { return options && options.publicKey ? run('get', options) : nativeGet(options); };
        if (window.PublicKeyCredential) {
            PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function () { return Promise.resolve(true); };
            PublicKeyCredential.isConditionalMediationAvailable = function () { return Promise.resolve(true); };
        }
    })();
    """#
}
