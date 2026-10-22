import Foundation

struct ListenListRequest: Equatable {
    let coreID: ObjectIdentifier?
    let catalogRevision: UInt64
}

extension DurvaldCoreStore {
    var listenListRequest: ListenListRequest {
        ListenListRequest(coreID: core.map(ObjectIdentifier.init), catalogRevision: libraryCatalogRevision)
    }
    var pendingListenListCount: Int { listenListEntries.filter { $0.heardAt == nil }.count }

    func refreshListenList() async {
        guard let core else { return }
        listenListGeneration &+= 1
        let generation = listenListGeneration
        isLoadingListenList = true
        defer { if generation == listenListGeneration { isLoadingListenList = false } }
        do {
            let entries = try await core.listenList()
            guard generation == listenListGeneration, self.core === core, !Task.isCancelled else { return }
            if listenListEntries != entries { listenListEntries = entries }
            listenListError = nil
        } catch {
            guard generation == listenListGeneration, self.core === core, !Task.isCancelled else { return }
            listenListError = "Não foi possível carregar Para ouvir. Tente novamente."
        }
    }

    @discardableResult
    func changeListenList(_ operation: (DurvaldCore) async throws -> Void) async -> Bool {
        guard let core, !isChangingListenList else { return false }
        isChangingListenList = true
        listenListGeneration &+= 1
        listenListError = nil
        defer { isChangingListenList = false }
        do {
            try await operation(core)
            await refreshListenList()
            return listenListError == nil
        } catch {
            listenListError = "Não foi possível atualizar Para ouvir. Tente novamente."
            return false
        }
    }
    func saveToListenList(releaseID: Int64) async {
        await changeListenList { _ = try await $0.addReleaseToListenList(releaseId: releaseID) }
    }
    func saveToListenList(release: ExternalReleaseGroup, artist: Artist) async {
        await changeListenList { _ = try await $0.addExternalToListenList(artistId: artist.id, release: release) }
    }
    func removeFromListenList(_ entry: ListenListEntry) async {
        await changeListenList { try await $0.removeFromListenList(entryId: entry.id) }
    }
    func markListenListEntry(_ entry: ListenListEntry, heard: Bool) async {
        await changeListenList { try await $0.setListenListHeard(entryId: entry.id, heard: heard) }
    }
    func listenListEntry(releaseID: Int64?, externalID: String? = nil) -> ListenListEntry? {
        listenListEntries.first { entry in
            (releaseID != nil && entry.localReleaseId == releaseID)
                || (externalID != nil && entry.externalRelease?.musicbrainzId.lowercased() == externalID?.lowercased())
        }
    }
}
