# F0.03 — Catálogo dos casos de uso atuais

Este documento inventaria os comportamentos atuais do `durvald-core` antes da migração arquitetural.

A F0.02 respondeu **qual superfície é pública**. A F0.03 muda deliberadamente a unidade de análise: em vez de módulos e exports, registra **o que o sistema faz hoje**.

Os identificadores definidos aqui são estáveis durante a migração e devem ser usados em testes, matrizes de cobertura, documentação e PRs. Exemplo:

```text
Fase 3 modifica PlaybackApplication.
PLAY-001–PLAY-019 continuam protegidos.
```

> Este catálogo é descritivo. Ele não propõe a arquitetura futura e não afirma que cada caso de uso deve continuar sendo um método separado.

## Snapshot analisado

A análise foi feita sobre `main` após a F0.02, tomando como referência o commit:

```text
a2e393151fba6e28aecb195c53d08f1fdbf5e9af
```

Foram considerados:

- a fachada `DurvaldCore`;
- os DTOs públicos de `api::*`;
- playback/audio;
- database e persistência;
- metadata e metadata editing;
- enrichment;
- Last.fm;
- secure storage;
- contratos documentados no README;
- fluxos compostos observados no cliente macOS quando eles representam comportamento do produto construído sobre o core.

## Tipos de caso de uso

| Tipo | Significado |
| --- | --- |
| **API** | existe um entrypoint público direto em `DurvaldCore` ou outra superfície pública relevante |
| **interno** | não é chamado diretamente pelo frontend, mas é comportamento atual necessário para cumprir um contrato |
| **composto** | o cliente atual combina mais de uma operação do core para oferecer o comportamento ao usuário |

Um caso composto continua sendo comportamento atual, mas não deve ser confundido com uma operação atômica já existente no core.

---

# Lifecycle

| ID | Caso de uso | Tipo | Entry point / implementação atual |
| --- | --- | --- | --- |
| **CORE-001** | Abrir o core | API | `DurvaldCore::open` / factory UniFFI `open` |
| **CORE-002** | Criar diretórios de suporte e covers | interno | executado durante `open` |
| **CORE-003** | Inicializar pool SQLite e pragmas | interno | `open`: WAL, busy timeout e foreign keys |
| **CORE-004** | Criar/garantir schema base | interno | `database::operations::create_tables` durante `open` |
| **CORE-005** | Executar migrations de enrichment | interno | `database::migrations::migrate_enrichment` |
| **CORE-006** | Inicializar valores padrão de settings | interno | `initiate_settings` |
| **CORE-007** | Inicializar estado persistido de sessão | interno | `initiate_last_session` |
| **CORE-008** | Restaurar sessão de playback ao abrir | interno | track atual, posição, volume, queue, shuffle e repeat são lidos durante `open` |
| **CORE-009** | Restaurar configuração de áudio | interno | crossfade e normalização são reaplicados ao criar o player |
| **CORE-010** | Inicializar secure storage | interno | `SecureStore::new` durante `open` |
| **CORE-011** | Inicializar integração Last.fm | interno | `LastFmClient::new` durante `open` |
| **CORE-012** | Inicializar serviço de enrichment | interno | `EnrichmentService::new` |
| **CORE-013** | Iniciar coordenação automática de término/transição de playback | interno | workers criados em `open` |
| **CORE-014** | Persistir estado após transição automática | interno | worker de eventos persiste sessão após avanço/completion |

### Observação

`open` é um caso de uso público único, mas hoje agrega várias responsabilidades observáveis. Os IDs CORE-002–CORE-014 existem para que a migração possa verificar cada comportamento mesmo quando eles forem distribuídos por componentes diferentes.

---

# Library

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **LIB-001** | Fazer scan de caminhos informados | API | `scan_library` |
| **LIB-002** | Fazer scan de todos os caminhos configurados | API | `scan_configured_library` |
| **LIB-003** | Cancelar scan em andamento | API | `cancel_library_scan` |
| **LIB-004** | Consultar progresso do scan | API | `scan_progress` |
| **LIB-005** | Rejeitar dois scans simultâneos | interno | segundo `scan_library` retorna `InvalidInput` |
| **LIB-006** | Adicionar caminho de biblioteca | API | `add_library_path` |
| **LIB-007** | Listar caminhos configurados | API | `library_paths` |
| **LIB-008** | Remover caminho configurado | API | `remove_library_path` |
| **LIB-009** | Listar todas as tracks | API | `tracks` |
| **LIB-010** | Paginar tracks | API | `tracks_page` |
| **LIB-011** | Obter track por ID | API | `track` |
| **LIB-012** | Listar releases | API | `releases` |
| **LIB-013** | Paginar releases | API | `releases_page` |
| **LIB-014** | Obter release por ID | API | `release` |
| **LIB-015** | Listar tracks de um release | API | `release_tracks` |
| **LIB-016** | Listar artistas | API | `artists` |
| **LIB-017** | Obter artista por ID | API | `artist` |
| **LIB-018** | Listar releases de um artista | API | `artist_releases` |
| **LIB-019** | Listar tracks de um artista | API | `artist_tracks` |
| **LIB-020** | Buscar biblioteca | API | `search` sobre tracks, releases, artists e playlists |
| **LIB-021** | Reconciliar arquivos removidos após scan completo | interno | reconciliation ao final de cada path concluído |
| **LIB-022** | Preservar registros existentes após scan cancelado/parcial | interno | reconciliation não é executada após cancelamento |
| **LIB-023** | Indexar apenas formatos locais suportados | interno | MP3, WAV, FLAC, Ogg/OGA |
| **LIB-024** | Atualizar track já conhecida em rescan | interno | metadata persistida distingue adição e atualização |
| **LIB-025** | Marcar/desmarcar track favorita | API | `set_track_favorite` |
| **LIB-026** | Marcar/desmarcar release favorito | API | `set_release_favorite` |
| **LIB-027** | Ocultar/reexibir track | API | `set_track_hidden` |
| **LIB-028** | Ocultar/reexibir release | API | `set_release_hidden` |
| **LIB-029** | Marcar/desmarcar “suggest less” de track | API | `set_track_suggest_less` |
| **LIB-030** | Marcar/desmarcar “suggest less” de release | API | `set_release_suggest_less` |
| **LIB-031** | Definir/remover rating de track | API | `set_track_rating`, escala 0–5 |
| **LIB-032** | Definir/remover rating de release | API | `set_release_rating`, escala 0–5 |

### Paginação

A implementação atual rejeita `page_size == 0`, rejeita offsets que não cabem no domínio aceito e limita o tamanho efetivo da página a 200. Esses comportamentos serão detalhados na etapa de invariantes/cobertura, mas pertencem aos casos LIB-010, LIB-013 e HIST-003.

---

# Playback

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **PLAY-001** | Reproduzir uma track | API | `play` |
| **PLAY-002** | Consultar snapshot atual | API | `playback` |
| **PLAY-003** | Pausar | API | `pause` |
| **PLAY-004** | Retomar | API | `resume` |
| **PLAY-005** | Parar | API | `stop` |
| **PLAY-006** | Seek por posição em segundos | API | `seek` |
| **PLAY-007** | Alterar volume | API | `set_volume` |
| **PLAY-008** | Ativar/desativar shuffle | API | `set_shuffle_enabled` |
| **PLAY-009** | Alterar repeat mode | API | `set_repeat_mode` |
| **PLAY-010** | Adicionar track à fila | API | `add_to_queue` |
| **PLAY-011** | Consultar fila | API | `queue` |
| **PLAY-012** | Avançar para próxima track | API | `next_track` |
| **PLAY-013** | Voltar para track anterior | API | `previous_track` |
| **PLAY-014** | Reproduzir item específico da fila | API | `play_queue_item` |
| **PLAY-015** | Remover item futuro da fila | API | `remove_from_queue` |
| **PLAY-016** | Reordenar item futuro da fila | API | `move_queue_item` |
| **PLAY-017** | Limpar fila futura sem remover track ativa | API | `clear_queue` |
| **PLAY-018** | Restaurar track e posição persistidas ao primeiro resume | interno | `restore_session` + `resume` |
| **PLAY-019** | Persistir sessão após comandos de playback | interno | play/pause/resume/stop/queue/shuffle/repeat persistem estado |
| **PLAY-020** | Persistir progresso após seek | interno | `persist_session_progress` |
| **PLAY-021** | Persistir volume | interno | `persist_session_volume` |
| **PLAY-022** | Preparar sucessor durante reprodução | interno | preloader de gapless |
| **PLAY-023** | Avançar automaticamente sem polling da UI | interno | worker + transição do player |
| **PLAY-024** | Fazer transição gapless quando o sucessor está preparado | interno | `schedule_gapless` / `synchronize_gapless` |
| **PLAY-025** | Aplicar crossfade configurado a mudanças manuais | interno | configuração restaurada/aplicada no player |
| **PLAY-026** | Aplicar ReplayGain quando normalização está habilitada | interno | preparação de áudio usa configuração de normalização |
| **PLAY-027** | Preservar histórico de navegação da fila para Previous | interno | histórico do player é separado do histórico persistente de escuta |

### Semântica da fila

A fila de apresentação inclui a track ativa na posição inicial quando existe reprodução. Operações de remoção/reordenação protegem a track ativa e atuam somente nos próximos itens.

---

# History

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **HIST-001** | Registrar reprodução concluída | interno | completion automático chama `record_completed_playback` |
| **HIST-002** | Criar nova entrada a cada completion em Repeat One | interno | cada completion gera evento persistente próprio |
| **HIST-003** | Listar histórico completo | API | `playback_history` |
| **HIST-004** | Paginar histórico | API | `playback_history_page` |
| **HIST-005** | Remover uma entrada de histórico | API | `remove_playback_history_item` |
| **HIST-006** | Limpar todo o histórico | API | `clear_playback_history` |
| **HIST-007** | Manter histórico persistente separado de navegação Previous | interno | DB history e queue navigation history são conceitos distintos |

---

# Playlists

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **PLST-001** | Listar playlists | API | `playlists` |
| **PLST-002** | Criar playlist | API | `create_playlist` |
| **PLST-003** | Obter playlist por ID | API | `playlist` |
| **PLST-004** | Renomear/editar descrição/artwork da playlist | API | `update_playlist` |
| **PLST-005** | Excluir playlist | API | `delete_playlist` |
| **PLST-006** | Listar tracks na ordem da playlist | API | `playlist_tracks` |
| **PLST-007** | Adicionar track em uma posição | API | `add_track_to_playlist` |
| **PLST-008** | Remover entrada de track da playlist | API | `remove_track_from_playlist` |
| **PLST-009** | Reordenar track na playlist | API | `move_playlist_track` |
| **PLST-010** | Marcar/desmarcar playlist favorita | API | `set_playlist_favorite` |
| **PLST-011** | Marcar/desmarcar “suggest less” da playlist | API | `set_playlist_suggest_less` |
| **PLST-012** | Ler artwork da playlist | API | `playlist_artwork_bytes` |
| **PLST-013** | Reproduzir playlist a partir de uma posição | composto | macOS: `playlist_tracks` → `clear_queue` → `play` → `add_to_queue` |
| **PLST-014** | Reproduzir playlist em shuffle | composto | cliente embaralha seleção e aplica `set_shuffle_enabled` |
| **PLST-015** | Enfileirar uma playlist | composto | macOS: `playlist_tracks` + operações de queue |
| **PLST-016** | Enfileirar playlist como “play next” | composto | adiciona e reposiciona itens na queue |

### Nota sobre “play playlist”

Não existe hoje `DurvaldCore::play_playlist`. O comportamento existe no produto, mas é uma **orquestração do cliente macOS**. Essa distinção é importante para a migração: uma futura `PlaybackApplication` pode absorver essa orquestração, mas a Fase 0 apenas registra o estado atual.

---

# Metadata e artwork

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **META-001** | Extrair metadata de arquivo local | API | `extract_metadata` |
| **META-002** | Ler metadata editável/indexada de uma track | API | `track_info` |
| **META-003** | Backfill de cache de metadata para biblioteca antiga | interno | `metadata_edit::ensure_cached` |
| **META-004** | Editar metadata somente no estado gerenciado pelo Durvald | API | `save_track_metadata(..., write_to_file=false)` |
| **META-005** | Editar metadata e gravar no arquivo | API | `save_track_metadata(..., write_to_file=true)` |
| **META-006** | Validar campos editáveis | interno | título/artista/álbum obrigatórios e limites numéricos |
| **META-007** | Preservar tags não editadas e artwork ao gravar arquivo | interno | writer altera somente campos editáveis |
| **META-008** | Registrar journal da alteração para undo | interno | `track_metadata_changes` |
| **META-009** | Desfazer última alteração aplicável | API | `undo_track_metadata` |
| **META-010** | Extrair artwork durante scan/metadata read | interno | pipeline de metadata |
| **META-011** | Validar tamanho/formato/dimensões de artwork | interno | limites do módulo metadata |
| **META-012** | Persistir artwork gerenciado em `covers_dir` | interno | scan/enrichment escrevem assets gerenciados |
| **META-013** | Ler bytes de artwork gerenciado | API | `artwork_bytes` |
| **META-014** | Rejeitar artwork fora de `covers_dir` | interno | `artwork_path_in_covers_dir` → `InvalidInput` |
| **META-015** | Rejeitar escape por symlink | interno | canonicalização antes da checagem do diretório |
| **META-016** | Gerar thumbnail de artwork local | interno | `metadata::write_thumbnail` |

---

# Enrichment

O enrichment atual separa explicitamente **reads locais** de **refresh remoto**. Abrir o core, fazer scan e ler snapshots locais não devem iniciar rede implicitamente.

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **ENR-001** | Ler configuração de enrichment | API | `enrichment_settings` |
| **ENR-002** | Configurar enrichment/offline/language | API | `configure_enrichment` |
| **ENR-003** | Ler identidade persistida de artista | API | `artist_identity` |
| **ENR-004** | Resolver candidatos de identidade | API | `resolve_artist_candidates` |
| **ENR-005** | Confirmar identidade MusicBrainz | API | `confirm_artist_identity` |
| **ENR-006** | Limpar identidade confirmada | API | `clear_artist_identity` |
| **ENR-007** | Ler detalhes de artista somente do cache local | API | `artist_details` |
| **ENR-008** | Ler página de discografia persistida | API | `artist_discography` |
| **ENR-009** | Ler popular tracks persistidas | API | `artist_popular_tracks` |
| **ENR-010** | Obter detalhes de release externo | API | `external_release_details`, cache-first com rede quando necessário |
| **ENR-011** | Refresh explícito de seções do artista | API | `refresh_artist` |
| **ENR-012** | Refresh de profile | API | seção `Profile` de `refresh_artist` |
| **ENR-013** | Refresh de portrait | API | seção `Portrait` |
| **ENR-014** | Refresh de discography | API | seção `Discography` |
| **ENR-015** | Refresh de covers | API | seção `Covers` |
| **ENR-016** | Refresh de popular tracks | API | seção `PopularTracks` |
| **ENR-017** | Refresh de similar artists | API | seção `SimilarArtists` |
| **ENR-018** | Sincronizar metadata de releases locais usando catálogo em cache | API | `sync_artist_release_metadata`; não inicia rede |
| **ENR-019** | Definir override editorial de campo de artista | API | `set_artist_override` |
| **ENR-020** | Limpar override editorial | API | `clear_artist_override` |
| **ENR-021** | Limpar dados/cache de um provider | API | `clear_enrichment_provider_data` |
| **ENR-022** | Servir snapshot fresco do cache sem rede | interno | políticas de TTL |
| **ENR-023** | Servir snapshot stale quando política offline/fallback permite | interno | cache continua legível offline |
| **ENR-024** | Impedir rede quando enrichment está desabilitado | interno | settings/policy |
| **ENR-025** | Impedir rede em modo offline | interno | settings/policy |
| **ENR-026** | Aplicar cache negativo de Not Found | interno | TTL específico |
| **ENR-027** | Classificar e reter falha transitória de provider | interno | failure snapshots/TTL |
| **ENR-028** | Respeitar rate limit e retry-after | interno | transport/provider failure policy |
| **ENR-029** | Deduplicar requests concorrentes equivalentes | interno | single-flight/cached request no service |
| **ENR-030** | Produzir diagnóstico por seção de refresh | API | `ArtistRefreshSectionResult`, status e diagnostic code |
| **ENR-031** | Recuperar e persistir artwork remoto validado | interno | providers + managed artwork cache |
| **ENR-032** | Manter attribution/proveniência de dados remotos | interno/API DTO | snapshots normalizados e DTOs de attribution |

### “Refresh release”

Não existe no snapshot atual um entrypoint público independente chamado `refresh_release`.

Os comportamentos de release remoto atualmente se dividem entre:

- `external_release_details`: carrega/cacheia detalhes de uma release externa;
- seção `Discography`/`Covers` de `refresh_artist`;
- `sync_artist_release_metadata`: aplica ao catálogo local metadata já presente no cache.

Portanto a F0.03 não cria um caso de uso fictício “refresh release” atômico.

---

# Last.fm

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **LFM-001** | Consultar status de conexão | API | `lastfm_status` |
| **LFM-002** | Configurar API key/secret | API | `configure_lastfm` |
| **LFM-003** | Armazenar credenciais sensíveis em secure storage | interno | `LastFmClient::initialize_lastfm` + `SecureStore` |
| **LFM-004** | Solicitar token/URL de autorização | API | `lastfm_auth_token` |
| **LFM-005** | Completar autenticação após aprovação | API | `complete_lastfm_auth` |
| **LFM-006** | Publicar Now Playing ao iniciar track | interno | disparado por `play`, resume/restauração e transições |
| **LFM-007** | Pausar contagem de tempo efetivamente tocado | interno | `pause_lastfm_playback` |
| **LFM-008** | Retomar contagem de tempo efetivamente tocado | interno | `resume_lastfm_playback` |
| **LFM-009** | Avaliar elegibilidade de scrobble | interno | duração >= 30 s e tempo tocado >= min(50%, 240 s) |
| **LFM-010** | Fazer scrobble após completion elegível | interno | `report_lastfm_track_completed` |
| **LFM-011** | Não fazer scrobble de playback insuficiente | interno | mesma regra de elegibilidade |
| **LFM-012** | Desconectar/log out | API | `disconnect_lastfm` |
| **LFM-013** | Remover credenciais ao desconectar | interno | `LastFmClient::disconnect_lastfm` |
| **LFM-014** | Limpar cache de enrichment Last.fm sem afetar outros providers | interno | `clear_provider_data(LastFm)` |
| **LFM-015** | Mapear erros externos para categorias públicas | interno | Network / Authentication / Storage |

---

# Settings

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **SET-001** | Ler settings | API | `settings` |
| **SET-002** | Atualizar settings | API | `update_settings` |
| **SET-003** | Validar settings antes de persistir | interno | crossfade, qualidade, source e download path |
| **SET-004** | Aplicar crossfade atualizado ao player em runtime | interno | `update_settings` |
| **SET-005** | Aplicar normalização de volume ao player em runtime | interno | `update_settings` |
| **SET-006** | Persistir settings | interno | database `save_settings` |
| **SET-007** | Restaurar settings ao abrir o core | interno | `open` |
| **SET-008** | Normalizar valores legados inválidos/fora da escala ao ler | interno | crossfade duration, audio quality e volume |
| **SET-009** | Rejeitar input inválido com `CoreError::InvalidInput` | interno/contrato | `validate_settings` |

---

# Secure storage

Secure storage é infraestrutura interna para os clientes atuais, mas possui comportamento próprio que precisa ser conhecido antes de ser escondido atrás de ports/adapters.

| ID | Caso de uso | Tipo | Entry point / comportamento atual |
| --- | --- | --- | --- |
| **SEC-001** | Inicializar store e carregar dados não sensíveis existentes | interno | `SecureStore::new` |
| **SEC-002** | Armazenar secret no credential service da plataforma | interno | `set_secret` |
| **SEC-003** | Recuperar secret | interno | `get_secret` |
| **SEC-004** | Excluir secret | interno | `delete_secret` |
| **SEC-005** | Tratar secret inexistente | interno | retorna erro “Not found”; delete é tolerante a ausência no keyring |
| **SEC-006** | Migrar secret legado criptografado para keychain/credential manager | interno | fallback de `get_secret` |
| **SEC-007** | Remover artefato criptografado legado após migração | interno | cleanup após set/get/delete |
| **SEC-008** | Armazenar dados não sensíveis chave/valor em memória | interno | `get`, `set`, `delete` |
| **SEC-009** | Persistir dados não sensíveis em arquivo | interno | `save_data` |
| **SEC-010** | Aplicar permissões restritivas aos arquivos gerenciados em Unix | interno | diretório 0700 / arquivos 0600 onde aplicável |
| **SEC-011** | Propagar erros do credential service/plataforma | interno | `SecureStoreError::Keyring` e demais variantes |
| **SEC-012** | Converter falha de secure store do Last.fm em `CoreError::Storage` | interno/contrato | mapping em `lastfm_error` |

---

# Fluxos compostos adicionais observados no cliente

Estes fluxos existem no produto atual e atravessam mais de um caso de uso do core. Eles não recebem IDs de domínio separados nesta fase porque são composições dos IDs acima, mas precisam ser considerados quando a orquestração migrar para Application Services.

| Fluxo atual | Composição principal |
| --- | --- |
| Reproduzir lista de tracks/álbum | `clear_queue` → `play` da primeira track → `add_to_queue` das demais |
| Reproduzir playlist | PLST-006 + PLAY-017 + PLAY-001 + PLAY-010 |
| Enfileirar playlist | PLST-006 + PLAY-010, opcionalmente PLAY-016 para “play next” |
| Enfileirar release | LIB-015 + PLAY-010, opcionalmente PLAY-016 |
| Adicionar release a playlist | LIB-015 + PLST-007 repetidamente |
| Adicionar playlist a outra playlist | PLST-006 + PLST-007 repetidamente |

Esses fluxos são bons candidatos futuros a orquestração de aplicação, mas **não devem ser refatorados na Fase 0**.

---

# Resumo por área

| Prefixo | Área | IDs atuais |
| --- | --- | ---: |
| `CORE` | Lifecycle | CORE-001–CORE-014 |
| `LIB` | Library | LIB-001–LIB-032 |
| `PLAY` | Playback/queue | PLAY-001–PLAY-027 |
| `HIST` | History | HIST-001–HIST-007 |
| `PLST` | Playlists | PLST-001–PLST-016 |
| `META` | Metadata/artwork | META-001–META-016 |
| `ENR` | Enrichment | ENR-001–ENR-032 |
| `LFM` | Last.fm | LFM-001–LFM-015 |
| `SET` | Settings | SET-001–SET-009 |
| `SEC` | Secure storage | SEC-001–SEC-012 |

Total catalogado nesta baseline: **180 casos de uso/comportamentos identificados**.

> O número não representa 180 features independentes. Vários IDs são subcomportamentos necessários para tornar contratos complexos testáveis durante a migração.

---

# Regras para evolução deste catálogo

1. **Não reutilizar IDs.** Se um caso for removido deliberadamente em fase futura, seu ID fica aposentado.
2. **Não renumerar para “fechar buracos”.**
3. Novos comportamentos adicionados depois da baseline recebem novos IDs no final da área correspondente.
4. Refatorar implementação não cria ID novo quando o comportamento observado permanece o mesmo.
5. Um bug descoberto na Fase 0 não deve ser silenciosamente transformado em novo comportamento esperado; primeiro ele é classificado conforme a política da Fase 0.
6. A matriz de cobertura da F0.06 deverá referenciar estes IDs, em vez de nomes de arquivos/funções.
7. Casos compostos podem futuramente ganhar um entrypoint único sem trocar de significado; o catálogo registra comportamento, não desenho de API.

# Critério de conclusão da F0.03

- [x] lifecycle catalogado;
- [x] library e scan catalogados;
- [x] playback, queue e transições automáticas catalogados;
- [x] histórico persistente catalogado;
- [x] playlists catalogadas;
- [x] metadata editing e artwork catalogados;
- [x] enrichment e suas políticas observáveis catalogados;
- [x] Last.fm catalogado;
- [x] settings catalogados;
- [x] secure storage catalogado;
- [x] casos receberam identificadores estáveis;
- [x] fluxos compostos do cliente foram separados de operações atômicas do core;
- [x] diferenças entre a lista inicial e o código atual foram registradas sem inventar APIs inexistentes.

A próxima etapa pode classificar estes casos por criticidade sem precisar voltar à organização física do código.
