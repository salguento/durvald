import Foundation

struct PersonalTagSelection: Identifiable {
    let id = UUID()
    var trackIDs: [Int64] = []
    var releaseIDs: [Int64] = []
    var count: Int { trackIDs.count + releaseIDs.count }
}

struct PersonalTagFilter: Equatable {
    var ids = Set<Int64>()
    var matchAll = true

    func matchingIDs(in links: [UserTagLink]) -> Set<Int64>? {
        guard !ids.isEmpty else { return nil }
        var matches: [Int64: Set<Int64>] = [:]
        for link in links where ids.contains(link.tagId) { matches[link.itemId, default: []].insert(link.tagId) }
        return Set(matches.compactMap { !matchAll || ids.isSubset(of: $0.value) ? $0.key : nil })
    }
}

struct PersonalTagsRequest: Equatable {
    let coreID: ObjectIdentifier?
    let catalogRevision: UInt64
}

extension DurvaldCoreStore {
    var personalTagsRequest: PersonalTagsRequest {
        PersonalTagsRequest(coreID: core.map(ObjectIdentifier.init), catalogRevision: libraryCatalogRevision)
    }

    func refreshPersonalTags() async {
        guard let core else { return }
        personalTagsLoadGeneration &+= 1
        let generation = personalTagsLoadGeneration
        do {
            let value = try await core.userTagLibrary()
            guard generation == personalTagsLoadGeneration, self.core === core, !Task.isCancelled else { return }
            if personalTags != value {
                personalTags = value
                personalTagsRevision &+= 1
            }
        } catch {
            guard generation == personalTagsLoadGeneration, self.core === core, !Task.isCancelled else { return }
            personalTagsError = "Não foi possível carregar as tags: \(error.localizedDescription)"
        }
    }

    func changePersonalTags(_ operation: (DurvaldCore) async throws -> Void) async -> Bool {
        guard let core, !isUpdatingPersonalTags else { return false }
        isUpdatingPersonalTags = true
        personalTagsLoadGeneration &+= 1
        personalTagsError = nil
        defer { isUpdatingPersonalTags = false }
        do {
            try await operation(core)
            await refreshPersonalTags()
            // Smart playlists must reflect associations and global renames immediately.
            try await reloadPlaylists()
            return personalTagsError == nil
        } catch {
            personalTagsError = "Não foi possível salvar as tags: \(error.localizedDescription)"
            return false
        }
    }

    func attachPersonalTag(_ tag: UserTag, to selection: PersonalTagSelection, attached: Bool) async {
        _ = await changePersonalTags { core in
            try await core.updateUserTagLinks(tagId: tag.id, trackIds: selection.trackIDs,
                                             releaseIds: selection.releaseIDs, attached: attached)
        }
    }

    func createPersonalTag(_ name: String, selection: PersonalTagSelection? = nil) async -> Bool {
        await changePersonalTags { core in
            let tag = try await core.createUserTag(name: name)
            if let selection {
                try await core.updateUserTagLinks(tagId: tag.id, trackIds: selection.trackIDs,
                                                 releaseIds: selection.releaseIDs, attached: true)
            }
        }
    }

    func tags(for selection: PersonalTagSelection) -> [UserTag] {
        personalTags.tags.filter { associationCount($0, in: selection) > 0 }
    }

    func associationCount(_ tag: UserTag, in selection: PersonalTagSelection) -> Int {
        let tracks = Set(selection.trackIDs), releases = Set(selection.releaseIDs)
        return personalTags.trackLinks.filter { $0.tagId == tag.id && tracks.contains($0.itemId) }.count
            + personalTags.releaseLinks.filter { $0.tagId == tag.id && releases.contains($0.itemId) }.count
    }
}
