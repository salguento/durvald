Sim. A **Fase 0** deve ser tratada como uma fase própria de engenharia, não como “escrever alguns testes antes de refatorar”.

O objetivo dela é responder:

> **“O que o Durvald faz hoje, quais comportamentos são contratos que precisamos preservar e como detectaremos imediatamente se a migração arquitetural mudar alguma coisa sem intenção?”**

Ela não deve alterar arquitetura nem comportamento de produto.

Hoje já existe uma base útil: `.github/workflows/ci.yml` executa formatação, Clippy, build normal, build com UniFFI e `cargo test` em Linux e macOS, além de gerar bindings Swift, compilar o cliente macOS e executar `DurvaldTests`. Ao mesmo tempo, `durvald-core/tests/` praticamente não contém uma suíte de integração — há atualmente apenas fixtures — então existe espaço para criar uma camada explícita de characterization/integration tests.

Eu estruturaria a Fase 0 assim.

---

# Fase 0 — Caracterização e proteção do comportamento atual

## Objetivo final

Ao terminar esta fase, queremos possuir:

```
Comportamento atual
        │
        ├── documentado
        ├── classificado
        ├── testado
        └── executado automaticamente
                 │
                 ▼
        baseline arquitetural
```

Depois disso podemos mover código de:

```
core.rs
```

para:

```
application/
domain/
infrastructure/
```

com muito mais confiança.

---

# 0.1 — Congelar o escopo da fase

Primeiro, estabelecer explicitamente o que **não** pertence à Fase 0.

Não implementar:

```
nova arquitetura
novos traits
repositories
application services
novas crates
Soulseek
Jellyfin
mudança de schema sem necessidade de testes
mudança de comportamento
otimização de performance
```

Permitido:

```
testes
fixtures
test helpers
instrumentação para teste
documentação
scripts de validação
pequenas mudanças que aumentem testabilidade
```

Mesmo mudanças para testabilidade devem ser conservadoras.

Por exemplo, transformar:

```
fn foo(...)
```

em:

```
pub(crate) fn foo(...)
```

pode ser aceitável.

Mudar algoritmo não.

### Entregável

Um documento, por exemplo:

```
docs/architecture/migration-phase-0.md
```

com:

```
objetivo
escopo
não-objetivos
comandos de validação
critério de conclusão
```

---

# 0.2 — Criar um inventário da superfície pública

Antes de testar comportamentos internos, precisamos saber qual é o contrato observado pelos clientes.

Hoje `src/lib.rs` expõe:

```
pub mod api;
pub mod audio;
pub mod core;
pub mod database;
pub mod enrichment;
pub mod lastfm;
pub mod metadata;
pub mod secure_store;
```

e também reexporta:

```
DurvaldCore
AudioPlayer
database::operations::*
LastFmClient
SecureStore
```

Inclusive existe o comentário:

```
// Re-export internal types for backward compatibility during transition
```

Isso é muito relevante.

Antes de remover esses exports em fases posteriores, precisamos saber quem depende deles.

### Trabalho

Produzir uma tabela semelhante a:

| Superfície               | Consumidor | Deve permanecer estável? |
| ------------------------ | ---------- | ------------------------ |
| `DurvaldCore`            | Swift/GTK  | sim                      |
| DTOs `api::*`            | Swift/GTK  | sim                      |
| UniFFI                   | Swift      | sim                      |
| `AudioPlayer` exportado  | verificar  | talvez                   |
| DB operations exportadas | verificar  | talvez não               |
| `LastFmClient`           | verificar  | talvez não               |
| `SecureStore`            | verificar  | talvez não               |

### Pergunta importante

Pesquisar no repositório:

```
durvald_core::AudioPlayer
durvald_core::LastFmClient
durvald_core::database
```

etc.

Assim sabemos quais “APIs públicas” são realmente contratos e quais são apenas dívida histórica.

### Entregável

```
docs/architecture/current-public-surface.md
```

---

# 0.3 — Inventariar todos os casos de uso atuais

Agora deixamos de pensar em arquivos e começamos a pensar em comportamento.

Criar um catálogo de casos de uso.

Eu começaria com estas áreas.

### Lifecycle

```
open core
initialize directories
initialize database
run migrations
restore state
```

### Library

```
scan library
cancel scan
scan progress
add library path
remove library path
list tracks
paginate tracks
search
list artists
list releases
```

### Playback

```
play
pause
resume
stop
seek
next
previous
queue
shuffle
repeat
volume
restore session
gapless transition
```

### History

```
record completed playback
list history
pagination
repeat-one creates additional history entry
```

### Playlist

```
create
rename
delete
add track
remove track
reorder
play playlist
```

### Metadata

```
read metadata
edit metadata
persist changes
artwork extraction
artwork validation
```

### Enrichment

```
resolve artist identity
refresh artist
refresh release
cache behavior
failure policy
diagnostics
artwork retrieval
```

### Last.fm

```
authenticate
now playing
scrobble
pause/resume timing
eligibility
logout
credentials
```

### Settings

```
read
write
restore
invalid input
```

### Secure storage

```
store
retrieve
delete
missing value
platform errors
```

### Resultado

Cada caso de uso recebe um identificador:

```
LIB-001 List tracks
LIB-002 Paginate tracks
PLAY-001 Play track
PLAY-002 Pause
PLAY-003 Resume
...
```

Isso parece burocrático, mas facilita muito a migração.

Mais tarde uma PR pode dizer:

> “Fase 3 modifica PlaybackApplication; PLAY-001–PLAY-014 continuam verdes.”

---

# 0.4 — Classificar os casos de uso por criticidade

Nem tudo merece a mesma proteção.

Eu usaria três níveis.

### P0 — crítico

Se quebrar, Durvald essencialmente deixa de funcionar.

Exemplos:

```
core open
database migration
scan
playback
queue
session restoration
FFI initialization
```

### P1 — funcional importante

```
playlists
history
metadata editing
Last.fm
enrichment
```

### P2 — secundário / edge cases

```
diagnostics
detalhes específicos de cache
casos incomuns de metadata
```

Isso determina a ordem de criação dos testes.

---

# 0.5 — Identificar invariantes

Esse é um dos passos mais importantes.

Um teste não deve verificar só:

> “a função retornou `Ok`”.

Ele precisa proteger as regras existentes.

Exemplos que já aparecem no README do core:

### Scan

```
somente um scan pode existir simultaneamente

scan cancelado:
    não deve reconciliar/deletar arquivos existentes

scan completo:
    deve reconciliar arquivos removidos
```

### Artwork

```
covers_dir é a área gerenciada

path fora de covers_dir:
    InvalidInput

symlink escapando de covers_dir:
    rejeitado
```

### Playback

```
history persistente
≠
queue navigation history
```

### Gapless

```
automatic advancement
não depende de polling da UI
```

### Errors

Clientes devem poder depender de:

```
InvalidInput
NotFound
Storage
Playback
Authentication
Network
```

e **não** do texto da mensagem.

Essas são invariantes arquiteturalmente valiosas porque continuarão verdadeiras mesmo depois que classes e módulos mudarem completamente.

---

# 0.6 — Criar uma matriz de cobertura

Agora unir:

```
caso de uso
+
invariante
+
tipo de teste
```

Exemplo:

|ID|Caso|Teste|
|---|---|---|
|CORE-001|abrir DB novo|integração|
|CORE-002|reabrir DB existente|integração|
|LIB-001|scan simples|integração|
|LIB-002|cancelar scan|integração|
|LIB-003|scan concorrente rejeitado|integração|
|PLAY-001|carregar track|integração|
|PLAY-002|persistir session|integração|
|HIST-001|completion registra histórico|integração|
|API-001|erros públicos estáveis|contrato|
|FFI-001|bindings Swift geram|contrato|

Essa matriz vira a checklist da Fase 0.

---

# 0.7 — Criar uma infraestrutura de fixtures temporárias

Hoje `durvald-core/tests/fixtures` já existe, mas é extremamente pequeno.

Eu criaria infraestrutura padronizada.

Algo como:

```
tests/
├── common/
│   ├── mod.rs
│   ├── database.rs
│   ├── filesystem.rs
│   ├── audio.rs
│   └── fixtures.rs
│
├── fixtures/
│   ├── audio/
│   ├── metadata/
│   └── network/
│
├── core_lifecycle.rs
├── library.rs
├── playback.rs
├── playlists.rs
├── history.rs
├── metadata.rs
├── enrichment.rs
└── public_api.rs
```

### Cada teste deve possuir seu ambiente

Por exemplo:

```
temp dir
├── app-support/
├── covers/
├── library/
└── durvald.sqlite
```

Nada deve depender de:

```
~/Music
DB do desenvolvedor
Keychain real
rede real
```

quando for evitável.

---

# 0.8 — Criar um `TestCore`

Um helper simples pode reduzir muito a repetição.

Por exemplo conceitualmente:

```
struct TestCore {
    core: Arc<DurvaldCore>,
    root: TempDir,
    library_dir: PathBuf,
}
```

Com:

```
impl TestCore {
    async fn new() -> Self;
    fn library_path(&self) -> &Path;
    fn add_fixture(&self, ...);
}
```

Importante:

`TestCore` deve ser apenas infraestrutura de teste.

Não deve virar abstração de produção.

---

# 0.9 — Baseline de banco de dados

SQLite será um dos componentes mais mexidos posteriormente.

Portanto, precisamos de uma proteção forte antes da migração.

Testes mínimos:

```
DB-001
DB vazio abre corretamente

DB-002
migrations são idempotentes

DB-003
dados persistem após fechar/reabrir

DB-004
track persiste corretamente

DB-005
artist/release relationships persistem

DB-006
playlist persiste

DB-007
history persiste

DB-008
last session persiste
```

Também é interessante possuir um teste:

```
create DB
→ perform operations
→ close core
→ reopen core
→ verify state
```

Isso testa uma propriedade muito mais real do que queries isoladas.

---

# 0.10 — Baseline da biblioteca

Depois proteger scan/indexação.

Fixtures pequenas:

```
library/
├── Artist A/
│   └── Album A/
│       ├── 01.flac
│       └── 02.mp3
└── Artist B/
    └── song.ogg
```

Casos:

```
scan inicial
rescan sem mudanças
arquivo adicionado
arquivo removido
arquivo modificado
diretório removido
arquivo inválido
extensão não suportada
cancelamento
scan concorrente
```

Um teste especialmente importante:

```
scan inicial
↓
3 tracks

cancel partial rescan
↓
continua com dados anteriores íntegros
```

porque o README explicitamente promete essa semântica.

---

# 0.11 — Baseline de paginação e queries

Isso parece simples, mas será muito afetado quando `LibraryApplication` for extraído.

Testar:

```
page size 0
page size acima do máximo
offset
next offset
última página
coleção vazia
ordenação
search
```

Isso protege funções como:

```
pagination_window
finish_page
```

mesmo que posteriormente elas mudem de módulo.

---

# 0.12 — Baseline de playback

Playback exige separar duas coisas.

### Testes determinísticos

Podem rodar sempre:

```
queue ordering
next
previous
repeat
shuffle semantics
seek bounds
session state
history state
scrobble eligibility
```

### Testes dependentes de hardware/backend

Áudio físico é mais difícil em CI.

Evitar transformar a Fase 0 numa luta contra dispositivo ALSA/CoreAudio.

O foco deve ser primeiro:

```
estado do player
transições
queue
persistência
```

e não:

> “ouviu som no alto-falante”.

---

# 0.13 — Testar persistência de sessão

Esse é particularmente importante porque hoje `core.rs` contém diretamente:

```
persist_playback_session
persist_session_progress
persist_session_volume
```

Esses métodos provavelmente serão movidos na Fase 3.

Portanto precisamos congelar comportamento antes.

Testes:

```
volume
shuffle
repeat
current track
queue
position
source context
```

Fluxo:

```
Core A
↓
configura playback
↓
persist
↓
drop

Core B
↓
open same DB
↓
verify state
```

Esse será um ótimo characterization test.

---

# 0.14 — Baseline de histórico

Proteger a distinção:

```
queue navigation history
≠
persistent listening history
```

Casos:

```
track completado uma vez
track completado duas vezes
Repeat One completado várias vezes
skip antes de completion
previous navigation
```

A refatoração de playback não poderá acidentalmente fundir esses conceitos.

---

# 0.15 — Baseline de playlists

Testes end-to-end no core:

```
create
rename
add
remove
reorder
delete
persist/reopen
```

Também:

```
playlist inexistente → NotFound
track inexistente → NotFound
```

Esses testes são especialmente úteis quando DB operations forem movidas para repositories.

---

# 0.16 — Baseline de metadata

Separar:

```
read
write
```

Fixtures com metadata conhecida:

```
fixture.flac

title = ...
artist = ...
album = ...
track = ...
disc = ...
year = ...
```

Teste:

```
read
→ expected model
```

E para edição:

```
copy fixture para temp
↓
edit
↓
read novamente
↓
verify
```

Nunca editar a fixture original.

---

# 0.17 — Baseline de artwork

Testar especialmente segurança de paths.

```
arquivo dentro de covers_dir
→ permitido

arquivo fora
→ InvalidInput

../ traversal
→ InvalidInput

symlink saindo da directory
→ InvalidInput
```

Isso protege um contrato de segurança, não apenas funcionalidade.

---

# 0.18 — Baseline de enrichment

Essa área merece testes em três níveis.

### Pure/domain-ish

```
identity matching
policy
cache policy
failure classification
```

### Provider parsing

Usando JSON/HTML fixtures locais:

```
MusicBrainz response
Wikidata response
Wikipedia response
Last.fm response
```

### Service orchestration

Com transporte simulado:

```
provider success
provider timeout
rate limit
cached failure
retry
concurrent request/single-flight
```

Importante:

CI não deve depender de MusicBrainz ou Wikipedia reais.

---

# 0.19 — Baseline de Last.fm

Separar regras puras de rede.

Por exemplo:

```
scrobble eligibility
```

deve ter testes exhaustivos.

Casos:

```
track muito curta
menos de X segundos
mais de threshold
pause/resume
multiple pauses
```

Para HTTP:

```
fixtures/mock
```

e não Last.fm real.

---

# 0.20 — Baseline de secure storage

Aqui existe um problema: Keychain/Secret Service são recursos do OS.

Então a Fase 0 deveria distinguir:

```
unit behavior
```

de:

```
platform smoke test
```

Não vale transformar CI em um teste frágil do keychain.

O mínimo é proteger:

```
error mapping
key naming
credentials not leaked into diagnostic messages
```

---

# 0.21 — Testes do contrato `CoreError`

Isso merece um arquivo dedicado:

```
tests/public_errors.rs
```

O contrato atual possui:

```
InvalidInput
NotFound
Storage
Playback
Authentication
Network
```

Criar casos representativos que garantam que:

```
input inválido
→ InvalidInput

entity inexistente
→ NotFound
```

etc.

Não testar textos exatos, salvo quando texto em si for contrato.

A intenção é preservar a **categoria**.

---

# 0.22 — Criar testes específicos da API pública

Uma diferença importante:

```
teste interno
```

pode continuar passando mesmo que você quebre a API pública.

Por isso, criar testes que importem a biblioteca como um consumidor faria.

Algo como:

```
use durvald_core::{
    CoreConfig,
    CoreError,
    DurvaldCore,
    Track,
};
```

Esses testes protegem exports.

Mais tarde, quando reduzirmos a superfície pública, alterações serão deliberadas.

---

# 0.23 — Criar um contrato UniFFI

Como macOS depende dos bindings Swift, uma refatoração Rust pode compilar normalmente mas quebrar FFI.

Já existe no CI:

```
cargo build --features uniffi
generate-swift-bindings.sh
xcodebuild
```

Isso é excelente.

Na Fase 0 eu adicionaria uma verificação mais explícita da API gerada.

Por exemplo:

```
generate bindings
↓
compilar consumidor mínimo
```

O cliente macOS já exerce boa parte disso.

O importante é tornar esse pipeline um gate obrigatório.

---

# 0.24 — Fortalecer testes Swift da ponte

Não precisamos testar toda a UI.

O alvo é:

```
DurvaldCoreStore ↔ generated Swift binding ↔ DurvaldCore
```

Casos essenciais:

```
open
reload library
basic query
error mapping
playback state conversion
enrichment DTO conversion
```

Mocks Swift continuam úteis para UI.

Mas precisamos de alguns testes usando a implementação Rust real, porque mocks não detectam quebra de UniFFI.

---

# 0.25 — Smoke test GTK

O cliente GTK usa a API Rust diretamente.

Isso é uma vantagem.

No mínimo:

```
cargo check/build durvald-gtk
```

deve virar parte da baseline arquitetural.

Se hoje estiver separado em outro workflow, manter essa verificação como gate de migração.

Porque remover um export Rust pode:

```
macOS continuar funcionando
```

mas:

```
GTK quebrar
```

---

# 0.26 — Criar testes de restart/recovery

Esses são especialmente importantes para um desktop app.

Não testar apenas:

```
operation
→ result
```

Também testar:

```
operation
→ shutdown
→ restart
→ state
```

Para:

```
library
playlists
settings
history
playback session
enrichment cache
```

Isso protege a fronteira:

```
runtime state ↔ persistent state
```

que será muito mexida na arquitetura futura.

---

# 0.27 — Criar characterization tests para comportamentos estranhos

Essa é uma técnica importante.

Durante a Fase 0 podemos encontrar:

```
“isso parece errado”
```

Mas não devemos automaticamente corrigir.

Primeiro registrar:

```
current_behavior_foo
```

Se não soubermos se é bug ou contrato:

```
documentar
+
testar
```

Depois abrir issue separada.

Porque fazer:

```
architecture migration
+
bug fix
```

na mesma mudança torna regressões difíceis de diagnosticar.

---

# 0.28 — Classificar bugs descobertos

Durante a Fase 0 certamente aparecerão comportamentos questionáveis.

Usaria três categorias:

```
A — comportamento claramente intencional
→ characterization test

B — bug confirmado
→ issue separada

C — comportamento ambíguo
→ documentar e preservar temporariamente
```

A arquitetura não deve “corrigir acidentalmente” categoria B ou C.

---

# 0.29 — Baseline de concorrência

O core usa bastante:

```
Arc
Mutex
Tokio
spawn_blocking
AtomicBool
watch
AbortHandle
```

Portanto precisamos proteger algumas propriedades concorrentes.

Casos relevantes:

```
dois scans simultâneos
concurrent enrichment request
cancel enrichment
play + next race
metadata edit serialization
DB blocking work
```

Não precisamos testar todas as possíveis interleavings.

Mas devemos testar explicitamente as garantias que o código promete.

---

# 0.30 — Testes de cancelamento

Cancelamento é frequentemente destruído por refatorações.

Criar testes para:

```
scan cancellation
enrichment cancellation
```

garantindo não somente:

```
operation returned
```

mas:

```
state final correto
nenhuma persistência posterior indevida
```

---

# 0.31 — Baseline de performance, mas sem otimizar

Eu adicionaria algumas **medições**, não metas rígidas inicialmente.

Por exemplo:

```
abrir DB com N tracks
listar primeira página
scan fixture
refresh cache
```

O objetivo é descobrir regressões grosseiras posteriores.

Algo como:

```
baseline:
list 100 tracks = X
```

não significa que CI deva falhar porque ficou 10% mais lento.

Primeiro guardar referência.

Microbenchmarking rígido pode entrar depois.

---

# 0.32 — Baseline de schema

Antes de reorganizar persistence:

```
capturar versão atual do schema
```

e testar:

```
new DB
→ current schema

old fixture DB
→ migration
→ current schema
```

Idealmente manter pelo menos uma fixture de banco anterior, se houver uma versão real disponível.

Isso protege futuras mudanças de `database/migrations.rs`.

---

# 0.33 — Definir níveis oficiais de teste

Ao final, eu deixaria explícito:

```
L1 — Unit
rápido, puro

L2 — Integration
SQLite/temp filesystem/core

L3 — Contract
public Rust API / UniFFI

L4 — Client
Swift/GTK

L5 — Manual/system
áudio físico / credenciais reais / rede real
```

E cada nível responde por coisas diferentes.

---

# 0.34 — Criar os comandos oficiais

Não queremos que cada desenvolvedor execute coisas diferentes.

Por exemplo:

```
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --package durvald-core
cargo test --package durvald-core --features uniffi
```

mais:

```
Swift tests
GTK build
bindings generation
```

Idealmente um script:

```
scripts/verify-architecture-baseline.sh
```

ou equivalente.

Ele não precisa substituir CI.

Só fornecer um comando local reproduzível.

---

# 0.35 — Tornar CI o gate da migração

O CI atual já possui boa parte da estrutura.

Eu o complementaria até termos:

```
Rust Linux
    fmt
    clippy
    build
    tests
    integration tests

Rust macOS
    build
    tests

UniFFI
    generation
    compile

macOS
    build
    tests

GTK
    build/check
```

Nenhuma PR das fases seguintes deveria ser mergeada com um desses gates quebrado.

---

# 0.36 — Criar um mapa comportamento → código atual

Agora que os testes existem, registrar onde cada responsabilidade mora **antes da migração**.

Exemplo:

```
PLAY-001 Play track
→ core.rs
→ audio/player.rs
→ database/operations.rs
→ lastfm.rs

LIB-001 Scan library
→ core.rs
→ metadata.rs
→ artwork.rs
→ database/operations.rs
```

Isso será extremamente útil na extração dos application services.

Podemos enxergar:

```
um caso de uso
→ atravessa 4 módulos
```

e decidir o que deve ser orquestrado por `PlaybackApplication`, por exemplo.

---

# 0.37 — Produzir o mapa de dependências atual

Também documentar:

```
core.rs
    → database
    → audio
    → lastfm
    → enrichment
    → metadata
    → secure_store

enrichment/service
    → database
    → providers
    → transport
```

Não é necessário gerar um UML perfeito.

Uma matriz simples:

|módulo|depende de|
|---|---|
|core|db, audio, lastfm, enrichment|
|enrichment|db, HTTP providers|
|audio|Kira/Symphonia|
|database|rusqlite|
|metadata|lofty|
|secure_store|keyring|

já serve.

Depois poderemos comparar:

```
antes
vs
depois
```

---

# 0.38 — Identificar seams para refatoração

Ao analisar testes e dependências, marcar pontos naturais para extração.

Por exemplo:

```
persist_playback_session
→ futuro PlaybackRepository/Application

run_database
→ futura infrastructure boundary

report_lastfm_track_started
→ futuro ScrobblingPort

pagination_window
→ LibraryApplication

EnrichmentService
→ futuros enrichment use cases
```

Não refatorar ainda.

Apenas marcar.

Isso transforma a Fase 1–3 em trabalho planejado, não exploração às cegas.

---

# 0.39 — Registrar dívida arquitetural observada

Criar uma lista concreta, não genérica.

Exemplos observáveis hoje:

```
core.rs muito grande

DurvaldCore conhece infraestrutura concreta

database operations reexportadas publicamente

modelos públicos/persistência/domínio parcialmente misturados

Last.fm participa de múltiplas responsabilidades

EnrichmentService muito grande

database/enrichment.rs muito grande
```

Cada item deverá apontar para uma fase futura.

Assim evitamos tentar resolver tudo na Fase 0.

---

# 0.40 — Criar a baseline oficial

Ao final, gerar um documento:

```
docs/architecture/baseline-v1.md
```

contendo algo como:

```
Commit baseline:
<sha>

Rust tests:
N passing

Swift tests:
N passing

GTK build:
passing

UniFFI:
passing

Critical use cases:
X/Y protected

Known bugs:
...

Known architectural debt:
...

Public surface:
...
```

O SHA é especialmente importante.

A partir dali podemos dizer:

```
Arquitetura antiga conhecida
= baseline commit X

Migração começa após X
```

---

# Critérios objetivos para concluir a Fase 0

Eu **não** encerraria a fase simplesmente porque “adicionamos vários testes”.

Ela termina quando estes pontos forem satisfeitos:

```
✓ superfície pública inventariada

✓ casos de uso P0 catalogados

✓ casos P0 protegidos por testes adequados

✓ invariantes importantes documentadas

✓ lifecycle/DB protegidos

✓ library scan protegido

✓ playback state protegido

✓ session persistence protegida

✓ history protegido

✓ playlists protegidas

✓ metadata protegido

✓ enrichment básico protegido

✓ CoreError protegido

✓ UniFFI validado

✓ Swift build/test validado

✓ GTK build validado

✓ restart/recovery coberto onde relevante

✓ CI executa toda baseline

✓ bugs descobertos separados da migração

✓ mapa de dependências atual documentado

✓ baseline commit registrada
```

Não considero necessário atingir 100% de cobertura.

Um alvo muito mais útil seria:

> **100% dos fluxos críticos conhecidos têm pelo menos um teste de caracterização; partes puras importantes possuem testes unitários mais detalhados.**

---

# Ordem concreta de execução

Se fôssemos implementar a Fase 0 agora, eu dividiria em aproximadamente estes blocos:

```
0A — Inventário
    public API
    casos de uso
    invariantes
    dependências

0B — Test infrastructure
    temp dirs
    fixture DB
    TestCore
    audio fixtures
    network fixtures

0C — Core baseline
    open
    DB
    migrations
    errors

0D — Library baseline
    scan
    cancellation
    queries
    pagination

0E — Playback baseline
    queue
    state
    session
    history

0F — Feature baseline
    playlists
    metadata
    artwork
    settings

0G — External integration baseline
    enrichment
    Last.fm
    secure store

0H — Boundary baseline
    Rust public API
    UniFFI
    Swift
    GTK

0I — Architecture documentation
    dependency map
    behavior map
    known debt
    migration seams

0J — CI gate + baseline
```

Eu faria nessa ordem porque cada bloco constrói a infraestrutura necessária para o próximo.

---

# O resultado arquitetural da Fase 0

Visualmente, **a arquitetura praticamente não muda**:

```
ANTES                       DEPOIS DA FASE 0

DurvaldCore                 DurvaldCore
   │                           │
database                    database
audio                       audio
enrichment                  enrichment
...                         ...
```

O que muda é o que existe **ao redor dela**:

```
                    CONTRACT TESTS
                          │
             ┌────────────▼────────────┐
             │                         │
       CHARACTERIZATION          INTEGRATION
             │                         │
             └────────────┬────────────┘
                          ▼
                  arquitetura atual
                          │
                          ▼
                   conhecida e segura
```

Isso é exatamente o que queremos.

A Fase 0 não melhora diretamente a arquitetura. Ela transforma a arquitetura atual de algo que temos medo de mexer em algo que podemos **refatorar com feedback rápido e mensurável**.

E para a migração específica do Durvald, eu consideraria **playback/session, library scan, persistence e API/UniFFI** os quatro pilares que precisam estar melhor protegidos antes de começar a extrair `Application Services`.