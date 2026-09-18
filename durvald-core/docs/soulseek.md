A melhor implementação para o Durvald é tratar o Soulseek como um subsistema novo de **aquisição**, separado do enrichment. O MusicBrainz continua responsável por dizer _o que é o release_; o Soulseek passa a responder _onde existem arquivos candidatos e como baixá-los_.

Hoje essa separação encaixa bem na arquitetura: a discografia remota já é persistida como `ExternalReleaseGroup`, com `musicbrainz_id`, título, tipo, data e eventual vínculo com um release local, e o cliente já diferencia releases locais dos “online only releases”. O `ArtistView` inclusive já mantém `discographyItems: [ExternalReleaseGroup]` e possui `onSelectExternalRelease`, que é o ponto natural para iniciar a aquisição.

## Arquitetura recomendada

Para a primeira implementação, eu **não implementaria o protocolo Soulseek diretamente em Rust**. Usaria o **slskd** como daemon Soulseek e faria o `durvald-core` falar com ele via REST.

O slskd já implementa busca, resultados, fila de downloads, progresso, cancelamento e retry. Ele roda como daemon inclusive no macOS e expõe API autenticada. [GitHub](https://github.com/slskd/slskd)

O fluxo ficaria:

```
MusicBrainz
    │
    ▼
ExternalReleaseGroup
    │
    │ "Procurar no Soulseek"
    ▼
AcquisitionService
    │
    ├── MusicBrainz: resolve tracklist/edição
    │
    └── SoulseekProvider
            │
            ▼
          slskd
            │
       search/results
            │
            ▼
      ReleaseCandidate[]
            │
       usuário escolhe
            │
            ▼
       DownloadJob
            │
          slskd
            │
     arquivo concluído
            │
            ▼
       import/scan Durvald
```

O ponto importante é: **Soulseek não deve virar `EnrichmentProvider::Soulseek`**. Os providers existentes representam fontes de metadados — MusicBrainz, Wikidata, Wikipedia, Commons e Cover Art Archive. Crie um domínio paralelo:

```
enrichment/
acquisition/
audio/
database/
```

---

# Fase 1 — abstração de aquisição no core

Criaria:

```
durvald-core/src/acquisition.rs
durvald-core/src/acquisition/models.rs
durvald-core/src/acquisition/service.rs
durvald-core/src/acquisition/providers.rs
durvald-core/src/acquisition/providers/slskd.rs
```

A interface interna principal deveria ser aproximadamente:

```
trait AcquisitionProvider {
    async fn search_release(
        &self,
        query: &ReleaseSearchQuery,
    ) -> Result<Vec<ReleaseSource>, AcquisitionError>;

    async fn enqueue_download(
        &self,
        source: &ReleaseSource,
    ) -> Result<DownloadJob, AcquisitionError>;

    async fn download_status(
        &self,
        job: &DownloadJob,
    ) -> Result<DownloadStatus, AcquisitionError>;

    async fn cancel_download(
        &self,
        job: &DownloadJob,
    ) -> Result<(), AcquisitionError>;
}
```

Não faça `slskd` aparecer fora desse módulo. O restante do Durvald trabalha com `ReleaseSource`, `DownloadJob` e `DownloadStatus`.

Assim, no futuro você poderia substituir:

```
SlskdProvider
```

por:

```
NativeSoulseekProvider
```

sem mudar Swift, SQLite ou o contrato público.

---

# Fase 2 — melhorar a identidade do release antes da busca

Aqui há uma lacuna importante na arquitetura atual.

Hoje `ExternalReleaseGroup` representa um **release-group do MusicBrainz**, não necessariamente uma edição concreta. Ele possui `musicbrainz_id`, título e primeira data, mas não possui tracklist nem um release MBID exato.

Isso é suficiente para mostrar:

> Aphex Twin — Selected Ambient Works 85–92

mas não para verificar se um resultado Soulseek contém exatamente:

```
01 Xtal
02 Tha
03 Pulsewidth
...
13 Actium
```

Portanto, antes da integração Soulseek, eu adicionaria uma chamada MusicBrainz **on-demand**:

```
resolve_release_manifest(
    release_group_mbid: &str
) -> ReleaseAcquisitionManifest
```

Modelo:

```
struct ReleaseAcquisitionManifest {
    release_group_mbid: String,
    preferred_release_mbid: Option<String>,

    artist: String,
    title: String,
    year: Option<i32>,

    discs: Vec<ReleaseDisc>,
}

struct ReleaseDisc {
    number: u32,
    tracks: Vec<ReleaseTrack>,
}

struct ReleaseTrack {
    position: u32,
    title: String,
    duration_ms: Option<u64>,
    recording_mbid: Option<String>,
}
```

Essa consulta **não deve fazer parte do refresh normal da discografia**, porque aumentaria muito o custo MusicBrainz. Ela ocorre somente quando o usuário solicita aquisição de um release.

A implementação entra em:

```
durvald-core/src/enrichment/providers/musicbrainz.rs
```

mas o resultado é consumido pelo `AcquisitionService`.

---

# Fase 3 — cliente slskd

O core já usa `reqwest 0.13.1`, Tokio, Serde e JSON, então não é necessário introduzir uma nova stack HTTP.

O `SlskdClient` teria inicialmente:

```
struct SlskdClient {
    base_url: Url,
    api_key: SecretString,
    http: reqwest::Client,
}
```

Operações mínimas:

```
POST   /api/v0/searches
GET    /api/v0/searches/{id}
GET    /api/v0/searches/{id}/responses

POST   /api/v0/transfers/downloads/{username}

GET    /api/v0/transfers/downloads
GET    /api/v0/transfers/downloads/{username}/{id}

DELETE /api/v0/transfers/downloads/{username}/{id}
```

A API de transfers do slskd já oferece listagem, enqueue, cancelamento e consulta da posição em fila. [GitHub](https://github.com/crmne/slskd-python-client/blob/main/docs/TransfersApi.md)

A busca básica seria:

```
"Artist Album"
```

e depois, se necessário:

```
"Artist Album 1997"
"Artist Album FLAC"
"Artist Album 320"
```

Eu evitaria várias queries paralelas inicialmente. Soulseek distribui cada busca pela rede; múltiplas buscas redundantes aumentariam tráfego e uso de CPU.

---

# Fase 4 — transformar respostas Soulseek em releases candidatos

Resultados do Soulseek são arquivos individuais. O Durvald precisa transformá-los em **pastas/releases candidatos**.

Exemplo:

```
peer: user123

\Music\Autechre\Tri Repetae\
    01 - Dael.flac
    02 - Clipper.flac
    ...
    10 - Rsdio.flac
```

Todos os arquivos que compartilham:

```
username + directory
```

devem ser agrupados em:

```
ReleaseSource {
    source_id,
    username,
    directory,
    files,
    format,
    total_size,
    upload_speed,
    queue_length,
    free_upload_slots,
    match_score,
}
```

Depois calcule um score.

Eu sugiro:

```
40% cobertura da tracklist
20% similaridade dos nomes
15% formato/qualidade
10% número de discos
10% duração/quantidade de faixas
 5% disponibilidade do peer
```

Mais importante que o valor exato é separar:

```
metadata_match_score
availability_score
quality_score
```

e não criar um número opaco impossível de depurar.

---

# Fase 5 — matching MusicBrainz ↔ Soulseek

Esse é o componente mais importante para evitar downloads incorretos.

Normalize:

```
lowercase
Unicode NFKD
remoção de pontuação
collapse whitespace
remoção opcional de "feat."
track number separado do título
```

Compare:

```
número de tracks
título das tracks
ordem
disc number
duração, quando disponível
```

Classificação sugerida:

```
enum ReleaseMatchConfidence {
    Exact,
    Strong,
    Probable,
    Weak,
}
```

Regras:

```
Exact:
track count igual
+ >= 95% dos títulos compatíveis
+ ordem compatível

Strong:
track count ±1
+ >= 85% dos títulos

Probable:
álbum/artista muito fortes
+ >= 70% da tracklist

Weak:
qualquer coisa abaixo disso
```

O Durvald deveria ocultar `Weak` por padrão.

---

# Fase 6 — modelos públicos e UniFFI

Criaria em:

```
durvald-core/src/api/acquisition.rs
```

e exportaria em:

```
durvald-core/src/api.rs
```

DTOs:

```
AcquisitionSettings

ReleaseSearchSession
ReleaseSource
ReleaseSourceFile

AudioQuality
ReleaseMatchConfidence

DownloadJob
DownloadFile
DownloadState
DownloadProgress
```

API pública no `DurvaldCore`:

```
soulseek_status()

search_external_release(
    release_group_mbid
)

release_search_results(
    search_id
)

download_release(
    source_id
)

downloads()

cancel_download(
    download_id
)

retry_download(
    download_id
)
```

A facade atual já usa esse modelo: `DurvaldCore` concentra database, áudio, Last.fm e enrichment. Acquisition deve entrar como mais um serviço:

```
pub struct DurvaldCore {
    ...
    enrichment: EnrichmentService,
    acquisition: AcquisitionService,
}
```

Depois regenere os bindings Swift usando o pipeline UniFFI existente no projeto. A árvore atual já contém tanto o script de geração como os bindings gerados para arm64.

---

# Fase 7 — configuração e credenciais

Adicionar uma seção nova em Settings:

```
Settings
 ├── Library
 ├── Metadata
 ├── Last.fm
 └── Soulseek
```

Arquivos novos:

```
Features/Settings/SoulseekSettingsView.swift
Features/Soulseek/SoulseekViewModel.swift
```

Não armazene API key nem password do Soulseek no SQLite ou `UserDefaults`.

O Durvald já possui `SecureStore`/Keychain no core e `CoreConfig` já recebe `keychain_service`. Reutilize isso para:

```
slskd_api_key
```

Configuração pública:

```
struct AcquisitionSettings {
    enabled: bool,
    slskd_url: String,
    download_directory: String,
}
```

Segredo:

```
Keychain:
com.durvald.player / slskd-api-key
```

Prefira `X-API-Key` em vez de guardar login/senha do painel slskd. A documentação do slskd suporta API keys e recomenda HTTPS quando a conexão não é exclusivamente local. [GitHub](https://github.com/slskd/slskd/blob/master/docs/config.md?plain=1&utm_source=chatgpt.com)

Para:

```
http://127.0.0.1:5030
```

HTTP local é aceitável.

Para qualquer endereço remoto:

```
https://...
```

deveria ser obrigatório por padrão.

---

# Fase 8 — interface no ArtistView

O `ArtistView` já possui uma lista de releases MusicBrainz que não existem localmente, usando `ExternalReleaseCard`.

Eu mudaria o fluxo do card para:

```
ExternalReleaseCard
        │
        ▼
ExternalReleaseView / Sheet
        │
        ├── artwork
        ├── tipo/data
        ├── tracklist
        │
        └── [ Procurar no Soulseek ]
                    │
                    ▼
              SoulseekSearchSheet
```

Estados:

```
Preparando release…
Buscando no Soulseek…
12 fontes encontradas
Nenhuma fonte compatível
Soulseek indisponível
```

Resultado:

```
FLAC · 16/44.1 · 421 MB
13/13 faixas
user123 · slot livre
Correspondência exata

[Baixar]
```

Não mostraria dezenas de arquivos crus para o usuário. A unidade visual deve ser o **release candidato**.

---

# Fase 9 — fila persistente de downloads

Não deixe o estado da fila somente no slskd.

Crie tabelas locais:

```
acquisition_jobs

id
release_group_mbid
source_username
source_directory
provider
remote_search_id
status
created_at
started_at
completed_at
total_files
completed_files
total_bytes
downloaded_bytes
error_code
```

e:

```
acquisition_files

job_id
remote_filename
local_filename
size
status
```

Estados:

```
searching
awaiting_selection
queued
downloading
completed
failed
cancelled
importing
imported
```

Com isso o Durvald consegue reconstruir a UI depois de reiniciar mesmo que o slskd tenha continuado trabalhando.

A experiência adquirida no próprio projeto com fila persistente de capas é diretamente aplicável: cursor/estado/tentativas/reinício já fazem parte da arquitetura atual.

---

# Fase 10 — diretório de download e importação

Eu evitaria baixar diretamente para a biblioteca musical definitiva.

Use:

```
~/Music/Durvald Downloads/
```

ou uma pasta escolhida pelo usuário.

Fluxo:

```
slskd
  ↓
Durvald Downloads/incomplete
  ↓
download complete
  ↓
validação
  ↓
Durvald Downloads/Artist/Album/
  ↓
scanner Durvald
  ↓
biblioteca local
```

Depois de concluído:

1. confirmar que todos os arquivos existem;
2. rejeitar extensões não autorizadas;
3. extrair metadata via `lofty`;
4. verificar que os arquivos são áudio válidos;
5. comparar novamente com o manifest MusicBrainz;
6. mover atomicamente;
7. disparar scan somente da pasta importada;
8. vincular o release local ao `ExternalReleaseGroup`.

O Durvald já suporta MP3, WAV, FLAC e Ogg Vorbis no player atual. Portanto, no MVP eu aceitaria somente:

```
.flac
.mp3
.ogg
.oga
.wav
```

Arquivos adicionais encontrados em uma pasta Soulseek:

```
.exe
.sh
.command
.app
.dmg
.zip
```

não devem ser movidos nem executados.

---

# Fase 11 — atualização do vínculo MusicBrainz/local

Depois do scan, o release adquirido deveria deixar de aparecer como “online only”.

Isso já está previsto no modelo:

```
ExternalReleaseGroup {
    ...
    local_release_id: Option<i64>
}
```

O importador deve tentar vincular:

```
release_group_mbid
        ↓
tracks importados
        ↓
release local
        ↓
local_release_id
```

Isso transforma a aquisição em um ciclo fechado:

```
descobrir → pesquisar → baixar → importar → tornar local
```

---

# Fase 12 — gerenciamento de downloads

Eu adicionaria uma área global nova:

```
LibraryDestination.downloads
```

Hoje os destinos são Home, Songs, Albums, Artists, Playlists, History e Search.

Novo destino:

```
case downloads
```

com:

```
Downloads

Downloading
───────────
Boards of Canada — Geogaddi
6 / 23 tracks · 312 MB / 781 MB
user_xyz · 2.4 MB/s

Queued
──────
...

Completed
─────────
...
```

O `DurvaldCoreStore` deveria ganhar apenas estado frontend:

```
private(set) var downloads: [DownloadJob] = []
```

e métodos:

```
func searchSoulseek(...)
func downloadRelease(...)
func cancelDownload(...)
func retryDownload(...)
func refreshDownloads()
```

O store já atua exatamente como essa ponte Swift/UniFFI para biblioteca e enrichment.

---

# Fase 13 — polling

No MVP:

```
search:
poll 300–500 ms
até completar ou 10–15 s

downloads ativos:
poll 1 s

downloads em fila:
poll 3–5 s

nenhum download:
sem polling
```

Não replique o polling de playback de 250 ms. O `DurvaldCoreStore` atualmente já tem um loop desse tipo para áudio. Para Soulseek, polling agressivo só aumentaria o consumo de CPU, justamente algo que já virou preocupação no Durvald.

Mais tarde, pode-se substituir polling por eventos/webhooks do slskd; ele expõe eventos como `DownloadFileComplete`. [GitHub](https://github.com/slskd/slskd/blob/master/docs/config.md?utm_source=chatgpt.com)

---

# Fase 14 — testes

No Rust:

```
acquisition::matching
```

Testes com:

```
13/13 tracks
12/13
bonus track
2 CDs
nomes com caracteres especiais
"feat."
disc/track prefix
FLAC + artwork + cue
resultados de múltiplos peers
duplicados
```

Para `SlskdClient`, mock HTTP para:

```
search OK
search timeout
401/403
server unavailable
empty response
malformed JSON
cancel
queue
download failure
restart
```

Teste especialmente:

```
download concluído no slskd enquanto Durvald estava fechado
```

e:

```
arquivo terminado mas ainda não importado
```

No Swift:

```
SoulseekSearchSheetTests
DownloadsViewTests
```

e UI tests para:

```
ArtistView
→ external release
→ Soulseek
→ results
→ download
```

---

# Ordem de implementação que eu adotaria

1. **Criar `acquisition/` e os DTOs**, sem Soulseek ainda.
2. Implementar `SlskdClient` e um `connection_test()`.
3. Criar Settings para URL + API key.
4. Estender MusicBrainz com `ReleaseAcquisitionManifest`.
5. Implementar busca simples `Artist + Album`.
6. Agrupar resultados por `peer + directory`.
7. Implementar matching de tracklist.
8. Expor resultados via UniFFI.
9. Criar `SoulseekSearchSheet`.
10. Implementar enqueue de downloads.
11. Criar `acquisition_jobs` persistente.
12. Criar tela Downloads.
13. Implementar import automático + scan.
14. Vincular o novo release local ao release-group MusicBrainz.
15. Adicionar retry/cancel/restart recovery.
16. Só depois considerar wishlist, download automático ou protocolo Soulseek nativo.

## Decisão importante: slskd externo primeiro

Eu começaria exigindo que o usuário tenha uma instância slskd instalada/configurada e faria o Durvald apenas conectar-se a ela.

O slskd já fornece exatamente as operações necessárias e suporta binários no macOS. [GitHub](https://github.com/slskd/slskd?utm_source=chatgpt.com) Além disso, ele é **AGPL-3.0**, enquanto o `durvald-core` atualmente declara MIT; empacotar ou incorporar slskd dentro do aplicativo merece uma análise específica de distribuição/licenciamento antes de fazê-lo. [GitHub](https://github.com/slskd/slskd)

Portanto, para o MVP:

```
Durvald ──REST──> slskd ──Soulseek──> peers
```

e não:

```
Durvald ──Soulseek protocol──> peers
```

Isso reduz drasticamente o tamanho e o risco da primeira implementação.

### Critério de conclusão do MVP

O MVP pode ser considerado fechado quando este caminho funcionar de ponta a ponta:

```
ArtistView
  ↓
release MusicBrainz sem cópia local
  ↓
"Procurar no Soulseek"
  ↓
tracklist MusicBrainz
  ↓
busca slskd
  ↓
3–10 releases candidatos ranqueados
  ↓
usuário escolhe um
  ↓
download com progresso/cancelamento
  ↓
validação
  ↓
scan Durvald
  ↓
release aparece como álbum local
  ↓
ExternalReleaseGroup.local_release_id != nil
```

Esse desenho preserva uma propriedade importante do Durvald: **MusicBrainz continua sendo a identidade canônica; Soulseek nunca decide qual release existe — apenas fornece arquivos candidatos para um release previamente identificado.**