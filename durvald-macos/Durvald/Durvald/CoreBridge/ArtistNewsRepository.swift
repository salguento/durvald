import Foundation
import Observation

@MainActor @Observable
final class ArtistNewsRepository {
    var query = ""
    var unseenOnly = false
    var kind: ArtistNewsKind?
    var sortBy = "date"
    var descending = true
    private(set) var items: [ArtistNewsItem] = []
    private(set) var followed: [FollowedArtist] = []
    private(set) var total: UInt64 = 0
    private(set) var nextOffset: UInt64?
    private(set) var loading = false
    private(set) var updating = false
    private(set) var currentArtist: String?
    private(set) var pending: Set<Int64> = []
    private(set) var error: String?
    private(set) var initialized = false
    @ObservationIgnored private var initializing: ObjectIdentifier?
    @ObservationIgnored private var coreID: ObjectIdentifier?
    @ObservationIgnored private var readToken = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshToken = UUID()
    var request: String { "\(query)|\(unseenOnly)|\(String(describing: kind))|\(sortBy)|\(descending)" }

    func initialize(core: DurvaldCore, legacyIDs: String) async {
        let id = ObjectIdentifier(core)
        guard initializing != id, !(initialized && coreID == id) else { return }
        initializing = id
        defer { if initializing == id { initializing = nil } }
        if coreID != id {
            cancelRefresh(); readToken = UUID(); coreID = id; initialized = false
            items = []; followed = []; total = 0; nextOffset = nil; pending = []
        }
        do {
            try await core.importFollowedArtists(artistIds: legacyIDs.split(separator: ",").compactMap { Int64($0) })
            let artists = try await core.followedArtists()
            guard coreID == id else { return }
            followed = artists; initialized = true; error = nil
        } catch { if coreID == id { self.error = "Não foi possível carregar os artistas seguidos. Tente novamente." } }
    }

    func load(core: DurvaldCore, more: Bool = false) async {
        let token = UUID(); readToken = token
        let id = ObjectIdentifier(core)
        guard coreID == id else { return }
        let offset = more ? (nextOffset ?? 0) : 0
        let request = self.request
        loading = true
        defer { if readToken == token { loading = false } }
        do {
            let page = try await core.artistNews(query: ArtistNewsQuery(query: query, unseenOnly: unseenOnly,
                kind: kind, sortBy: sortBy, descending: descending, offset: offset, limit: 40))
            try Task.checkCancellation()
            guard readToken == token, coreID == id, self.request == request else { return }
            items = more ? items + page.items.filter { item in !items.contains(where: { $0.id == item.id }) } : page.items
            followed = page.followedArtists; total = page.total; nextOffset = page.nextOffset; error = nil
        } catch { if readToken == token && !Task.isCancelled { self.error = "Não foi possível carregar as novidades. Tente novamente." } }
    }

    func setFollow(_ artist: Int64, followed value: Bool, core: DurvaldCore) async {
        guard initialized, !pending.contains(artist) else { return }
        let id = ObjectIdentifier(core)
        pending.insert(artist)
        defer { if coreID == id { pending.remove(artist) } }
        do {
            try await core.setArtistFollowed(artistId: artist, followed: value)
            guard coreID == id else { return }
            await load(core: core)
        } catch { if coreID == id { self.error = "Não foi possível alterar os artistas seguidos. Tente novamente." } }
    }

    func setSeen(_ item: ArtistNewsItem, seen: Bool, core: DurvaldCore) async {
        do {
            try await core.setArtistNewsSeen(releaseGroupMbid: item.id, seen: seen)
            await load(core: core)
        } catch { self.error = "Não foi possível atualizar esta novidade. Tente novamente." }
    }

    func refresh(core: DurvaldCore, force: Bool = false) {
        guard initialized, !updating else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let artists = followed.filter { force || ($0.nextRefreshAt ?? 0) <= now }.prefix(8)
        guard !artists.isEmpty else { return }
        let token = UUID(); refreshToken = token; updating = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.refreshToken == token { self.updating = false; self.currentArtist = nil; self.refreshTask = nil } }
            for artist in artists {
                guard !Task.isCancelled, self.refreshToken == token, self.followed.contains(where: { $0.artist.id == artist.artist.id }) else { continue }
                self.currentArtist = artist.artist.name
                do {
                    _ = try await core.refreshArtistNews(artistId: artist.artist.id, force: force)
                    try Task.checkCancellation()
                    guard self.refreshToken == token else { return }
                    await self.load(core: core)
                } catch {
                    if Task.isCancelled { return }
                    self.error = "Algumas novidades não puderam ser atualizadas. O conteúdo salvo continua disponível."
                }
            }
        }
    }

    func cancelRefresh() {
        refreshToken = UUID(); refreshTask?.cancel(); refreshTask = nil
        updating = false; currentArtist = nil
    }
}
