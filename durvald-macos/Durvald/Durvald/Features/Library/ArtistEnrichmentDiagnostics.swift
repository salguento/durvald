import Foundation

enum ArtistEnrichmentDiagnostics {
    static let orderedSections: [ArtistRefreshSection] = [
        .profile, .portrait, .discography, .covers
    ]

    static func title(for section: ArtistRefreshSection) -> String {
        switch section {
        case .profile: "Perfil"
        case .portrait: "Retrato"
        case .discography: "Discografia"
        case .covers: "Capas"
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
        if result.diagnostic == .databaseBusy {
            return "Banco ocupado; tente novamente." + cacheSuffix
        }
        if result.diagnostic == .timeout {
            return "O provedor demorou demais para responder." + cacheSuffix
        }
        if result.diagnostic == .connectionFailed {
            return "Não foi possível conectar ao provedor." + cacheSuffix
        }
        if result.diagnostic == .invalidResponse {
            return "O provedor retornou uma resposta inválida." + cacheSuffix
        }
        if result.diagnostic == .invalidImage {
            return "A imagem recebida é inválida." + cacheSuffix
        }

        switch result.status {
        case .updated:
            return "Atualizado com sucesso."
        case .unchanged:
            return hasCachedContent ? "Conteúdo local atualizado e válido." : "Nenhuma alteração encontrada."
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
            }
        case .needsIdentity:
            return "Confirme a identidade MusicBrainz para atualizar esta seção."
        case .unavailable:
            let providerName: String
            switch result.provider {
            case .coverArtArchive: providerName = "Cover Art Archive"
            case .musicBrainz: providerName = "MusicBrainz"
            case .commons: providerName = "Wikimedia Commons"
            case .wikidata: providerName = "Wikidata"
            case .wikipedia: providerName = "Wikipedia"
            case .theAudioDb: providerName = "TheAudioDB"
            case .youTube: providerName = "YouTube"
            case nil: providerName = "Provedor remoto"
            }
            return "\(providerName) indisponível." + cacheSuffix
        case .rateLimited:
            if let seconds = result.retryAfterSeconds {
                return "Limite do provedor atingido. Tente novamente em \(seconds) segundos." + cacheSuffix
            }
            return "Limite do provedor atingido. Tente novamente mais tarde." + cacheSuffix
        case .disabled:
            return "Enriquecimento remoto desativado nos Ajustes."
        case .offline:
            return hasCachedContent
                ? "Modo offline: exibindo o cache local."
                : "Modo offline: nenhum conteúdo remoto está armazenado."
        case .superseded:
            return "A identidade mudou durante a atualização; este resultado foi descartado."
        }
    }
}
