// Luna — native sign-in sheet for HTTP Basic/Digest authentication challenges.
import AppKit

enum AuthChallengeSheet {
    /// Asks for a user name and password for `space`; calls back with nil when cancelled.
    static func present(for space: URLProtectionSpace, previous: URLCredential?, in window: NSWindow?,
                        completion: @escaping (URLCredential?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Sign in"
        let site = space.port == 0 || space.port == 80 || space.port == 443 ? space.host : "\(space.host):\(space.port)"
        var info = "\(space.protocol ?? "https")://\(site) requires a user name and password."
        if !space.receivesCredentialSecurely {
            info += " Your connection to this site isn't private."
        }
        if let realm = space.realm, !realm.isEmpty { info += "\n\(realm)" }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "User name"
        user.stringValue = previous?.user ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password
        user.nextKeyView = password

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            completion(URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
