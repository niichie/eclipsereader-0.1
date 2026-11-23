import SwiftUI
import Security
import AuthenticationServices

/// The AniList sign-in token, kept in the iOS Keychain (never in backups or the library file).
enum TokenVault {
    private static let service = "com.personal.eclipse.reader.anilist"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ token: String?) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(match as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// AniList tracking: sign in once, link series, and finished chapters update your AniList list.
@MainActor
enum AniList {
    static let clientKey = "aniListClientID"
    static let syncKey = "aniListSync"
    static var clientID: String { UserDefaults.standard.string(forKey: clientKey) ?? "" }
    static var signedIn: Bool { TokenVault.read() != nil }

    static func post(_ query: String, variables: [String: any Sendable] = [:], auth: Bool = true) async throws -> Data {
        var request = URLRequest(url: AniListAPI.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            guard let token = TokenVault.read() else { throw AniListError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try AniListAPI.body(query, variables: variables)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 { throw AniListError.service("AniList signed you out. Sign in again in Settings › Tracking.") }
        if let http = response as? HTTPURLResponse, http.statusCode == 429 { throw AniListError.service("AniList is rate limiting requests. Try again in a minute.") }
        return data
    }

    /// Signs in through AniList's own page and returns your AniList name.
    static func signIn(using session: WebAuthenticationSession, model: LibraryModel) async throws -> String {
        guard let url = AniListAPI.authorizeURL(clientID: clientID) else {
            throw AniListError.service("Paste your AniList client ID (a number) first.")
        }
        let callback = try await session.authenticate(using: url, callbackURLScheme: AniListAPI.callbackScheme)
        guard let token = AniListAPI.token(fromCallback: callback) else {
            throw AniListError.service("AniList didn't sign you in. Check the client's redirect URL is \(AniListAPI.redirect).")
        }
        TokenVault.write(token.token)
        let name = try AniListAPI.parseViewer(try await post(AniListAPI.viewerQuery))
        model.state.aniListUser = name
        model.state.aniListToken = nil
        model.save()
        return name
    }

    static func signOut(model: LibraryModel) {
        TokenVault.write(nil)
        model.state.aniListUser = nil
        model.save()
    }

    static func search(_ title: String) async throws -> [AniListMedia] {
        try AniListAPI.parseSearch(try await post(AniListAPI.searchQuery, variables: ["search": title], auth: false))
    }

    static func link(_ series: MangaSeries, to media: AniListMedia?, model: LibraryModel) {
        var links = model.state.aniListLinks ?? [:]
        links[series.id] = media?.id
        model.state.aniListLinks = links
        model.save()
    }
    static func linkedID(_ series: MangaSeries, model: LibraryModel) -> Int? { model.state.aniListLinks?[series.id] }

    /// Pushes the highest chapter you've finished in this series to AniList. Never moves progress backwards.
    static func sync(_ series: MangaSeries, model: LibraryModel) async throws -> Int? {
        guard let id = linkedID(series, model: model) else { return nil }
        let read = series.chapters.filter { model.state.progress[$0.id]?.completed == true }
            .compactMap { AniListAPI.progress(for: $0.number) }.max()
        guard let read else { return nil }
        let current = try AniListAPI.parseEntry(try await post(AniListAPI.entryQuery, variables: ["id": id]))
        guard let change = AniListAPI.update(after: read, current: current.entry, total: current.chapters) else { return current.entry?.progress }
        let reply = try await post(AniListAPI.saveMutation, variables: ["id": id, "progress": change.progress, "status": change.status])
        if let message = AniListAPI.error(in: reply) { throw AniListError.service(message) }
        return change.progress
    }

    /// Called whenever a chapter is finished.
    static func chapterFinished(_ chapter: Chapter, model: LibraryModel) async {
        guard UserDefaults.standard.object(forKey: syncKey) as? Bool ?? true, signedIn,
              model.state.incognito != true,
              let series = model.series(id: model.seriesID(for: chapter)), linkedID(series, model: model) != nil else { return }
        _ = try? await sync(series, model: model)
    }
}

// MARK: - Settings › Tracking

struct TrackingSettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.webAuthenticationSession) private var webAuth
    @AppStorage(AniList.clientKey) private var clientID = ""
    @AppStorage(AniList.syncKey) private var sync = true
    @State private var working = false
    @State private var message: String?
    @State private var signedIn = AniList.signedIn
    var body: some View {
        Form {
            Section {
                if signedIn, let user = model.state.aniListUser {
                    LabeledContent("Signed in as", value: user)
                    Toggle("Update AniList when I finish a chapter", isOn: $sync)
                    Button("Sync every linked series now") { syncAll() }.disabled(working)
                    Button("Sign out", role: .destructive) { AniList.signOut(model: model); signedIn = false }
                } else {
                    TextField("AniList client ID", text: $clientID)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button {
                        working = true; message = nil
                        Task {
                            defer { working = false }
                            do {
                                let name = try await AniList.signIn(using: webAuth, model: model)
                                signedIn = true; message = "Signed in as \(name)."
                            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                            } catch { message = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Label("Sign in with AniList", systemImage: "person.crop.circle.badge.checkmark")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || AniListAPI.authorizeURL(clientID: clientID) == nil)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("AniList")
            } footer: {
                if !signedIn {
                    Text("""
                    AniList needs a client of your own (it's free):
                    1. On anilist.co, open Settings › Developer and create a new client.
                    2. Set its redirect URL to \(AniListAPI.redirect)
                    3. Paste the client's ID above and sign in.
                    Then open a series, tap ⋯ › Track on AniList, and finished chapters update your list.
                    """)
                } else {
                    Text("Linked series: \(model.state.aniListLinks?.count ?? 0). Progress only ever moves forward, and nothing is sent in incognito.")
                }
            }
        }
        .navigationTitle("Tracking")
        .scrollContentBackground(.hidden).background(EclipseBackground())
    }
    private func syncAll() {
        working = true; message = nil
        Task {
            defer { working = false }
            var done = 0
            for (id, _) in model.state.aniListLinks ?? [:] {
                guard let series = model.series(id: id) else { continue }
                do { if try await AniList.sync(series, model: model) != nil { done += 1 } }
                catch { message = error.localizedDescription; return }
            }
            message = "Synced \(done) series."
        }
    }
}

// MARK: - Link a series

struct AniListLinkSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let series: MangaSeries
    @State private var query = ""
    @State private var results: [AniListMedia] = []
    @State private var loading = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                if !AniList.signedIn {
                    Text("Sign in to AniList in Settings › Tracking to keep your list up to date.").foregroundStyle(.secondary)
                }
                if let linked = AniList.linkedID(series, model: model) {
                    Section {
                        Label("Linked to AniList #\(linked)", systemImage: "link")
                        Button("Sync progress now") {
                            Task {
                                do { message = try await AniList.sync(series, model: model).map { "AniList progress: \($0)" } ?? "Nothing finished yet." }
                                catch { message = error.localizedDescription }
                            }
                        }
                        Button("Unlink", role: .destructive) { AniList.link(series, to: nil, model: model) }
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Section(results.isEmpty ? "" : "Pick the matching manga") {
                    if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                    ForEach(results) { media in
                        Button {
                            AniList.link(series, to: media, model: model)
                            Task { _ = try? await AniList.sync(series, model: model) }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                CoverView(url: media.cover, referer: nil)
                                    .frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(media.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text([media.format?.replacingOccurrences(of: "_", with: " ").capitalized,
                                          media.year.map(String.init), media.chapters.map { "\($0) chapters" }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if AniList.linkedID(series, model: model) == media.id {
                                    Image(systemName: "checkmark").foregroundStyle(Eclipse.highlight)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search AniList")
            .onSubmit(of: .search) { Task { await run() } }
            .navigationTitle("Track on AniList")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { if query.isEmpty { query = series.title; await run() } }
        }
    }
    private func run() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        loading = true; message = nil
        defer { loading = false }
        do { results = try await AniList.search(term) } catch { message = error.localizedDescription }
    }
}
