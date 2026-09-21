Sim. Eu faria essa migração como uma **refatoração arquitetural incremental**, não como uma reescrita. O objetivo seria chegar a:

> **monólito modular + hexagonal pragmática + catálogo canônico + adapters especializados**

sem implementar Soulseek, Jellyfin ou qualquer integração futura durante a migração.

A regra central seria: **primeiro reorganizar o que já existe; só criar abstrações quando o código atual provar que elas são necessárias.**

---

# Estado inicial → estado desejado

Hoje, simplificando:

```
durvald-core
│
├── api
│
├── DurvaldCore                 ← facade + muita orquestração
│
├── database                    ← SQLite + operações
├── audio                       ← player/decoder/gapless
├── enrichment                  ← service/policy/providers
├── lastfm
├── metadata
├── metadata_edit
├── artwork
└── secure_store
```

O problema principal não é essa divisão funcional.

O problema é que a direção das dependências ainda tende a ser:

```
DurvaldCore
   │
   ├── rusqlite
   ├── AudioPlayer
   ├── LastFmClient
   ├── EnrichmentService
   └── filesystem
```

O estado desejado seria aproximadamente:

```
                  API
                   │
             DurvaldCore
             facade fina
                   │
            application/
        ┌──────────┼───────────┐
        │          │           │
     library    playback    enrichment
        │          │           │
        └────── domain ─────────┘
                   │
                 ports
                   │
             adapters/infra
        ┌──────────┼──────────┐
      SQLite      audio      HTTP
```

Tudo isso ainda pode continuar em **uma única crate**.

---

# Princípios da migração

Eu estabeleceria cinco regras antes de começar:

1. **não quebrar a API pública sem necessidade;**
2. **não mudar comportamento e arquitetura na mesma etapa;**
3. **não introduzir traits apenas para “parecer hexagonal”;**
4. **não separar em múltiplas crates durante essa primeira migração;**
5. **cada etapa deve deixar a aplicação compilando e os testes passando.**

Especialmente importante:

```
refatoração arquitetural
≠
reescrita
```

---

# Fase 0 — estabelecer uma linha de base

Antes de mover qualquer coisa, precisamos saber o que não pode quebrar.

### Objetivo

Transformar o comportamento atual em um contrato verificável.

### Trabalho

Mapear os principais fluxos:

```
open core
scan library
list tracks
list artists
list releases
play
pause
seek
next / previous
queue
history
playlists
metadata editing
enrichment
Last.fm
settings
secure credentials
```

E separar testes em:

```
unit
integration
public API / FFI
```

O ponto não é atingir cobertura de 100%.

É proteger as fronteiras que serão mexidas.

### Critério de conclusão

Deve ser possível executar uma suíte que nos diga:

> "a reorganização interna não alterou os principais comportamentos observáveis."

---

# Fase 1 — definir explicitamente os módulos arquiteturais

Antes de mover código, documentaria as responsabilidades.

Criaria algo semelhante a:

```
durvald-core/src/

api/
application/
domain/
ports/
infrastructure/
```

Mas inicialmente **sem mover tudo para esses diretórios**.

Primeiro estabelecemos o modelo mental.

### Responsabilidades

```
api/
    contrato com Swift/GTK

application/
    casos de uso e coordenação

domain/
    conceitos e regras independentes de infraestrutura

ports/
    contratos necessários pelo application/domain

infrastructure/
    SQLite, filesystem, HTTP, keyring, audio backend
```

### Uma regra importante

Não precisa existir:

```
domain/
```

cheio de entidades artificiais desde o começo.

Por exemplo, `EnrichmentPolicy` pode ser claramente domain.

Mas uma função simples de paginação talvez possa continuar próxima da aplicação.

---

# Fase 2 — transformar `DurvaldCore` em uma facade real

Essa seria provavelmente a primeira grande mudança estrutural.

Hoje `DurvaldCore` possui diretamente:

```
db_pool
audio_player
lastfm
enrichment
scan state
playback state
metadata edit coordination
...
```

e `core.rs` já ultrapassa 100 KB.

O objetivo passa a ser:

```
DurvaldCore
│
├── LibraryApplication
├── PlaybackApplication
├── EnrichmentApplication
├── MetadataApplication
└── IntegrationApplication
```

Por exemplo, hoje podemos ter conceitualmente:

```
impl DurvaldCore {
    pub async fn play_track(&self, id: u64) -> CoreResult<()> {
        // 100 linhas de coordenação...
    }
}
```

O destino seria:

```
impl DurvaldCore {
    pub async fn play_track(&self, id: u64) -> CoreResult<()> {
        self.playback.play_track(id).await
    }
}
```

A API externa continua igual.

### Estrutura inicial

```
application/
├── library.rs
├── playback.rs
├── enrichment.rs
├── metadata.rs
├── playlists.rs
└── settings.rs
```

### Critério de conclusão

`DurvaldCore` deve passar a responder principalmente por:

```
construction
lifecycle
public API delegation
cross-module coordination excepcional
```

e não pela implementação detalhada dos casos de uso.

---

# Fase 3 — extrair primeiro `PlaybackApplication`

Eu começaria por playback porque a responsabilidade já está relativamente bem identificada.

Hoje existem:

```
DurvaldCore orchestration
       +
AudioPlayer
       +
session persistence
       +
history
       +
Last.fm tracking
```

O objetivo seria:

```
PlaybackApplication
│
├── AudioPlayer
├── playback persistence
├── history coordination
└── scrobbling coordination
```

Mas sem abstrair Kira imediatamente.

Inicialmente:

```
struct PlaybackApplication {
    player: Arc<Mutex<AudioPlayer>>,
    ...
}
```

Isso já reduz dramaticamente `DurvaldCore`.

Só depois analisamos se `AudioPlayer` precisa virar port.

### Primeira regra importante

Não fazer:

```
trait AudioPort
```

apenas porque estamos migrando para hexagonal.

Primeiro movemos a responsabilidade.

Depois vemos onde existe necessidade real de inversão.

---

# Fase 4 — extrair `LibraryApplication`

Aqui entrariam os casos relacionados ao catálogo local atual:

```
scan
tracks
artists
releases
history queries
library paths
search
pagination
```

Estrutura aproximada:

```
application/library/
├── service.rs
├── scanning.rs
├── queries.rs
└── pagination.rs
```

O objetivo é começar a separar:

```
"o que quero fazer"

de

"como SQLite faz isso"
```

Por exemplo:

```
LibraryApplication.list_tracks()
```

pode inicialmente continuar chamando:

```
database::operations::list_tracks()
```

Essa etapa ainda não exige repositories.

---

# Fase 5 — separar catálogo de persistência

Essa é uma das fases conceitualmente mais importantes.

Hoje existe certa proximidade entre:

```
database::models
```

e:

```
modelo do Durvald
```

O objetivo seria deixar claro que existem três tipos diferentes de estrutura.

### 1. Modelo público

```
api::Track
api::Artist
api::Release
```

DTOs para clientes.

### 2. Modelo de domínio/catálogo

```
domain::Track
domain::Artist
domain::Release
```

Conceitos internos.

### 3. Modelo de persistência

```
infrastructure::sqlite::TrackRow
```

Como SQLite armazena os dados.

O fluxo seria:

```
SQLite Row
    ↓
domain model
    ↓
API DTO
```

E não:

```
SQLite model
     ↓
direto para UI
```

Isso cria a base para o **catálogo canônico**.

---

# Fase 6 — introduzir o catálogo canônico

Aqui não estamos adicionando nenhuma fonte externa.

Estamos apenas tornando explícito que:

```
Artist
Release
Track
```

são entidades do Durvald, e não simplesmente reflexos das tabelas SQLite.

Estrutura possível:

```
domain/catalog/
├── artist.rs
├── release.rs
├── track.rs
└── identity.rs
```

Identificadores também poderiam começar a ganhar tipos próprios:

```
struct TrackId(i64);
struct ArtistId(i64);
struct ReleaseId(i64);
```

em vez de:

```
i64
```

espalhado pelo core.

Isso é particularmente valioso porque evita erros como:

```
play_track(artist_id)
```

ser semanticamente possível apenas porque ambos são `i64`.

### Importante

Eu não transformaria imediatamente tudo em aggregates complexos de DDD.

Começaria com:

```
identidade
modelos
invariantes reais
```

---

# Fase 7 — reorganizar SQLite como adapter

Só agora eu atacaria seriamente o banco.

Hoje:

```
database/
├── operations.rs
├── enrichment.rs
├── models.rs
└── ...
```

O destino poderia ser:

```
infrastructure/sqlite/
├── connection.rs
├── migrations.rs
├── library.rs
├── playback.rs
├── playlists.rs
├── enrichment.rs
└── models.rs
```

Aqui existe uma grande mudança de perspectiva:

Antes:

```
database
= parte central do core
```

Depois:

```
SQLite
= uma implementação da persistência necessária pela aplicação
```

---

# Fase 8 — introduzir ports de persistência seletivamente

Somente depois de extrair application services e SQLite eu introduziria traits.

Por exemplo, se `LibraryApplication` necessita destas operações:

```
find track
list tracks
save scan results
find artist
```

poderíamos chegar a:

```
trait CatalogRepository {
    async fn track(&self, id: TrackId) -> Result<Option<Track>>;
    async fn save_tracks(&self, tracks: &[Track]) -> Result<()>;
}
```

Implementação:

```
CatalogRepository
       ^
       |
SqliteCatalogRepository
```

Mas eu evitaria criar:

```
TrackRepository
ArtistRepository
ReleaseRepository
GenreRepository
...
```

automaticamente.

Pode ser melhor ter ports alinhados ao **uso da aplicação**:

```
CatalogRepository
PlaybackRepository
PlaylistRepository
EnrichmentRepository
```

A granularidade deve surgir da coesão.

---

# Fase 9 — transformar enrichment em um módulo arquitetural completo

Enrichment já está mais avançado estruturalmente que outras áreas:

```
identity
models
policy
cache
service
transport
providers
```

Mas há arquivos muito grandes:

```
service.rs             ~177 KB
database/enrichment.rs ~189 KB
```

Então eu faria uma segunda decomposição:

```
enrichment/
├── application/
│   ├── refresh_artist.rs
│   ├── refresh_release.rs
│   └── diagnostics.rs
│
├── domain/
│   ├── identity.rs
│   ├── policy.rs
│   └── models.rs
│
└── ports/
    ├── metadata_provider.rs
    ├── artwork_provider.rs
    └── repository.rs
```

Adapters:

```
infrastructure/enrichment/
├── musicbrainz.rs
├── wikidata.rs
├── wikipedia.rs
├── commons.rs
├── cover_art_archive.rs
└── lastfm.rs
```

Não necessariamente com esses nomes exatos, mas com essa separação conceitual.

---

# Fase 10 — separar transporte HTTP dos providers

Hoje enrichment possui `transport.rs`, o que já é um bom sinal.

Eu formalizaria esta fronteira:

```
MusicBrainzAdapter
      |
      v
HttpTransport
      |
      v
reqwest
```

Assim um provider não precisa saber detalhes de:

```
timeout
retry
rate limiting
headers
TLS
```

quando estes puderem ser compartilhados.

Mas novamente: abstrair apenas comportamentos realmente compartilhados.

---

# Fase 11 — reorganizar Last.fm

Last.fm atualmente atravessa duas preocupações:

```
playback/scrobbling
```

e:

```
metadata/enrichment
```

Essas duas responsabilidades deveriam continuar separadas mesmo usando o mesmo serviço externo.

Conceitualmente:

```
LastFmScrobblingAdapter
        ↑
ScrobblingPort
```

e:

```
LastFmMetadataAdapter
        ↑
MetadataProvider
```

Um mesmo cliente HTTP interno pode ser compartilhado.

A regra é:

> capacidade arquitetural ≠ fornecedor externo.

---

# Fase 12 — secure storage como port

Esse é um caso clássico onde a abstração é justificada.

```
application
     |
SecureCredentialStore
     ^
     |
KeyringAdapter
```

O application não deveria saber:

```
Keychain
Secret Service
Windows Credential Manager
```

A implementação atual baseada em `keyring` pode continuar exatamente como está internamente.

Só muda quem conhece quem.

---

# Fase 13 — metadata e filesystem

Também separaria claramente:

```
metadata/
```

como capacidade do core e:

```
Lofty
filesystem
image crate
```

como detalhes técnicos.

Possível desenho:

```
MetadataReader
      ^
      |
LoftyMetadataReader
```

Aqui eu teria mais cautela do que no secure store.

Se não houver ganho real em testes ou substituição, pode continuar como módulo concreto.

Essa é a parte **pragmática** da hexagonal.

---

# Fase 14 — composition root

Quando ports e adapters aparecem, alguém precisa conectá-los.

Essa responsabilidade deveria estar concentrada.

Por exemplo:

```
DurvaldCore::open()
        |
        +-- cria SQLite repositories
        +-- cria AudioPlayer
        +-- cria HTTP clients
        +-- cria Keyring store
        +-- cria EnrichmentApplication
        +-- cria PlaybackApplication
        +-- cria LibraryApplication
```

Esse lugar é chamado frequentemente de:

> **Composition Root**

Ele sabe quais implementações concretas usar.

Exemplo:

```
CatalogRepository
        =
SqliteCatalogRepository
```

O resto da aplicação não precisa saber disso.

---

# Fase 15 — limpar `lib.rs` e visibilidade dos módulos

Atualmente existe inclusive comentário de:

```
// Re-export internal types for backward compatibility during transition
```

e tipos internos como `AudioPlayer`, operações de banco e `LastFmClient` são reexportados.

Ao final da migração, eu reduziria isso.

Ideal:

```
public:
    api
    DurvaldCore

crate-private:
    application
    domain
    ports
    infrastructure
```

Ou seja, consumidores não deveriam poder fazer:

```
durvald_core::database::operations::...
```

se isso não fizer parte do contrato oficial.

Essa mudança fortalece muito a fronteira arquitetural.

---

# Fase 16 — consolidar os módulos

Nesse momento a estrutura poderia ficar aproximadamente:

```
durvald-core/src/

lib.rs

api/
├── catalog.rs
├── playback.rs
├── enrichment.rs
├── playlists.rs
└── settings.rs

core/
└── facade.rs

application/
├── library/
├── playback/
├── enrichment/
├── playlists/
├── metadata/
└── settings/

domain/
├── catalog/
├── playback/
└── enrichment/

ports/
├── catalog_repository.rs
├── playback_repository.rs
├── scrobbling.rs
├── enrichment_repository.rs
└── secure_store.rs

infrastructure/
├── sqlite/
├── audio/
├── metadata/
├── artwork/
├── http/
├── keyring/
└── providers/
    ├── musicbrainz/
    ├── wikidata/
    ├── wikipedia/
    ├── commons/
    ├── cover_art_archive/
    └── lastfm/
```

Eu não trataria essa árvore como dogma.

O objetivo é preservar:

```
API
 ↓
Application
 ↓
Domain / Ports
 ↑
Infrastructure
```

mais do que obter nomes de pastas perfeitos.

---

# Fase 17 — endurecer as dependências

Depois da reorganização, estabelecer regras explícitas:

```
domain
    NÃO depende de:
    - rusqlite
    - reqwest
    - Kira
    - keyring
    - UniFFI

application
    NÃO depende diretamente de:
    - rusqlite
    - reqwest
    - keyring

infrastructure
    PODE depender de:
    - tudo necessário para implementar ports

api
    NÃO expõe:
    - tipos de infraestrutura
```

Isso é onde a arquitetura começa efetivamente a se proteger.

---

# Fase 18 — decidir se múltiplas crates são necessárias

Só depois de tudo isso eu avaliaria:

```
durvald-domain
durvald-application
durvald-infrastructure
```

Minha expectativa é que, inicialmente, **não seja necessário**.

Uma única crate:

```
durvald-core
```

com boas regras de visibilidade provavelmente será suficiente.

Separaria em crates somente se aparecer um benefício concreto como:

```
compilação independente
reuso
testabilidade
feature flags
isolamento obrigatório de dependências
```

Não por estética arquitetural.

---

# Ordem prática que eu seguiria

Se transformarmos isso em execução real, eu faria nesta sequência:

1. proteger os principais fluxos com testes;
2. documentar boundaries e regras de dependência;
3. criar `application/`;
4. extrair `PlaybackApplication`;
5. extrair `LibraryApplication`;
6. extrair Playlists/Settings/Metadata conforme necessário;
7. reduzir `DurvaldCore` a facade;
8. separar modelos API, domínio e persistência;
9. introduzir IDs de domínio;
10. consolidar catálogo canônico;
11. reorganizar SQLite como infraestrutura;
12. introduzir repositories/ports onde comprovadamente úteis;
13. decompor `EnrichmentService`;
14. separar policies/models/providers do enrichment;
15. formalizar adapters dos providers atuais;
16. separar scrobbling Last.fm de metadata Last.fm;
17. formalizar secure storage como port/adapter;
18. estabelecer Composition Root;
19. reduzir exports públicos de `lib.rs`;
20. regenerar/verificar UniFFI;
21. rodar testes Rust + Swift + GTK;
22. documentar a arquitetura resultante;
23. só então avaliar divisão em crates.

---

# O que eu deliberadamente não faria nessa migração

Não incluiria:

```
Soulseek
Jellyfin
Navidrome
Plex
novos protocolos
streaming remoto
download manager
```

E também evitaria aproveitar a refatoração para adicionar:

```
event bus global
CQRS
microservices
actor system completo
dependency injection framework
```

Essas coisas podem ser discutidas depois, caso um problema real as justifique.

---

# Como saberemos que a migração terminou

Eu consideraria a migração arquitetural concluída quando conseguirmos desenhar o Durvald desta forma:

```
             SwiftUI / GTK
                    │
                    ▼
               Public API
                    │
                    ▼
               DurvaldCore
               thin facade
                    │
          ┌─────────┼─────────┐
          ▼         ▼         ▼
       Library   Playback  Enrichment
     Application Application Application
          │         │         │
          └──────┬──┴──┬──────┘
                 │     │
              Domain  Ports
                       ▲
                       │
          ┌────────────┼─────────────┐
          │            │             │
        SQLite       Audio         Providers
        adapter      adapter        adapters
```

e, principalmente, se pudermos responder claramente:

```
Onde fica um caso de uso?
→ application

Onde fica uma regra musical?
→ domain

Onde fica SQL?
→ infrastructure/sqlite

Onde fica reqwest?
→ infrastructure/adapters

Onde fica uma estrutura exposta ao Swift?
→ api

Quem monta tudo?
→ composition root

Quem o frontend chama?
→ DurvaldCore
```

Esse seria, para mim, o marco de uma arquitetura efetivamente otimizada — não porque o código “parece hexagonal”, mas porque **cada responsabilidade tem uma casa clara e a direção das dependências fica previsível**.