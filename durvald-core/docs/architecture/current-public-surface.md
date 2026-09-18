# F0.02 — Inventário da superfície pública atual

Este documento registra a superfície pública observável do `durvald-core` antes da migração arquitetural.

A finalidade desta etapa é distinguir:

- **contratos deliberados**, consumidos pelos frontends e que precisam permanecer estáveis durante a migração;
- **compatibilidade temporária**, exposta hoje para evitar quebra durante transições anteriores;
- **superfície pública sem consumidor conhecido no monorepo**, que deve ser tratada como candidata a redução em uma fase posterior.

> Este inventário é descritivo. A Fase 0 não remove exports, não reduz visibilidade e não altera contratos.

## Snapshot analisado

A análise foi feita sobre `main` após a F0.01, no commit:

```text
9dfa653fac2999c3c017767fc62cfefbe9f2d7f7
```

Foram inspecionados, em especial:

- `durvald-core/src/lib.rs`;
- `durvald-core/src/api.rs` e `src/api/enrichment.rs`;
- `durvald-core/src/core.rs`;
- `durvald-core/src/durvald.udl`;
- módulos públicos de audio, database, enrichment, Last.fm, metadata e secure storage;
- `durvald-gtk`, consumidor Rust direto do core;
- `durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift`;
- bindings Swift gerados e o pipeline de geração UniFFI.

A classificação de uso abaixo significa **uso encontrado dentro deste repositório**. Ela não prova que não existam consumidores externos fora do monorepo.

## Superfície publicada por `lib.rs`

Atualmente a raiz da crate declara:

```rust
pub mod api;
pub mod audio;
pub mod core;
pub mod database;
pub mod enrichment;
pub mod lastfm;
pub mod metadata;
pub mod secure_store;
```

Também reexporta:

```rust
pub use crate::api::*;
pub use crate::core::DurvaldCore;

// Re-export internal types for backward compatibility during transition
pub use crate::audio::AudioPlayer;
pub use crate::database::operations::*;
pub use crate::lastfm::LastFmClient;
pub use crate::secure_store::{SecureStore, SecureStoreError};
```

O comentário de compatibilidade é importante: ele documenta que pelo menos `AudioPlayer`, as operações de banco, `LastFmClient` e `SecureStore` não foram concebidos como a fronteira arquitetural definitiva.

## Consumidores atuais

### GTK — consumidor Rust direto

`durvald-gtk` depende da crate por path:

```toml
durvald-core = { path = "../durvald-core" }
```

O backend GTK importa atualmente apenas:

```rust
use durvald_core::{CoreConfig, CoreError, CoreResult, DurvaldCore};
```

O cliente chama a fachada `DurvaldCore`, hoje principalmente `DurvaldCore::open` e `tracks`.

Não foi encontrado no cliente GTK uso direto de:

- `AudioPlayer`;
- `LastFmClient`;
- `SecureStore`;
- `durvald_core::database`;
- `durvald_core::audio`;
- `durvald_core::lastfm`;
- `durvald_core::metadata`;
- `durvald_core::enrichment`.

### macOS — consumidor UniFFI

O cliente macOS não consome os módulos Rust internos diretamente. Ele consome os bindings gerados pela superfície UniFFI.

`DurvaldCoreStore.swift` usa diretamente, entre outros:

- `DurvaldCore`;
- `CoreConfig`;
- `PlaybackSnapshot`;
- `QueueItem`;
- `ScanProgress`;
- `Track`;
- `Release`;
- `Artist`;
- `Playlist`;
- `PlaybackHistoryItem`;
- `Settings`;
- `EnrichmentSettings`;
- `SearchResults`;
- DTOs e enums de enriquecimento.

Além dos tipos, o cliente chama uma quantidade significativa dos métodos públicos da fachada para biblioteca, paginação, playlists, playback, settings, metadata, Last.fm e enrichment.

A função Rust livre `open(config)`, exportada por UniFFI, é a factory usada pelo binding Swift para obter um `DurvaldCore`.

### Consequência

A fronteira realmente compartilhada pelos dois clientes é:

```text
clientes
   │
   ├── GTK ───────────────► Rust public API
   │                         │
   │                         ├── api::*
   │                         └── DurvaldCore
   │
   └── macOS ──► UniFFI ──► api::* + DurvaldCore
```

Os componentes de infraestrutura concretos ficam atrás dessa fachada na utilização atual.

## Inventário e classificação

| Superfície | Consumidor encontrado | Classificação | Deve permanecer estável durante a migração? |
| --- | --- | --- | --- |
| `DurvaldCore` reexportado na raiz | GTK e Swift/UniFFI | contrato principal | **sim** |
| Métodos funcionais públicos de `DurvaldCore` | Swift/UniFFI; parte deles também disponível ao GTK | contrato da fachada | **sim**, enquanto o método fizer parte do contrato existente |
| `DurvaldCore::open` | GTK | contrato Rust | **sim** |
| função UniFFI `open(config)` | Swift | contrato FFI | **sim** |
| `api::*` reexportado na raiz | GTK e Swift/UniFFI | API deliberada | **sim** |
| `pub mod api` | nenhum uso por module path encontrado no GTK; semanticamente definido como API pública | API deliberada | **sim por enquanto** |
| `CoreError` e suas categorias | GTK e Swift/UniFFI | contrato público de erro | **sim** |
| superfície UniFFI gerada | macOS | contrato de cliente | **sim** |
| `AudioPlayer` reexportado na raiz | nenhum consumidor in-repo encontrado | compatibilidade temporária | **preservar na Fase 0; candidato a remover depois** |
| `pub mod audio` / `audio::player` | nenhum consumidor in-repo encontrado | infraestrutura exposta | **não há necessidade in-repo demonstrada** |
| `database::operations::*` reexportado na raiz | nenhum consumidor in-repo encontrado | compatibilidade temporária / vazamento de persistence | **preservar na Fase 0; forte candidato a remover depois** |
| `pub mod database` e submódulos | nenhum consumidor in-repo encontrado | infraestrutura exposta | **não há necessidade in-repo demonstrada** |
| `LastFmClient` reexportado na raiz | nenhum consumidor in-repo encontrado | compatibilidade temporária | **preservar na Fase 0; candidato a remover depois** |
| `pub mod lastfm` | nenhum consumidor in-repo encontrado | integração concreta exposta | **não há necessidade in-repo demonstrada** |
| `SecureStore` / `SecureStoreError` reexportados | nenhum consumidor in-repo encontrado | compatibilidade temporária | **preservar na Fase 0; candidato a remover depois** |
| `pub mod secure_store` | nenhum consumidor in-repo encontrado | infraestrutura concreta exposta | **não há necessidade in-repo demonstrada** |
| `pub mod metadata` | nenhum consumidor in-repo encontrado | infraestrutura concreta exposta | **não há necessidade in-repo demonstrada** |
| `pub mod enrichment` | nenhum consumidor de infraestrutura encontrado; clientes usam DTOs de `api` | infraestrutura exposta | **não há necessidade in-repo demonstrada** |
| `pub mod core` | nenhum consumidor pelo caminho `durvald_core::core::*` encontrado | implementação da fachada exposta como módulo | **o tipo deve permanecer; o module path não tem necessidade in-repo demonstrada** |

## API deliberada: `api::*`

`api.rs` declara explicitamente que contém tipos públicos estáveis e seguros para frontends. Esses tipos são reexportados pela raiz da crate e grande parte possui derive UniFFI.

### Core e erros

- `CoreConfig`;
- `CoreError`;
- `CoreResult<T>`.

### Biblioteca, metadata e busca

- `Track`;
- `TrackMetadataEdit`;
- `TrackInfo`;
- `TrackPage`;
- `Release`;
- `ReleasePage`;
- `Artist`;
- `AudioMetadata`;
- `KeyValuePair`;
- `SearchResults`.

### Playback, fila e histórico

- `QueueItem`;
- `PlaybackSnapshot`;
- `RepeatMode`;
- `PlaybackHistoryItem`;
- `PlaybackHistoryPage`;
- `LastSession`.

### Playlists e settings

- `Playlist`;
- `PlaylistTrack`;
- `Settings`.

### Scan

- `ScanProgress`;
- `ScanPhase`;
- `ScanResult`.

### Last.fm

- `LastFmStatus`;
- `AuthTokenResponse`;
- `SessionResponse`.

### Enrichment

`api/enrichment.rs` acrescenta a superfície frontend-safe de enriquecimento:

- `EnrichmentProvider`;
- `EnrichmentSettings`;
- `ArtistIdentityStatus`;
- `ArtistEntityKind`;
- `ArtistPartialDate`;
- `EnrichmentAttribution`;
- `ArtistProfile`;
- `ArtistProfileSource`;
- `ArtistImageReference`;
- `ExternalArtworkScope`;
- `ExternalReleaseArtwork`;
- `ExternalReleaseGroup`;
- `ExternalReleaseTrack`;
- `ExternalReleaseDetails`;
- `ArtistDiscographyPage`;
- `ArtistPopularTrack`;
- `ArtistPopularTracks`;
- `ArtistProfileField`;
- `ArtistFieldOverride`;
- `SimilarArtist`;
- `ArtistDetails`;
- `ArtistIdentityOrigin`;
- `ArtistIdentity`;
- `ArtistIdentityCandidate`;
- `ArtistIdentityLookupStatus`;
- `ArtistIdentityCandidates`;
- `ArtistRefreshSection`;
- `ArtistRefreshRequest`;
- `ArtistRefreshStatus`;
- `ArtistRefreshDiagnosticCode`;
- `CoverRefreshProgress`;
- `ArtistRefreshSectionResult`;
- `ArtistRefreshResult`.

Durante a migração, alterações nesses tipos devem ser consideradas alterações de contrato, principalmente quando mudam campos, enums, semântica ou representação FFI.

## Fachada `DurvaldCore`

`DurvaldCore` é explicitamente descrito no código como o ponto principal de entrada e encapsula banco, áudio, secure storage, Last.fm e enrichment.

Dois blocos de `impl DurvaldCore` são anotados para exportação UniFFI. A superfície funcional pública cobre atualmente estas famílias:

| Família | Exemplos |
| --- | --- |
| lifecycle | `open` |
| scan/library paths | `scan_library`, `scan_configured_library`, `cancel_library_scan`, `add_library_path`, `remove_library_path`, `library_paths` |
| library/query | `tracks`, `tracks_page`, `releases`, `releases_page`, `artists`, `track`, `release`, `search` |
| enrichment | identity, details, discography, popular tracks, refresh, overrides e settings |
| playlists | create/read/update/delete, tracks, reorder e associação de tracks |
| playback | `play`, `pause`, `resume`, `stop`, `seek`, volume, shuffle e repeat |
| queue | add/next/previous/play item/remove/move/clear/read |
| Last.fm | status, configuração, autenticação e disconnect |
| session/history | session, save, history, paginação, delete e clear |
| settings | read/update |
| metadata | track info, save/undo metadata, extract metadata |
| artwork | artwork bytes e playlist artwork |

Essa fachada é o contrato que as fases arquiteturais devem preservar enquanto a implementação interna é redistribuída.

## Accessors públicos de infraestrutura em `DurvaldCore`

Existe um conjunto separado de métodos públicos no primeiro `impl DurvaldCore`:

```rust
pub fn db_pool(&self) -> ...
pub fn audio_player(&self) -> ...
pub fn lastfm(&self) -> ...
pub fn covers_dir(&self) -> ...
```

O próprio comentário no código os descreve como:

```text
Internal accessor methods for Tauri integration (not exported to UniFFI)
```

Não existe cliente Tauri no monorepo atual e o GTK não usa esses accessors.

Classificação:

| Accessor | Expõe | Consumidor in-repo | Avaliação |
| --- | --- | --- | --- |
| `db_pool()` | pool SQLite/r2d2 concreto | nenhum | vazamento claro de infraestrutura |
| `audio_player()` | mutex de `AudioPlayer` concreto | nenhum | vazamento claro de infraestrutura |
| `lastfm()` | `LastFmClient` concreto | nenhum | vazamento de provider/integration |
| `covers_dir()` | detalhe de armazenamento | nenhum | detalhe interno exposto |

Eles devem continuar intactos durante a Fase 0, mas são candidatos explícitos à redução de visibilidade quando a compatibilidade pública for tratada deliberadamente.

## Superfície de áudio

Como `audio` é público:

```rust
pub mod player;
pub use player::{AudioPlayer, QueueData, QueueItem};
```

Logo, além do reexport de `AudioPlayer` na raiz, um consumidor Rust pode hoje alcançar:

- `audio::AudioPlayer`;
- `audio::QueueData`;
- `audio::QueueItem`;
- `audio::player::AudioError`;
- métodos públicos concretos do player.

Nenhum desses caminhos é usado pelos clientes atuais.

O frontend consome estado e comandos de playback através de `DurvaldCore` e dos DTOs `api::PlaybackSnapshot`, `api::QueueItem` e `api::RepeatMode`.

**Conclusão:** a exposição do player concreto não é necessária para os consumidores in-repo atuais.

## Superfície de database

`database.rs` publica:

```rust
pub mod enrichment;
pub mod migrations;
pub mod models;
pub mod operations;
pub mod identity;

pub use models::*;
pub use operations::*;
```

Além disso, `lib.rs` faz:

```rust
pub use crate::database::operations::*;
```

Isso torna detalhes de persistência acessíveis tanto por caminhos como:

```text
durvald_core::database::operations::...
durvald_core::database::models::...
```

quanto diretamente na raiz para vários símbolos de `operations::*`.

A superfície inclui, entre outros:

- `DatabaseError` / `DatabaseResult`;
- criação e migração de tabelas;
- CRUD de library paths e settings;
- operações de artists/releases/tracks;
- histórico;
- favoritos/hidden/rating;
- playlists;
- sessão;
- scan;
- modelos de persistência como `SongItem`, `ReleaseGroup`, `PlayHistory`, `LastSession`, `Settings`.

O cliente GTK não usa operações ou modelos de database diretamente e a superfície UniFFI não os expõe como contrato do Swift.

**Conclusão:** esta é a maior área de superfície pública que hoje representa detalhe de persistence em vez de contrato de frontend.

## Superfície de enrichment interna

O módulo público `enrichment` expõe:

- `models`;
- `policy`;
- `service`;
- `transport`;
- `identity`;
- `providers`.

Com isso, consumidores Rust podem alcançar diretamente:

- `EnrichmentService`;
- `EnrichmentHttpClient`;
- `TransportError`;
- snapshots e modelos internos de providers/cache;
- políticas, TTLs e normalização;
- providers concretos e utilitários de identity.

Os clientes atuais não usam esses módulos. Eles usam a superfície normalizada definida em `api/enrichment.rs` e os métodos correspondentes de `DurvaldCore`.

**Conclusão:** os DTOs de enrichment em `api` são contrato; a infraestrutura de `enrichment::*` não possui necessidade externa demonstrada no monorepo.

## Last.fm

`lastfm.rs` publica diretamente:

- `LastFmError`;
- `LastFmResult<T>`;
- `AuthTokenResponse`;
- `SessionResponse`;
- `LastFmClient` e seus métodos públicos.

`LastFmClient` também é reexportado na raiz por compatibilidade.

Os clientes atuais acessam Last.fm por `DurvaldCore` e por DTOs de `api`; nenhum deles instancia ou usa `LastFmClient` diretamente.

**Conclusão:** `LastFmClient` é uma implementação concreta atualmente vazando pela API Rust, não uma dependência necessária dos frontends atuais.

## Metadata

Como `metadata` é público, a crate também publica diretamente:

- `MetadataError` / `MetadataResult<T>`;
- `metadata::AudioMetadata` interno;
- `replay_gain_db`;
- escrita de cover e thumbnail;
- extração bloqueante de metadata;
- `MusicBrainzTags`.

O contrato frontend equivalente passa por `DurvaldCore::extract_metadata` e pelo DTO `api::AudioMetadata`.

Nenhum frontend atual usa `durvald_core::metadata::*` diretamente.

**Conclusão:** a superfície concreta de metadata não possui necessidade externa demonstrada no monorepo.

## Secure storage

`secure_store` publica:

- `SecureStore`;
- `SecureStoreError`;
- `SecureStoreResult<T>`;
- operações de secrets e chave/valor;
- `SECURE_STORE`;
- `init_secure_store`;
- `get_secure_store`.

`SecureStore` e `SecureStoreError` também são reexportados na raiz por compatibilidade.

Nenhum frontend atual acessa secure storage diretamente. Credenciais de Last.fm são geridas através da fachada.

**Conclusão:** secure storage é infraestrutura concreta e não precisa fazer parte do contrato dos clientes atuais.

## Contrato que deve ser protegido antes da redução de superfície

A Fase 0 deve priorizar testes de contrato para:

1. importação Rust pela raiz:
   ```rust
   use durvald_core::{
       CoreConfig,
       CoreError,
       CoreResult,
       DurvaldCore,
       Track,
       Release,
       // demais DTOs públicos relevantes
   };
   ```
2. construção/abertura de `DurvaldCore`;
3. categorias de `CoreError`;
4. DTOs usados nas fronteiras;
5. geração dos bindings UniFFI;
6. compilação do cliente Swift contra os bindings;
7. compilação do cliente GTK contra a API Rust.

Esses testes permitem que uma fase posterior reduza os exports de infraestrutura sem confundir quebra de implementação com quebra do contrato real.

## Candidatos de redução em fases posteriores

Nenhuma das alterações abaixo pertence à Fase 0. Elas ficam registradas apenas como consequência deste inventário.

### Prioridade alta

```text
database::operations::* na raiz
pub mod database
```

Motivo: expõem diretamente detalhes e modelos de persistence sem consumidor frontend atual.

### Prioridade alta

```text
AudioPlayer
pub mod audio
```

Motivo: o frontend já possui uma fachada de playback em `DurvaldCore`.

### Prioridade alta

```text
LastFmClient
SecureStore
SecureStoreError
```

Motivo: são implementações concretas já encapsuladas por `DurvaldCore`.

### Prioridade média

```text
pub mod enrichment
pub mod metadata
```

Motivo: expõem infraestrutura e modelos internos enquanto a fronteira frontend já existe em `api::*`.

### Prioridade média

```text
DurvaldCore::db_pool
DurvaldCore::audio_player
DurvaldCore::lastfm
DurvaldCore::covers_dir
```

Motivo: o próprio código os classifica como accessors internos e nenhum consumidor atual foi encontrado.

### Avaliar separadamente

```text
pub mod core
pub mod api
```

O tipo `DurvaldCore` e os DTOs devem permanecer públicos. A necessidade de preservar também os caminhos de módulo `durvald_core::core::*` e `durvald_core::api::*` deve ser decidida conscientemente antes de tornar esses módulos privados, pois esses paths são tecnicamente públicos mesmo que os clientes atuais usem majoritariamente reexports da raiz.

## Decisão da F0.02

Para a migração arquitetural, considerar como **contrato protegido**:

```text
DurvaldCore
+
api::*
+
CoreError
+
UniFFI
+
comportamento observado pelos clientes
```

Considerar como **superfície legada ou infraestrutura pública a investigar/reduzir depois**:

```text
AudioPlayer
database::*
database::operations::* reexportado
LastFmClient
SecureStore / SecureStoreError
metadata::*
enrichment::* de infraestrutura
accessors concretos de DurvaldCore
```

A ausência de consumidor in-repo não autoriza remoção imediata. A remoção deve ocorrer apenas em uma fase posterior, com os testes de contrato da Fase 0 ativos e com a alteração explicitamente tratada como mudança de superfície pública.

## Critério de conclusão da F0.02

- [x] exports da raiz inventariados;
- [x] módulos públicos inventariados por responsabilidade;
- [x] consumidor Rust atual identificado;
- [x] consumidor Swift/UniFFI identificado;
- [x] uso direto dos reexports legados verificado nos clientes atuais;
- [x] API deliberada separada de infraestrutura concreta;
- [x] accessors públicos internos de `DurvaldCore` identificados;
- [x] contratos que devem permanecer estáveis durante a migração registrados;
- [x] candidatos a redução futura registrados sem alterar código de produção.
