import AppKit
import Combine
import Foundation
import WebKit

/// Installed web extensions (WebKit's WKWebExtension: Chrome/Firefox/Safari
/// manifest v2 and v3). Unpacked copies live in Application Support; every
/// profile loads the enabled ones into its own controller.
final class ExtensionLibrary: ObservableObject {
    static let shared = ExtensionLibrary()

    struct Record: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var version: String
        var enabled: Bool
        /// Chrome Web Store id when installed from a store link.
        var storeID: String?
        var installedAt: Date
        /// Set for extensions that ship inside Luna (e.g. "ubolite").
        var builtInID: String?
    }

    /// Extensions bundled in Luna.app (Resources/BuiltInExtensions).
    struct BuiltIn {
        let id: String
        let folder: String
        let name: String
    }

    static let builtIns = [BuiltIn(id: "ubolite", folder: "uBOLite", name: "uBlock Origin Lite")]
    /// Built-ins the user removed; they aren't reinstalled.
    static let removedBuiltInsKey = "luna_removed_builtin_extensions"

    enum InstallError: LocalizedError {
        case noManifest
        case unreadable(String)
        case badStoreLink
        case download(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noManifest: return "That doesn't look like a web extension (no manifest.json)."
            case .unreadable(let msg): return "Couldn't load the extension: \(msg)"
            case .badStoreLink: return "Paste a Chrome Web Store link to an extension."
            case .download(let msg): return "Couldn't download the extension: \(msg)"
            case .cancelled: return "Installation cancelled."
            }
        }
    }

    @Published private(set) var records: [Record] = []
    /// Asks the user to approve an install (replaced in tests).
    var confirmInstall: (WKWebExtension) -> Bool = ExtensionLibrary.confirmInstallAlert

    let rootDirectory: URL
    private var indexURL: URL { rootDirectory.appendingPathComponent("extensions.json") }

    nonisolated deinit {}

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootDirectory = base.appendingPathComponent("Luna/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved.filter { FileManager.default.fileExists(atPath: directory(for: $0).path) }
        }
        installBuiltIns()
    }

    // MARK: - Built-ins

    /// Installs bundled extensions the first time, and refreshes them in place
    /// (same record, so their settings survive) when Luna ships a new version.
    /// Ones the user removed stay removed.
    func installBuiltIns(bundle: Bundle = .main) {
        let removed = Set(UserDefaults.standard.stringArray(forKey: Self.removedBuiltInsKey) ?? [])
        var changed = false
        for builtIn in Self.builtIns where !removed.contains(builtIn.id) {
            guard let source = bundle.resourceURL?
                    .appendingPathComponent("BuiltInExtensions/\(builtIn.folder)", isDirectory: true),
                  let version = Self.manifestVersion(at: source) else { continue }
            let existing = records.firstIndex { $0.builtInID == builtIn.id }
            if let i = existing, records[i].version == version { continue }
            let record = existing.map { records[$0] }
                ?? Record(id: UUID(), name: builtIn.name, version: version, enabled: true,
                          storeID: nil, installedAt: Date(), builtInID: builtIn.id)
            let dest = directory(for: record)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                print("ExtensionLibrary: couldn't install \(builtIn.name): \(error)")
                continue
            }
            if let i = existing {
                records[i].version = version
                // Reload with the new files on next sync.
                records[i].installedAt = Date()
            } else {
                records.insert(record, at: 0)
            }
            changed = true
        }
        if changed { save() }
    }

    static func manifestVersion(at dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    func directory(for record: Record) -> URL {
        rootDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
    }

    var enabledRecords: [Record] { records.filter(\.enabled) }

    // MARK: - Install

    /// Installs from an unpacked folder, a .zip/.xpi, or a .crx file.
    func install(from source: URL) async throws -> Record {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let staging = try makeStagingDirectory()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
        if isDir.boolValue {
            try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent("ext"))
        } else {
            try unpackArchive(Data(contentsOf: source), into: staging.appendingPathComponent("ext"))
        }
        return try await finishInstall(staging: staging, storeID: nil)
    }

    /// Downloads and installs an extension from a Chrome Web Store link.
    func install(storeLink: String) async throws -> Record {
        guard let id = Self.storeID(in: storeLink) else { throw InstallError.badStoreLink }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "140.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw InstallError.download("the store didn't return the extension")
        }
        let staging = try makeStagingDirectory()
        try unpackArchive(data, into: staging.appendingPathComponent("ext"))
        return try await finishInstall(staging: staging, storeID: id)
    }

    static func storeID(in link: String) -> String? {
        guard let range = link.range(of: "[a-p]{32}", options: .regularExpression) else { return nil }
        return String(link[range])
    }

    private func finishInstall(staging: URL, storeID: String?) async throws -> Record {
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let root = Self.manifestRoot(in: staging.appendingPathComponent("ext")) else { throw InstallError.noManifest }
        let ext: WKWebExtension
        do {
            ext = try await WKWebExtension(resourceBaseURL: root)
        } catch {
            throw InstallError.unreadable(error.localizedDescription)
        }
        guard confirmInstall(ext) else { throw InstallError.cancelled }
        // A store reinstall replaces the old copy only now that the new one is confirmed, and keeps
        // its id so the extension's storage carries over.
        let existing = storeID.flatMap { id in records.firstIndex { $0.storeID == id } }
        let record = Record(id: existing.map { records[$0].id } ?? UUID(), name: ext.displayName ?? "Extension",
                            version: ext.displayVersion ?? ext.version ?? "",
                            enabled: true, storeID: storeID, installedAt: Date(), builtInID: nil)
        let dir = directory(for: record)
        if existing != nil, FileManager.default.fileExists(atPath: dir.path) {
            _ = try FileManager.default.replaceItemAt(dir, withItemAt: root)
        } else {
            try FileManager.default.moveItem(at: root, to: dir)
        }
        // Publishing the list without it first makes ExtensionHost unload the old version.
        if let existing { records.remove(at: existing) }
        records.append(record)
        save()
        return record
    }

    // MARK: - Manage

    func setEnabled(_ record: Record, _ enabled: Bool) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[i].enabled = enabled
        save()
    }

    func remove(_ record: Record) {
        if let builtIn = record.builtInID {
            var removed = UserDefaults.standard.stringArray(forKey: Self.removedBuiltInsKey) ?? []
            if !removed.contains(builtIn) { removed.append(builtIn) }
            UserDefaults.standard.set(removed, forKey: Self.removedBuiltInsKey)
        }
        records.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: directory(for: record))
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: indexURL, options: .atomic) }
    }

    // MARK: - Helpers

    private func makeStagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luna-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The folder holding manifest.json (archives sometimes wrap it in one folder).
    static func manifestRoot(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
        let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return children.first { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }

    /// Strips a CRX header (v2 or v3) so the rest is a plain zip; zips pass through.
    static func zipPayload(_ data: Data) -> Data {
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8) else { return data }
        func u32(_ offset: Int) -> Int {
            data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4))
                .withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        }
        let version = u32(4)
        let start = version == 2 ? 16 + u32(8) + u32(12) : 12 + u32(8)
        guard start < data.count else { return data }
        return data.subdata(in: (data.startIndex + start)..<data.endIndex)
    }

    private func unpackArchive(_ data: Data, into destination: URL) throws {
        let zipURL = destination.deletingLastPathComponent().appendingPathComponent("package.zip")
        try Self.zipPayload(data).write(to: zipURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallError.unreadable("the archive couldn't be opened") }
    }

    /// Shows what the extension asks for before installing it.
    static func confirmInstallAlert(_ ext: WKWebExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(ext.displayName ?? "this extension")”?"
        var lines: [String] = []
        if let desc = ext.displayDescription, !desc.isEmpty { lines.append(desc) }
        let hosts = ext.allRequestedMatchPatterns.map(\.string).sorted()
        if ext.allRequestedMatchPatterns.contains(where: { $0.matchesAllHosts }) || hosts.contains("<all_urls>") {
            lines.append("It can read and change content on all websites.")
        } else if !hosts.isEmpty {
            lines.append("It can read and change content on: " + hosts.prefix(6).joined(separator: ", ") + (hosts.count > 6 ? "…" : ""))
        }
        let permissions = ext.requestedPermissions.map(\.rawValue).sorted()
        if !permissions.isEmpty { lines.append("Permissions: " + permissions.joined(separator: ", ")) }
        alert.informativeText = lines.joined(separator: "\n\n")
        if let icon = ext.icon(for: CGSize(width: 64, height: 64)) { alert.icon = icon }
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
