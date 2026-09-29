# Análise do Estado Atual do Projeto vs. Documentação em `durvald-core/docs`

**Data de referência:** 25 de setembro de 2026
**Ambiente:** macOS (Apple Silicon), Rust 1.85+, Swift / SwiftUI (UniFFI)

---

## 1. Visão Geral Executiva

Uma auditoria comparativa entre o código-fonte atual do projeto (`durvald-core` e `durvald-macos`) e a documentação existente no diretório [`durvald-core/docs`](./) demonstrou que a implementação técnica **avançou além dos registros documentais**, com destaque para a finalização dos marcos arquiteturais e a incorporação de recursos essenciais no core.

Em linhas gerais:
* A refatoração arquitetural (Monólito Modular + Hexagonal Pragmático) atingiu a conclusão prática do **Marco 7**, embora os relatórios de status ainda o apontassem como pendente.
* Recursos do player dados como ausentes no checklist de maturidade de 14/09 (Gapless playback, Edição de tags em disco e reordenação de playlists) **já foram plenamente implementados** no core.
* As Fases 1 a 4 de enriquecimento remoto de metadados (MusicBrainz, Cover Art Archive, Wikidata, Wikipedia) estão 100% operacionais.
* Propostas para novos formatos de áudio (Symphonia AAC/ALAC) e aquisição remota (Soulseek) continuam preservadas como especificações conceituais de backlog, sem afetar o escopo do core.

---

## 2. Refatoração Arquitetural do Core

### Documentos de Referência
* [`estado-refatoracao-arquitetura-core.md`](estado-refatoracao-arquitetura-core.md)
* [`arquitetura/roteiro-implementacao-direto.md`](arquitetura/roteiro-implementacao-direto.md)
* [`arquitetura/roteiro.md`](arquitetura/roteiro.md)

### Situação Registrada vs. Situação Real

| Aspecto | Registrado na Documentação | Situação Real no Código |
|---|---|---|
| **Marcos 1 a 6** | Concluídos (último commit documentado: `f9f89a3`) | Concluídos e validados com suíte de testes verdes |
| **Marco 7 (Composição e Redução da API)** | Registrado como **"Não iniciado"** | **Praticamente concluído** nos commits `157bfa9` até `760bacd` e no working tree |
| **Composition Root** | Pendente | Implementado centralizadamente em `src/composition.rs` (`compose(...)`) |
| **Accessors concretos em `DurvaldCore`** | Presentes como dívida transitória | Removidos em `fe833a5` |
| **Superfície pública de `src/lib.rs`** | Módulos internos reexportados | **Todos os submódulos internalizados** (`mod application;`, `mod audio;`, `mod database;`, etc.). Apenas `api` e `DurvaldCore` são públicos. |
| **Fronteira Arquitetural Application ↔ Banco** | Protegida por teste | Validada continuamente pelo teste `tests/architecture_boundaries.rs` |

### Estrutura Vigente
1. **`src/application/`**: Contém 8 serviços desacoplados (`PlaybackApplication`, `LibraryApplication`, `HistoryApplication`, `PlaylistApplication`, `MetadataApplication`, `SettingsApplication`, `EnrichmentApplication`, `LastFmApplication`).
2. **`src/domain/`**: Tipos fortes para identificadores (`TrackId`, `ReleaseId`, `ArtistId`, `PlaylistId`, `PlaybackHistoryId`) e modelos puros de domínio (`CatalogTrack`, `CatalogRelease`, `CatalogArtist`, `PlaylistDetails`, etc.).
3. **`src/infrastructure/sqlite/`**: 12 adapters concretos que encapsulam consultas, mutações, paginação e mapeamento de rows para modelos de domínio. Nenhum serviço de aplicação recebe pool ou conexão direta.

---

## 3. Maturidade de Funcionalidades do Player Desktop

### Documento de Referência
* [`features checklist.md`](features%20checklist.md) (Auditoria realizada em 14/09/2026, commit `5b3ce071`)

### Atualizações no Estado das Features

* **Gapless Playback:**
  * *No documento:* ❌ *"Não encontrei; crossfade existe, mas não há pipeline gapless"*
  * *No código atual:* **✅ Implementado.** Engine em `src/audio/player.rs` e `src/audio/gapless.rs` com ringbuffers de transição na thread de áudio, pré-carregamento assíncrono, cálculo de cauda de frames e sincronização determinística.
* **Edição de Tags nos Arquivos:**
  * *No documento:* ❌ *"Infraestrutura de leitura/indexação; sem editor gravando no arquivo"*
  * *No código atual:* **✅ Implementado.** Módulo `src/metadata_edit.rs` e `MetadataApplication` com suporte a edição de tags em disco (via `lofty`), atualização transacional no SQLite, journaling de segurança e comando de `undo`.
* **Reordenação Permanente de Playlists:**
  * *No documento:* ❌/🟡 *"Não aparece na PlaylistView"*
  * *No código atual:* **✅ Implementado no Core.** Operação `reorder_playlist_track` com adapter SQLite dedicado e persistência de ordenação.
* **Formatos de Áudio Adicionais (AAC, M4A, ALAC, AIFF):**
  * *No documento:* ❌
  * *No código atual:* **❌ Permanece pendente.** `Cargo.toml` continua configurado com features de codecs para MP3, FLAC, WAV e Ogg Vorbis.
* **Integração com Sistema Operacional (macOS):**
  * *No documento:* ❌
  * *No código atual:* **❌ Permanece pendente.** Falta integração com `MPNowPlayingInfoCenter` e `MPRemoteCommandCenter` (teclas de mídia de teclado/fones e Central de Controle).
* **Monitoramento Contínuo da Biblioteca:**
  * *No documento:* ❌
  * *No código atual:* **✅ Implementado no macOS.** FSEvents monitora as raízes autorizadas, agrupa mudanças com debounce, faz scans incrementais dos diretórios afetados e reconecta volumes/bookmarks indisponíveis; scans completos manuais e periódicos permanecem como reconciliação.

---

## 4. Metadados e Enriquecimento Externo

### Documentos de Referência
* [`plano-apis-metadados.md`](plano-apis-metadados.md)
* [`fase-4-discografia-capas.md`](fase-4-discografia-capas.md)
* [`enrichment-cache.md`](enrichment-cache.md)
* [`lastfm.md`](lastfm.md)

### Situação
* **Fases 1 a 4 Concluídas:** Integrações com MusicBrainz, Cover Art Archive, Wikidata e Wikipedia estão totalmente implementadas.
* **Mecanismos de Proteção Ativos:** Rate limit de 1 req/s por processo para o MusicBrainz, tolerância a falhas, cooldown persistente para HTTP 429, cache local com TTL de 7 dias e suporte total ao modo offline.
* **Segunda Entrega (TheAudioDB e YouTube):** Permanece como especificação no backlog de produto, sem código iniciado no core (preservando o monólito modular).
* **Last.fm:** Scrobbling, Now Playing e autenticação com armazenamento seguro de sessão (Keychain / SecureStore) integrados via `LastFmApplication`.

---

## 5. Avaliações Técnicas e Backlog Futuro

* **Symphonia / Novos Codecs ([`symphonia.md`](symphonia.md)):** Roteiro técnico pronto para implementação em 3 etapas assim que priorizado pelo produto.
* **Soulseek / Aquisição Remota ([`soulseek.md`](soulseek.md)):** Proposta de arquitetura baseada no daemon REST `slskd` mantida isolada como design conceitual.
* **Consumo de CPU ([`cpu.md`](cpu.md)) e Glitch de Seek ([`return glitch.md`](return%20glitch.md)):** Documentos diagnósticos que continuam servindo como referência para refinar a sincronização de playback e a carga assíncrona de metadados na interface macOS.

---

## 6. Ações Recomendadas de Atualização Documental

1. **Atualizar [`estado-refatoracao-arquitetura-core.md`](estado-refatoracao-arquitetura-core.md):** Registrar os 19 commits posteriores ao `f9f89a3`, formalizando a conclusão do Marco 7 (Composition Root e internalização da superfície pública da crate).
2. **Revisar [`features checklist.md`](features%20checklist.md):** Atualizar o status de Gapless playback, Edição de tags e reordenação de playlists para refletir as capacidades atuais do engine.
