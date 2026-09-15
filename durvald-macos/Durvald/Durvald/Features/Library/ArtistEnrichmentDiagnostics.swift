import Foundation

enum ArtistEnrichmentDiagnostics {
    static let orderedSections: [ArtistRefreshSection] = [
        .profile, .portrait, .discography, .covers, .popularTracks
    ]

    static func title(for section: ArtistRefreshSection) -> String {
        switch section {
        case .profile: "Perfil"
        case .portrait: "Retrato"
        case .discography: "Discografia"
        case .covers: "Capas"
        case .popularTracks: "Mais populares"
        }
    }

    static func isRetryable(_ result: ArtistRefreshSectionResult) -> Bool {
        switch result.status {
        case .unavailable, .rateLimited, .partial:
            true
        default:
            false
        }
    }

    static func message(
        for result: ArtistRefreshSectionResult,
        hasCachedContent: Bool
    ) -> String {
        let cacheSuffix = hasCachedContent ? " O conteúdo do cache local foi preservado." : ""

        switch result.diagnostic {
        case .databaseBusy:
            return "Banco ocupado; nova tentativa pode ser feita agora." + cacheSuffix
        case .timeout:
            return "O provedor demorou demais para responder." + cacheSuffix
        case .connectionFailed:
            return "Não foi possível conectar ao provedor." + cacheSuffix
        case .invalidResponse:
            return "O provedor retornou uma resposta inválida." + cacheSuffix
        case .invalidImage:
            return "A imagem recebida é inválida." + cacheSuffix
        case .providerUnavailable:
            return providerUnavailableMessage(result.provider) + cacheSuffix
        case nil:
            break
        }

        switch result.status {
        case .updated:
            return "Atualizado com sucesso."
        case .unchanged:
            return hasCachedContent ? "O conteúdo do cache local está atualizado." : "Nenhuma alteração encontrada."
        case .partial:
            return result.section == .covers
                ? "Ainda há capas pendentes; a atualização pode continuar."
                : "A atualização está parcial e pode continuar."
        case .notFound:
            switch result.section {
            case .profile: return "Nenhum perfil remoto foi encontrado."
            case .portrait: return "Nenhum retrato remoto foi encontrado."
            case .discography: return "Nenhuma discografia remota foi encontrada."
            case .covers: return "Nenhuma capa foi encontrada para os itens consultados."
            case .popularTracks: return "Nenhuma faixa popular foi encontrada."
            }
        case .needsIdentity:
            return "Confirme a identidade MusicBrainz do artista para atualizar esta seção."
        case .rateLimited:
            if let seconds = result.retryAfterSeconds {
                return "Limite do provedor atingido. Tente novamente em \(seconds) segundos." + cacheSuffix
            }
            return "Limite do provedor atingido. Tente novamente mais tarde." + cacheSuffix
        case .disabled:
            return "Enriquecimento remoto desativado nos Ajustes." + cacheSuffix
        case .offline:
            return "Modo offline." + cacheSuffix
        case .superseded:
            return "A identidade mudou durante a atualização; faça uma nova tentativa."
        case .unavailable:
            return providerUnavailableMessage(result.provider) + cacheSuffix
        }
    }

    private static func providerUnavailableMessage(_ provider: EnrichmentProvider?) -> String {
        switch provider {
        case .musicBrainz: "MusicBrainz indisponível."
        case .wikidata: "Wikidata indisponível."
        case .wikipedia: "Wikipedia indisponível."
        case .commons: "Wikimedia Commons indisponível."
        case .coverArtArchive: "Cover Art Archive indisponível."
        case .lastFm: "Last.fm indisponível."
        case .theAudioDb: "TheAudioDB indisponível."
        case .youTube: "YouTube indisponível."
        case nil: "O provedor está indisponível."
        }
    }
}
