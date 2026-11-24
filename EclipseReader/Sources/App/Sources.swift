import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - What you're into (onboarding)

/// The kinds of content you chose in the setup, and where you like it from. Drives Browse, the library tabs
/// and the launch card.
enum Interests {
    static let categoriesKey = "interestCategories"
    static let originsKey = "interestOrigins"
    static let rawsKey = "interestRaws"
    /// Countries of origin (AniList codes): Japan, Korea, China, Taiwan.
    static let allOrigins: [(code: String, name: String)] = [("JP", "Japan"), ("KR", "Korea"), ("CN", "China"), ("TW", "Taiwan")]

    /// Everything with pictures until you choose; novels are an option you turn on.
    static let pictureCategories: Set<SourceCategory> = [.manga, .manhwa, .manhua, .webtoons, .comics]
    /// The kinds you chose. Novels follow their own switch (Features.novelsKey), so turning novels on or off anywhere counts.
    static var categories: Set<SourceCategory> {
        get {
            // Stored as "manga,manhwa,…" (a plain string, so views can watch it with @AppStorage).
            var chosen = UserDefaults.standard.string(forKey: categoriesKey).map {
                Set($0.split(separator: ",").compactMap { SourceCategory(rawValue: String($0)) })
            } ?? pictureCategories
            chosen.remove(.novels)
            if Features.novelsOn { chosen.insert(.novels) }
            return chosen
        }
        set {
            UserDefaults.standard.set(SourceCategory.allCases.filter { newValue.contains($0) && $0 != .novels }.map(\.rawValue).joined(separator: ","),
                                      forKey: categoriesKey)
            UserDefaults.standard.set(newValue.contains(.novels), forKey: Features.novelsKey)
        }
    }
    static var origins: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: originsKey) ?? allOrigins.map(\.code)) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: originsKey) }
    }
    /// Show untranslated (raw) works too, read with on-device translation.
    static var raws: Bool {
        get { UserDefaults.standard.object(forKey: rawsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rawsKey) }
    }
}

// MARK: - Sources in the library model

extension LibraryModel {
    /// The bundled destinations (Resources/DefaultSources.json).
    static let bundledSources: [SavedSite] = {
        guard let url = Bundle.main.url(forResource: "DefaultSources", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? SourceManifest.decode(data)) ?? []
    }()

    /// Every source you have, in your order (bundled ones included).
    var sources: [SavedSite] { state.sites ?? [] }
    /// The source an address belongs to.
    func source(for url: URL) -> SavedSite? { sources.first { $0.owns(url) } }
    /// Read this address through the in-app browser's session (a site you signed in to there).
    func usesBrowserSession(_ url: URL) -> Bool { source(for: url)?.browserSession == true }

    /// Adds the bundled destinations you don't have yet (and haven't removed). Runs at every launch, so new
    /// entries in an update appear too.
    func seedBundledSources() {
        var list = state.sites ?? []
        let removed = Set(state.removedBundled ?? [])
        var changed = false
        for bundled in Self.bundledSources {
            guard let id = bundled.bundledID, !removed.contains(id) else { continue }
            if let i = list.firstIndex(where: { $0.bundledID == id || ($0.bundledID == nil && $0.owns(bundled.url)) }) {
                // A site you saved yourself that is also bundled: keep your name and settings, learn its category.
                if list[i].bundledID == nil {
                    list[i].bundledID = id
                    if list[i].category == nil { list[i].category = bundled.category }
                    if list[i].note == nil { list[i].note = bundled.note }
                    list[i].native = bundled.native
                    changed = true
                }
                continue
            }
            list.append(bundled)
            changed = true
        }
        if changed { state.sites = list; save() }
    }

    func updateSource(_ site: SavedSite) {
        guard var list = state.sites, let i = list.firstIndex(where: { $0.id == site.id }) else { return }
        list[i] = site
        state.sites = list
        save()
    }
    /// Changes a source's address (keeps its place and settings).
    func moveSource(_ site: SavedSite, to url: URL) {
        guard WebLink.publicHTTPS(url), var list = state.sites, let i = list.firstIndex(where: { $0.id == site.id }) else { return }
        list[i].url = url
        state.sites = list
        save()
    }
    func reorderSources(from offsets: IndexSet, to destination: Int, within visible: [SavedSite]) {
        var list = state.sites ?? []
        var subset = visible
        subset.move(fromOffsets: offsets, toOffset: destination)
        // Put the reordered ones back into the slots they occupied in the full list.
        let slots = list.indices.filter { i in visible.contains { $0.id == list[i].id } }
        for (slot, site) in zip(slots, subset) { list[slot] = site }
        state.sites = list
        save()
    }
    func removeSource(_ site: SavedSite) {
        if let id = site.bundledID {
            var removed = state.removedBundled ?? []
            if !removed.contains(id) { removed.append(id) }
            state.removedBundled = removed
        }
        state.sites = (state.sites ?? []).filter { $0.id != site.id }
        save()
    }
    /// Puts back the bundled destinations you removed.
    func restoreBundledSources() {
        state.removedBundled = []
        seedBundledSources()
        save()
    }
    /// Adds sources from a pasted or shared list. Returns how many were new.
    @discardableResult
    func addSources(_ sites: [SavedSite], category: SourceCategory?) -> Int {
        var list = state.sites ?? []
        var added = 0
        for var site in sites where WebLink.publicHTTPS(site.url) && !list.contains(where: { $0.owns(site.url) }) {
            if site.category == nil { site.category = category }
            list.append(site)
            added += 1
        }
        if added > 0 { state.sites = list; save() }
        return added
    }

    // MARK: Source lists you subscribe to

    static let listSubscriptionsKey = "sourceListSubscriptions"
    var sourceListSubscriptions: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.listSubscriptionsKey) ?? []).compactMap(URL.init(string:))
    }
    /// Reads a list at an address (a text file, a gist, a page with one address per line) and adds its sites.
    /// Subscribed lists are read again at launch, so updates to the list show up.
    func subscribeSourceList(_ url: URL, category: SourceCategory?) async throws -> Int {
        let sites = try await Self.fetchSourceList(url)
        guard !sites.isEmpty else { throw SourceError.unsupportedStructure }
        var subscriptions = sourceListSubscriptions.map(\.absoluteString)
        if !subscriptions.contains(url.absoluteString) { subscriptions.append(url.absoluteString) }
        UserDefaults.standard.set(subscriptions, forKey: Self.listSubscriptionsKey)
        return addSources(sites, category: category)
    }
    func unsubscribeSourceList(_ url: URL) {
        UserDefaults.standard.set(sourceListSubscriptions.map(\.absoluteString).filter { $0 != url.absoluteString }, forKey: Self.listSubscriptionsKey)
    }
    func refreshSourceLists() async {
        for url in sourceListSubscriptions {
            if let sites = try? await Self.fetchSourceList(url) { addSources(sites, category: nil) }
        }
    }
    static func fetchSourceList(_ url: URL) async throws -> [SavedSite] {
        guard WebLink.publicHTTPS(url) else { throw SourceError.insecureURL }
        var address = url
        // A GitHub gist or file page: read the raw text.
        if url.host == "gist.github.com", !url.path.hasSuffix("/raw") { address = url.appendingPathComponent("raw") }
        if url.host == "github.com", url.path.contains("/blob/"),
           let raw = URL(string: url.absoluteString.replacingOccurrences(of: "github.com", with: "raw.githubusercontent.com")
               .replacingOccurrences(of: "/blob/", with: "/")) { address = raw }
        let (data, response) = try await URLSession.shared.data(from: address)
        if let http = response as? HTTPURLResponse { try HTTPPolicy.validate(status: http.statusCode) }
        guard data.count < 2_000_000, let text = String(data: data, encoding: .utf8) else { throw SourceError.unsupportedStructure }
        let plain = text.contains("<html") || text.contains("<body") ? LinkedSource.plain(text.replacingOccurrences(of: "<br", with: "\n<br")
            .replacingOccurrences(of: "</p>", with: "\n").replacingOccurrences(of: "</li>", with: "\n")) : text
        return SourceManifest.parseList(plain)
    }
}

// MARK: - Browser sessions

/// Sign-ins live in the in-app browser (WebKit's own store). This only signs you out of one site there.
@MainActor
enum SiteSessions {
    /// WebKit names each site's data by its registrable domain ("bbc.co.uk"), which the source's host ends with.
    static func matches(_ domain: String, _ site: SavedSite) -> Bool {
        let host = site.url.host?.lowercased() ?? ""
        let d = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return !d.isEmpty && (host == d || host.hasSuffix("." + d) || d.hasSuffix("." + host))
    }
    static func signOut(of site: SavedSite) async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { matches($0.displayName, site) })
        // Cookies set for a parent domain are listed under it; remove those too.
        let cookies = await store.httpCookieStore.allCookies()
        for cookie in cookies where matches(cookie.domain, site) { await store.httpCookieStore.deleteCookie(cookie) }
    }
    /// Whether the browser holds any cookies for the site (you have visited, and maybe signed in).
    static func hasCookies(for site: SavedSite) async -> Bool {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies().contains { matches($0.domain, site) }
    }
}

// MARK: - Sources page (Browse › Sources)

/// Every source, grouped by what it offers: edit, hide, remove, reorder and favourite; add your own or a whole list.
struct SourcesPage: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var editing: SavedSite?
    @State private var importing = false
    @State private var adding = false
    @State private var showHidden = false
    var body: some View {
        List {
            Section {
                Button { adding = true } label: { Label("Add a source", systemImage: "plus.circle") }
                Button { importing = true } label: { Label("Add a list of sources…", systemImage: "list.bullet.rectangle") }
            } footer: {
                Text("Any website works: open it from here, sign in on the site if it needs it, and add series from its pages.")
            }
            let favorites = model.sources.filter { $0.favorite == true && (showHidden || $0.hidden != true) }
            if !favorites.isEmpty {
                Section("Favourites") { ForEach(favorites) { row($0) } }
            }
            ForEach(SourceCategory.allCases) { category in
                let sites = model.sources.filter { $0.category == category && (showHidden || $0.hidden != true) }
                if !sites.isEmpty {
                    Section(category.title) {
                        ForEach(sites) { row($0) }
                            .onMove { model.reorderSources(from: $0, to: $1, within: sites) }
                    }
                }
            }
            let other = model.sources.filter { $0.category == nil && (showHidden || $0.hidden != true) }
            if !other.isEmpty {
                Section("Other sites") {
                    ForEach(other) { row($0) }.onMove { model.reorderSources(from: $0, to: $1, within: other) }
                }
            }
            if !model.sourceListSubscriptions.isEmpty {
                Section {
                    ForEach(model.sourceListSubscriptions, id: \.self) { url in
                        Label(url.host.map { $0 + url.path } ?? url.absoluteString, systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote).lineLimit(1)
                            .swipeActions { Button("Unsubscribe", role: .destructive) { model.unsubscribeSourceList(url) } }
                    }
                } header: { Text("Subscribed lists") } footer: { Text("Read again at every launch, so new sites in a list show up.") }
            }
            Section {
                Toggle("Show hidden sources", isOn: $showHidden)
                if !(model.state.removedBundled ?? []).isEmpty {
                    Button("Restore removed built-in sources") { model.restoreBundledSources() }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Eclipse.surface)
        .navigationTitle("Sources")
        .toolbar { EditButton() }
        .sheet(item: $editing) { site in SourceEditSheet(site: site).environmentObject(model) }
        .sheet(isPresented: $importing) { SourceListImportSheet().environmentObject(model) }
        .sheet(isPresented: $adding) {
            SourceEditSheet(site: SavedSite(name: "", url: URL(string: "https://example.com/")!), isNew: true).environmentObject(model)
        }
    }
    private func row(_ site: SavedSite) -> some View {
        Button { editing = site } label: {
            HStack(spacing: 12) {
                Image(systemName: site.category?.symbol ?? "globe").frame(width: 26).foregroundStyle(Eclipse.highlight)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(site.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        if site.favorite == true { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                        if site.browserSession == true { Image(systemName: "person.crop.circle.badge.checkmark").font(.caption2).foregroundStyle(.green) }
                        if site.hidden == true { Text("Hidden").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(site.note ?? site.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.removeSource(site) } label: { Label("Remove", systemImage: "trash") }
            Button { var s = site; s.hidden = !(site.hidden ?? false); model.updateSource(s) } label: {
                Label(site.hidden == true ? "Show" : "Hide", systemImage: site.hidden == true ? "eye" : "eye.slash")
            }.tint(.gray)
        }
        .swipeActions(edge: .leading) {
            Button { var s = site; s.favorite = !(site.favorite ?? false); model.updateSource(s) } label: {
                Label(site.favorite == true ? "Unfavourite" : "Favourite", systemImage: "star")
            }.tint(.yellow)
        }
    }
}

/// One source's settings: name, address, what it offers, reading style, browser sign-in.
struct SourceEditSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State var site: SavedSite
    var isNew = false
    @State private var address = ""
    @State private var browsing: BrowseTarget?
    @State private var signedIn: Bool?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $site.name)
                    TextField("https://…", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } footer: {
                    if let note = site.note { Text(note) }
                }
                Section {
                    Picker("Offers", selection: Binding(get: { site.category }, set: { site.category = $0; if $0 == .novels { site.style = nil } })) {
                        Text("Work it out").tag(SourceCategory?.none)
                        ForEach(SourceCategory.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    if site.category != .novels {
                        Picker("Reads as", selection: $site.style) {
                            Text("Detect").tag(ReadingStyle?.none)
                            ForEach(ReadingStyle.allCases.filter { $0 != .automatic }, id: \.self) { Text($0.title).tag(Optional($0)) }
                        }
                    }
                } footer: {
                    Text(site.category == .novels ? "Series added from this site read as text, in the novel reader."
                         : "Series added from this site start in this reading style; change any series on its page.")
                }
                if !isNew {
                    Section {
                        Button { browsing = BrowseTarget(url: site.url) } label: { Label("Open the site to sign in…", systemImage: "person.crop.circle") }
                        Toggle(isOn: Binding(get: { site.browserSession == true }, set: { site.browserSession = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Read with my browser sign-in")
                                Text("Pages from this site load through the in-app browser, so what your account can see opens in the reader too. Your sign-in never leaves the browser.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            Task {
                                await SiteSessions.signOut(of: site)
                                signedIn = false
                                message = "Signed out of \(site.host) in the browser."
                            }
                        } label: { Label("Sign out of this site", systemImage: "rectangle.portrait.and.arrow.right") }
                    } header: { Text("Account") } footer: {
                        if let message { Text(message) }
                        else if let signedIn { Text(signedIn ? "The browser has a session for this site." : "No session for this site in the browser yet.") }
                    }
                    Section {
                        Toggle("Favourite", isOn: Binding(get: { site.favorite == true }, set: { site.favorite = $0 }))
                        Toggle("Hide from Browse", isOn: Binding(get: { site.hidden == true }, set: { site.hidden = $0 }))
                        Button("Remove source", role: .destructive) { model.removeSource(site); dismiss() }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Eclipse.surface)
            .navigationTitle(isNew ? "New source" : site.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(isNew ? "Add" : "Save") { save() }.disabled(WebLink.parse(address) == nil) }
            }
            .onAppear { address = isNew ? "" : site.url.absoluteString }
            .task { if !isNew { signedIn = await SiteSessions.hasCookies(for: site) } }
            .fullScreenCover(item: $browsing) { target in MangaBrowserView(start: target.url).environmentObject(model) }
        }
    }
    private func save() {
        guard let url = WebLink.parse(address) else { return }
        if site.name.trimmingCharacters(in: .whitespaces).isEmpty { site.name = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Site" }
        if isNew {
            site.url = url
            model.addSources([site], category: site.category)
        } else {
            if url != site.url { model.moveSource(site, to: url); site.url = url }
            model.updateSource(site)
        }
        dismiss()
    }
}

/// Paste a list of sites, open a text file, or subscribe to a list at an address.
struct SourceListImportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var link = ""
    @State private var category: SourceCategory?
    @State private var picking = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("These offer", selection: $category) {
                        Text("Work it out").tag(SourceCategory?.none)
                        ForEach(SourceCategory.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                }
                Section {
                    TextEditor(text: $text).frame(minHeight: 140).font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add these") {
                        let sites = SourceManifest.parseList(text)
                        let added = model.addSources(sites, category: category)
                        message = sites.isEmpty ? "No addresses found in that text." : "Added \(added) of \(sites.count) (the rest were already there)."
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Open a text file…") { picking = true }
                } header: { Text("Paste addresses") } footer: {
                    Text("One per line. “Name — address” keeps the name. Lines starting with # are skipped.")
                }
                Section {
                    TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button {
                        guard let url = WebLink.parse(link) else { message = "That isn't a web address."; return }
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                let added = try await model.subscribeSourceList(url, category: category)
                                message = "Subscribed. Added \(added) new source\(added == 1 ? "" : "s")."
                            } catch {
                                message = "Couldn’t read a list there: \(error.localizedDescription)"
                            }
                        }
                    } label: { HStack { Text("Subscribe"); if busy { Spacer(); ProgressView() } } }
                    .disabled(busy || link.isEmpty)
                } header: { Text("Subscribe to a list") } footer: {
                    Text("A text file, gist or page listing sites. It's read again at every launch, so additions to the list show up here.")
                }
                if let message { Section { Text(message).font(.callout) } }
            }
            .scrollContentBackground(.hidden).background(Eclipse.surface)
            .navigationTitle("Add sources").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText, .text, .json, .html]) { result in
                guard case .success(let file) = result else { return }
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: file), let content = String(data: data, encoding: .utf8) { text = content }
            }
        }
    }
}
