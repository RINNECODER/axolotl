import SwiftUI

/// Settings → General → Search engine: the default engine (built-in or custom) and site search keywords.
struct SearchEngineSettings: View {
    @AppStorage(SearchEngine.defaultsKey) private var selection = SearchEngine.google.rawValue
    @State private var engines = CustomSearchEngine.load()
    @State private var name = ""
    @State private var keyword = ""
    @State private var template = ""

    var body: some View {
        SettingsCard("Search engine") {
            SettingsMenuRow("Search engine", subtitle: "Engine for searches from the address bar and start page.",
                            selection: Binding(get: { selection }, set: {
                                RegistrySettings.willChange("search.engine")
                                selection = $0
                            }),
                            options: SearchEngine.allCases.map { .init($0.rawValue, $0.title) }
                                + engines.map { .init($0.selectionValue, $0.name) })
            RegistryToggle("search.suggestions")
        }

        SettingsCard("Site search", footer: "Type a keyword and a space (or Tab) in the address bar, then your search: \"yt cats\". Use %s where the search goes.") {
            ForEach(engines) { engine in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.name).font(.system(size: 13))
                        Text("\(engine.keyword) · \(engine.template)")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) { save(engines.filter { $0.id != engine.id }) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                        .accessibilityLabel("Remove \(engine.name)")
                }
                .settingsRowPadding()
            }
            SettingsContentRow {
                HStack(spacing: 8) {
                    TextField("Name", text: $name, prompt: Text("Name"))
                        .textFieldStyle(SettingsTextFieldStyle()).frame(maxWidth: 140)
                    TextField("Keyword", text: $keyword, prompt: Text("Keyword"))
                        .textFieldStyle(SettingsTextFieldStyle()).frame(maxWidth: 90)
                    TextField("URL with %s", text: $template, prompt: Text(verbatim: "https://example.com/search?q=%s"))
                        .textFieldStyle(SettingsTextFieldStyle())
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.settingsProminent)
                        .disabled(!canAdd)
                }
            }
        }
    }

    private var trimmed: (name: String, keyword: String, template: String) {
        (name.trimmingCharacters(in: .whitespaces), keyword.trimmingCharacters(in: .whitespaces).lowercased(),
         template.trimmingCharacters(in: .whitespaces))
    }

    private var canAdd: Bool {
        let t = trimmed
        return !t.name.isEmpty && CustomSearchEngine.isValidKeyword(t.keyword) && CustomSearchEngine.isValidTemplate(t.template)
            && !engines.contains { $0.keyword.lowercased() == t.keyword }
    }

    private func add() {
        guard canAdd else { return }
        let t = trimmed
        save(engines + [CustomSearchEngine(name: t.name, keyword: t.keyword, template: t.template)])
        name = ""; keyword = ""; template = ""
    }

    private func save(_ list: [CustomSearchEngine]) {
        CustomSearchEngine.save(list)
        engines = list
        selection = UserDefaults.standard.string(forKey: SearchEngine.defaultsKey) ?? SearchEngine.google.rawValue
    }
}
