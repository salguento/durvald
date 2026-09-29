# Diagnóstico de Consumo de Memória RAM e Oportunidades de Otimização

**Data de referência:** 25 de setembro de 2026
**Problema relatado:** Após a remodelação arquitetural do core, o consumo de memória RAM do aplicativo macOS saltou de ~70 MB para ~700 MB em estado aparentemente inativo (idle).

---

## 1. Causa Raiz: O Falso "Estado Inativo"

A análise de execução e chamadas entre o cliente macOS (`durvald-macos`) e o core Rust (`durvald-core`) revelou que o aplicativo **não estava verdadeiramente em repouso**.

Ao abrir o aplicativo, o método `openCoreIfNeeded()` em [`DurvaldCoreStore.swift`](file:///Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift#L111-L113) dispara incondicionalmente uma tarefa de sincronização global em segundo plano:

```swift
startPlaybackPolling()
Task { [weak self] in
    await self?.updateLibraryMetadata(refreshRemote: true)
}
```

O método `updateLibraryMetadata` itera por **todos os artistas da biblioteca local**:
1. Para cada artista, invoca `core.refreshArtist(...)` solicitando simultaneamente:
   * `.profile` (biografia via Wikipedia / Wikidata);
   * `.portrait` (retratos via Wikimedia / Last.fm);
   * `.discography` (catálogo remoto paginado via MusicBrainz);
   * `.popularTracks` (faixas populares via Last.fm);
   * `.similarArtists` (artistas similares).
2. Apenas a seção de discografia pode requisitar até **10 páginas de 100 itens (até 1.000 release groups)** por artista.
3. Capas externas são baixadas e validadas pelo Cover Art Archive.
4. Na camada Swift, o dicionário `refreshedByID` vai acumulando centenas/milhares de instâncias de `Release` na memória principal para posterior substituição no array da view.

Portanto, em bibliotecas com dezenas ou centenas de artistas, o aplicativo entra em um loop pesado e contínuo de I/O de rede, parsing JSON, decodificação de imagens e transações concorrentes no SQLite.

---

## 2. Fontes de Retenção Excessiva e Fugas de Memória

### A. Camada de Interface Swift / macOS

#### 1. Retenção de Bitmaps Descompactados no `ArtworkRepository`
* **Local:** [`ArtworkRepository.swift`](file:///Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/ArtworkRepository.swift)
* **Mecanismo:** O repositório utiliza `NSCache` com `totalCostLimit = 64 MB` e `countLimit = 600`.
* **Comportamento no macOS:** Diferente do iOS, o `NSCache` no macOS não purga dados de forma determinística ou preventiva ao atingir o `totalCostLimit`. Ele aguarda notificações de pressão de memória do sistema operacional (`OSMemoryNotification`), que raramente ocorrem em sistemas desktop com memória virtual/swap abundante.
* **Impacto em Bytes:** O método `pixelSize` escala thumbnails até **2048 px** (usado por exemplo na imagem de topo do `ArtistView`). Um bitmap descompactado de 2048×2048 a 32 bits por pixel (RGBA) ocupa **~16,7 MB de memória física**. Apenas 20 a 30 imagens decodificadas retidas em cache já representam de **300 MB a 500 MB** de memória residente no processo.

#### 2. Carga Total da Biblioteca em `AlbumsView`
* **Local:** [`AlbumsView.swift`](file:///Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumsView.swift#L77-L80)
* **Mecanismo:** Ao exibir a tela de álbuns no modo padrão de ordenação `.recent`, a view executa:
  ```swift
  orderingTracks = (try? await store.core?.tracks()) ?? store.tracks
  ```
* **Impacto:** Invoca `core.tracks()` sem paginação (`SqliteCatalogTrackQuery.all()`). Toda a tabela de faixas do SQLite é mapeada em structs Rust, serializada através do bridge UniFFI e inflada em instâncias Swift no array `@State orderingTracks`.

---

### B. Camada Rust / Core (`durvald-core`)

#### 1. Arquivo SQLite WAL Inflado e Memória Mapeada (`mmap`)
* **Local:** [`composition.rs`](file:///Users/salguento/Developer/durvald/durvald-core/src/composition.rs#L109-L117)
* **Mecanismo:** O pool de conexões SQLite (`r2d2`) inicializa o banco com `PRAGMA journal_mode = WAL;`.
* **Impacto:** Durante as milhares de inserções pontuais geradas pela sincronização de metadados, o arquivo `-wal` cresce sem checkpoints periódicos forçados. O subsistema de arquivos do macOS e o SQLite utilizam memory mapping (`mmap`) para o banco e para o WAL. Como conexões de leitura simultâneas no pool podem manter snapshots abertos, o SQLite não consegue truncar o WAL, elevando a memória residente mapeada no processo.

#### 2. Loop de Polling de 50ms em `PlaybackApplication`
* **Local:** [`application/playback.rs`](file:///Users/salguento/Developer/durvald/durvald-core/src/application/playback.rs#L100-L114)
* **Mecanismo:**
  ```rust
  tokio::spawn(async move {
      loop {
          tokio::time::sleep(std::time::Duration::from_millis(50)).await;
          ...
          application.process_automatic_transition().await;
      }
  });
  ```
* **Impacto:** Mesmo sem áudio em reprodução e sem faixas agendadas, a cada 50ms o loop acorda, adquire o lock `playback_transition` e o mutex de `audio_player`. Essa frequência impede que o thread pool do Tokio e o alocador do sistema entrem em repouso profundo.

#### 3. Fragmentação nas Arenas de Alocação (`malloc` do macOS)
* O alto volume de tarefas concorrentes `tokio::task::spawn_blocking` e `reqwest` alocando e desalocando temporariamente buffers de strings e JSON faz com que as arenas de memória do `malloc` expandam. No macOS, as páginas alocadas nas arenas raramente são devolvidas ao kernel imediatamente se o processo continuar executando tarefas de background.

---

## 3. Matriz de Soluções Recomendadas

### Ações Imediatas (Frontend & Orquestração)

| Ação | Impacto Esperado | Complexidade |
|---|---|---|
| **1. Desativar sincronização automática de metadados no startup** | **Redução imediata de ~300–400 MB** de pico | Muito baixa |
| Alterar [`DurvaldCoreStore.swift`](file:///Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift) para não chamar `updateLibraryMetadata(refreshRemote: true)` incondicionalmente no `openCoreIfNeeded()`. O enriquecimento deve ocorrer somente sob demanda ao abrir uma tela específica de artista. | Evita fan-out de rede e parsing em segundo plano. | |
| **2. Eliminar o carregamento de todas as faixas em `AlbumsView`** | **Redução de ~50–100 MB** | Baixa |
| Substituir `core.tracks()` por uma query SQLite com `ORDER BY` ou agregação no backend, mantendo a paginação. | Evita serialização FFI massiva para ordenação em memória no Swift. | |
| **3. Limitar resolução e aplicar política LRU estrita em `ArtworkRepository`** | **Redução de ~150–250 MB** | Média |
| Limitar o `pixelSize` de cards e células para no máximo 512 px. Substituir o `NSCache` por uma estrutura LRU customizada com limite estrito de bytes ou forçar limpeza manual periódica. | Evita bitmaps 2048×2048 não purgados na memória residente. | |

### Ações Estruturais no Core (`durvald-core`)

| Ação | Impacto Esperado | Complexidade |
|---|---|---|
| **4. Pausar ou espaçar o loop de transição de playback quando inativo** | Redução de churn de CPU e estabilização de heap | Baixa |
| Em [`playback.rs`](file:///Users/salguento/Developer/durvald/durvald-core/src/application/playback.rs), verificar se o player está parado/vazio antes de esperar 50ms; quando ocioso, usar intervalos de 2 a 5 segundos ou aguardar notificação de evento de play. | Permite consolidação de memória no runtime Tokio. | |
| **5. Executar `wal_checkpoint` explícito após lotes de escrita** | Redução do tamanho em disco e da memória mapeada (`mmap`) | Baixa |
| Executar `PRAGMA wal_checkpoint(PASSIVE)` ou `TRUNCATE` no final de rotinas de scan e sincronização de metadados. | Impede que o arquivo WAL cresça indefinidamente. | |
| **6. Depreciar endpoints `.all()` sem limite de paginação** | Prevenção de regressões de memória | Média |
| Remover métodos que retornam coleções completas em memória (`tracks()`, `releases()`), tornando o uso de `TrackPage` e `ReleasePage` obrigatório. | Limita a footprint de memória a buffers previsíveis. | |
