# F0.06 — Matriz de cobertura da baseline

Esta matriz une os três artefatos anteriores:

```text
caso de uso (F0.03)
+
criticidade (F0.04)
+
invariante (F0.05)
+
cenário e tipo de teste
```

Ela é a **checklist operacional da Fase 0**. A arquitetura pode mudar depois, mas cada linha precisa continuar tendo uma evidência de teste equivalente enquanto o comportamento permanecer no contrato.

## Snapshot analisado

A matriz parte do estado de `main` após a F0.05:

```text
eb6c951ae60d98a76f29e1ac7b33673fecae2dee
```

## Regra para marcar uma linha

A existência de um teste parecido **não marca automaticamente** uma linha como concluída.

Uma linha passa de `☐` para `☑` somente quando:

1. existe teste determinístico que cobre o cenário e os invariantes indicados;
2. o teste está explicitamente associado ao ID do caso de uso, por nome, comentário ou esta matriz;
3. ele passa no gate apropriado;
4. o teste não congela detalhes de implementação excluídos pela F0.05;
5. para P0, a evidência roda no CI/baseline obrigatória.

Um único teste pode satisfazer várias linhas. Não é objetivo criar 180 funções de teste independentes.

## Tipos de teste

| Tipo | Uso |
| --- | --- |
| **unidade** | regra pura, policy, parser, validation ou estado interno cujo contrato é melhor isolado |
| **integração** | `DurvaldCore` + DB/filesystem/audio mock ou múltiplos componentes reais |
| **integração com double HTTP** | provider/Last.fm sem dependência de rede real |
| **integração de adapter/plataforma** | comportamento de secure storage ou integração específica do SO |
| **contrato** | forma/semântica da API pública e categorias de erro |
| **contrato de compilação/FFI** | consumidores continuam compilando e bindings continuam geráveis |
| **fluxo cliente** | comportamento composto que hoje é orquestrado no frontend |

## Gates transversais

Estes IDs são **gates de cobertura**, não novos casos de uso da F0.03.

| Check | ID | P | Invariante | Cenário | Tipo |
| --- | --- | --- | --- | --- | --- |
| ☐ | API-001 | P0 | INV-ERR-001–INV-ERR-003 | CoreError continua expondo as seis variantes públicas e testes fazem match por variante | contrato |
| ☐ | API-002 | P0 | INV-CORE-004 | imports/reexports públicos protegidos na F0.02 continuam compilando para consumidores Rust | contrato de compilação |
| ☑ CI existente | FFI-001 | P0 | INV-ERR-001 | `./durvald-core/scripts/generate-swift-bindings.sh` gera bindings sem drift inválido | contrato FFI |
| ☑ CI existente | FFI-002 | P0 | — | cliente macOS compila contra bindings gerados | contrato FFI |
| ☐ | FFI-003 | P0 | INV-CORE-001 | factory Swift/UniFFI `open(config)` obtém handle utilizável | contrato + integração |
| ☑ CI existente | RUST-001 | P0 | INV-CORE-004 | cliente GTK compila contra API Rust pública | contrato de compilação |

## Matriz por caso de uso

### Lifecycle

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | CORE-001 | P0 | INV-CORE-001, INV-CORE-004 | abrir instalação nova e obter core utilizável | integração |
| ☐ | CORE-002 | P0 | INV-CORE-001 | open cria app_support_dir e covers_dir ausentes | integração |
| ☐ | CORE-003 | P0 | INV-CORE-001 | abrir banco e exercer leitura/escrita com configuração SQLite válida | integração |
| ☐ | CORE-004 | P0 | INV-CORE-001, INV-CORE-002 | abrir DB novo cria schema mínimo utilizável | integração |
| ☐ | CORE-005 | P0 | INV-CORE-002 | reabrir fixture de schema anterior e aplicar migrations sem perda | integração |
| ☐ | CORE-006 | P0 | INV-CORE-001 | DB novo recebe settings default legíveis | integração |
| ☐ | CORE-007 | P0 | INV-CORE-001 | DB novo recebe sessão default legível | integração |
| ☐ | CORE-008 | P0 | INV-CORE-003 | reabrir core restaura track, posição, volume, queue, shuffle e repeat | integração |
| ☐ | CORE-009 | P1 | INV-SET-004 | reabrir core reaplica crossfade e normalização persistidos | integração |
| ☐ | CORE-010 | P0 | INV-SEC-001 | open inicializa secure storage em diretório temporário válido | integração |
| ☐ | CORE-011 | P0 | — | open inicializa Last.fm client sem exigir sessão configurada | integração |
| ☐ | CORE-012 | P0 | INV-ENR-001 | open inicializa enrichment sem disparar rede | integração |
| ☐ | CORE-013 | P0 | INV-PLAY-009 | completion/avanço automático funciona sem polling da UI | integração |
| ☐ | CORE-014 | P0 | INV-PLAY-007 | transição automática persiste sessão coerente | integração |

### Library

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | LIB-001 | P0 | INV-SCAN-003–INV-SCAN-007 | scan simples indexa fixture válida e finaliza coerentemente | integração |
| ☐ | LIB-002 | P0 | INV-SCAN-005 | scan_configured_library percorre todos os roots configurados | integração |
| ☐ | LIB-003 | P1 | INV-SCAN-002–INV-SCAN-004 | cancelar scan ativo interrompe com segurança; sem scan retorna NotFound | integração |
| ☐ | LIB-004 | P1 | — | progresso percorre fases observáveis e termina em Complete | integração |
| ☐ | LIB-005 | P1 | INV-SCAN-001 | segundo scan concorrente retorna InvalidInput | integração |
| ☐ | LIB-006 | P0 | INV-SCAN-009 | adicionar diretório válido persiste; arquivo/nonexistent retorna InvalidInput | integração |
| ☐ | LIB-007 | P0 | — | listar paths retorna conjunto persistido após reopen | integração |
| ☐ | LIB-008 | P1 | — | remover path existente funciona; ausente retorna NotFound | integração |
| ☐ | LIB-009 | P0 | — | listar tracks após scan retorna DTOs esperados | integração |
| ☐ | LIB-010 | P0 | INV-LIB-002, INV-LIB-003 | paginação de tracks limita 200 e calcula next_offset corretamente | integração |
| ☐ | LIB-011 | P0 | INV-LIB-001 | track válido é encontrado; ID negativo InvalidInput; ausente NotFound | integração |
| ☐ | LIB-012 | P1 | — | listar releases derivados da biblioteca | integração |
| ☐ | LIB-013 | P1 | INV-LIB-002, INV-LIB-003 | paginação de releases é bounded e estável | integração |
| ☐ | LIB-014 | P1 | INV-LIB-001 | release por ID: válido, negativo e ausente | integração |
| ☐ | LIB-015 | P1 | — | listar tracks de release preserva associação correta | integração |
| ☐ | LIB-016 | P1 | — | listar artistas indexados | integração |
| ☐ | LIB-017 | P1 | INV-LIB-001 | artist por ID: válido, negativo e ausente | integração |
| ☐ | LIB-018 | P1 | — | listar releases do artista correto | integração |
| ☐ | LIB-019 | P1 | — | listar tracks do artista correto | integração |
| ☐ | LIB-020 | P1 | INV-LIB-004 | busca cobre tracks/releases/artists/playlists; whitespace é InvalidInput | integração |
| ☐ | LIB-021 | P1 | INV-SCAN-005 | scan completo remove registro de arquivo realmente removido | integração |
| ☐ | LIB-022 | P0 | INV-SCAN-003, INV-SCAN-004 | scan cancelado/parcial preserva registro de arquivo ausente | integração |
| ☐ | LIB-023 | P0 | INV-SCAN-006, INV-SCAN-007 | walker ignora symlinks e somente aceita formatos suportados | integração |
| ☐ | LIB-024 | P1 | INV-SCAN-008, INV-META-002, INV-META-009 | rescan atualiza arquivo alterado sem apagar override/edit válida | integração |
| ☐ | LIB-025 | P1 | — | favoritar/desfavoritar track persiste | integração |
| ☐ | LIB-026 | P1 | — | favoritar/desfavoritar release persiste | integração |
| ☐ | LIB-027 | P2 | — | hidden de track persiste e reverte | integração |
| ☐ | LIB-028 | P2 | — | hidden de release persiste e reverte | integração |
| ☐ | LIB-029 | P2 | — | suggest-less de track persiste e reverte | integração |
| ☐ | LIB-030 | P2 | — | suggest-less de release persiste e reverte | integração |
| ☐ | LIB-031 | P2 | INV-LIB-005 | rating de track aceita 0–5/None e rejeita >5 | integração |
| ☐ | LIB-032 | P2 | INV-LIB-005 | rating de release aceita 0–5/None e rejeita >5 | integração |

### Playback

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | PLAY-001 | P0 | INV-PLAY-001, INV-LIB-001 | play carrega track válida sem duplicá-la na queue; erros tipados | integração |
| ☐ | PLAY-002 | P0 | INV-PLAY-002 | snapshot reflete track ativa, flags, volume, queue, shuffle e repeat | integração |
| ☐ | PLAY-003 | P0 | INV-PLAY-007 | pause altera estado e persiste sessão | integração |
| ☐ | PLAY-004 | P0 | INV-CORE-003, INV-PLAY-007 | resume normal e resume de sessão restaurada retomam posição correta | integração |
| ☐ | PLAY-005 | P0 | INV-PLAY-007 | stop interrompe playback, limpa tracking ativo e persiste | integração |
| ☐ | PLAY-006 | P0 | INV-PLAY-007 | seek altera posição e persiste progresso | integração |
| ☐ | PLAY-007 | P0 | INV-PLAY-008 | volume finite é clamp/persistido; NaN/inf retorna InvalidInput | integração |
| ☐ | PLAY-008 | P0 | INV-PLAY-007, INV-PLAY-010 | shuffle altera política, invalida sucessor stale e persiste | integração |
| ☐ | PLAY-009 | P0 | INV-PLAY-007, INV-PLAY-010 | repeat None/One/All preserva semântica da queue e persiste | integração |
| ☐ | PLAY-010 | P0 | INV-PLAY-005 | enqueue com/sem track ativa respeita semântica atual | integração |
| ☐ | PLAY-011 | P0 | INV-PLAY-002 | queue exposta possui posições contíguas e coerentes | integração |
| ☐ | PLAY-012 | P0 | INV-PLAY-006, INV-PLAY-010 | next avança; sem sucessor retorna NotFound sem corromper estado | integração |
| ☐ | PLAY-013 | P0 | INV-PLAY-006, INV-HIST-002 | previous usa navigation history e não playback history | integração |
| ☐ | PLAY-014 | P0 | INV-PLAY-003 | play_queue_item protege posição ativa e inicia item futuro correto | integração |
| ☐ | PLAY-015 | P0 | INV-PLAY-003, INV-PLAY-010 | remove item futuro; não remove track ativa | integração |
| ☐ | PLAY-016 | P0 | INV-PLAY-003, INV-PLAY-010 | move item futuro; não move track ativa | integração |
| ☐ | PLAY-017 | P0 | INV-PLAY-004 | clear_queue preserva track ativa e remove sucessores | integração |
| ☐ | PLAY-018 | P0 | INV-CORE-003 | restart + primeiro resume restaura track/posição persistidas | integração |
| ☐ | PLAY-019 | P0 | INV-PLAY-007 | cada comando mutante relevante atualiza last_session | integração |
| ☐ | PLAY-020 | P0 | INV-PLAY-007 | seek persiste progress_seconds exato dentro da semântica atual | integração |
| ☐ | PLAY-021 | P0 | INV-PLAY-007, INV-PLAY-008 | volume persistido reabre normalizado em 0–1 | integração |
| ☐ | PLAY-022 | P1 | INV-PLAY-010, INV-PLAY-011 | preloader agenda somente sucessor válido e cancela plano stale | unidade |
| ☐ | PLAY-023 | P0 | INV-PLAY-009 | track completa avança automaticamente sem chamadas playback() | integração |
| ☐ | PLAY-024 | P1 | INV-PLAY-010–INV-PLAY-012 | gapless ativa sucessor correto e alterações de queue cancelam antigo | unidade |
| ☐ | PLAY-025 | P2 | INV-PLAY-012 | mudança manual usa política de crossfade configurada | unidade |
| ☐ | PLAY-026 | P2 | INV-PLAY-013 | ReplayGain válido aplica ajuste; inválido/ausente não altera ganho | unidade |
| ☐ | PLAY-027 | P1 | INV-HIST-002 | navigation history conserva semântica de Previous independentemente do DB history | unidade |

### History

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | HIST-001 | P1 | INV-HIST-001, INV-HIST-002 | completion cria registro persistente e incrementa estado esperado | integração |
| ☐ | HIST-002 | P2 | INV-HIST-001 | Repeat One cria uma nova entrada a cada completion | integração |
| ☐ | HIST-003 | P1 | — | listar histórico retorna eventos persistidos em ordem atual | integração |
| ☐ | HIST-004 | P1 | INV-LIB-002, INV-LIB-003 | paginação de histórico é bounded e calcula next_offset | integração |
| ☐ | HIST-005 | P1 | — | remover evento existente funciona; ID inválido/ausente tipado | integração |
| ☐ | HIST-006 | P1 | — | clear history remove todos e retorna quantidade coerente | integração |
| ☐ | HIST-007 | P2 | INV-HIST-002 | operações de Previous não criam/removem playback-history indevidamente | integração |

### Playlists

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | PLST-001 | P1 | — | listar playlists retorna track_count e atributos persistidos | integração |
| ☐ | PLST-002 | P1 | INV-PLST-001 | create válido; nome vazio/whitespace retorna InvalidInput | integração |
| ☐ | PLST-003 | P1 | — | lookup de playlist existente/ausente/ID inválido | integração |
| ☐ | PLST-004 | P1 | INV-PLST-001 | update rename/description/artwork preserva entidade; nome vazio rejeitado | integração |
| ☐ | PLST-005 | P1 | INV-PLST-003 | delete remove playlist e associações de tracks | integração |
| ☐ | PLST-006 | P1 | INV-PLST-002 | playlist_tracks retorna ordem persistida | integração |
| ☐ | PLST-007 | P1 | INV-PLST-002 | adicionar track na posição correta | integração |
| ☐ | PLST-008 | P1 | INV-PLST-002 | remover entrada específica preserva demais posições coerentes | integração |
| ☐ | PLST-009 | P1 | INV-PLST-002 | move reordena de forma persistente | integração |
| ☐ | PLST-010 | P2 | — | favorito de playlist persiste e reverte | integração |
| ☐ | PLST-011 | P2 | — | suggest-less de playlist persiste e reverte | integração |
| ☐ | PLST-012 | P2 | INV-ART-001 | artwork blob da playlist é retornado/ausente conforme persistência | integração |
| ☐ | PLST-013 | P1 | INV-PLST-004 | fluxo macOS play playlist reproduz seleção a partir da posição | fluxo cliente |
| ☐ | PLST-014 | P1 | INV-PLST-004 | play playlist shuffle preserva conjunto selecionado | fluxo cliente |
| ☐ | PLST-015 | P1 | — | enqueue playlist adiciona todas as tracks na ordem esperada | fluxo cliente |
| ☐ | PLST-016 | P1 | — | play-next reposiciona tracks da playlist após item ativo | fluxo cliente |

### Metadata e artwork

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | META-001 | P1 | — | extract_metadata lê fixture suportada e retorna DTO coerente | integração |
| ☐ | META-002 | P1 | — | track_info retorna cache/editable metadata e can_undo coerentes | integração |
| ☐ | META-003 | P2 | — | biblioteca antiga sem cache faz backfill sem apagar tags existentes | integração |
| ☐ | META-004 | P1 | INV-META-001, INV-META-002, INV-META-004 | database-only edit não toca arquivo, persiste e sobrevive a rescan | integração |
| ☐ | META-005 | P1 | INV-META-001, INV-META-003, INV-META-005, INV-META-006 | file edit altera tags/index atomicamente e preserva campos não editados | integração |
| ☐ | META-006 | P1 | INV-META-001, INV-META-004 | inputs inválidos não criam journal nem mutação | unidade |
| ☐ | META-007 | P1 | INV-META-003 | edição preserva artwork e tags fora do conjunto gerenciado | integração |
| ☐ | META-008 | P1 | INV-META-004–INV-META-006 | journal registra applied/failed coerentemente | integração |
| ☐ | META-009 | P1 | INV-META-007, INV-META-008 | undo restaura bytes/índice e bloqueia arquivo alterado externamente | integração |
| ☐ | META-010 | P2 | INV-ART-005, INV-ART-006 | scan extrai cover válido sem tornar cover inválida fatal à track | unidade |
| ☐ | META-011 | P2 | INV-ART-005–INV-ART-007 | limites/formato/dimensões rejeitam artwork inseguro | unidade |
| ☐ | META-012 | P2 | INV-ART-001, INV-ART-006 | artwork válida é persistida somente na área gerenciada | integração |
| ☐ | META-013 | P1 | INV-ART-001–INV-ART-004 | artwork_bytes lê asset interno e não lê path arbitrário | integração |
| ☐ | META-014 | P1 | INV-ART-002 | path existente fora de covers_dir retorna InvalidInput | integração |
| ☐ | META-015 | P1 | INV-ART-003 | symlink dentro apontando para fora retorna InvalidInput | integração |
| ☐ | META-016 | P2 | INV-ART-008 | falha de thumbnail não invalida artwork full-size | unidade |

### Enrichment

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | ENR-001 | P1 | INV-ENR-001, INV-ENR-003 | ler settings não faz rede e retorna estado persistido | integração |
| ☐ | ENR-002 | P1 | INV-ENR-003, INV-ENR-004 | configurar enabled/offline/language normaliza e persiste | integração |
| ☐ | ENR-003 | P1 | INV-ENR-005 | artist_identity retorna estado/generation persistidos | integração |
| ☐ | ENR-004 | P1 | INV-ENR-005 | resolver candidatos usa double provider e produz lookup status coerente | integração com double HTTP |
| ☐ | ENR-005 | P1 | INV-ENR-005 | confirmar MBID válido atualiza identidade/generation | integração |
| ☐ | ENR-006 | P1 | INV-ENR-005 | clear identity volta ao estado não confirmado sem corromper artista local | integração |
| ☐ | ENR-007 | P1 | INV-ENR-002 | artist_details lê SQLite sem rede, inclusive stale/offline | integração |
| ☐ | ENR-008 | P1 | INV-ENR-002 | discography page lê snapshot local e pagina corretamente | integração |
| ☐ | ENR-009 | P1 | INV-ENR-002 | popular tracks lê snapshot local e marca stale coerentemente | integração |
| ☐ | ENR-010 | P1 | INV-ENR-006 | external release details usa fresh cache; fallback stale/erro segue política | integração com double HTTP |
| ☐ | ENR-011 | P1 | INV-ENR-003–INV-ENR-007 | refresh valida input, policy, identity e single-flight | integração com double HTTP |
| ☐ | ENR-012 | P1 | INV-ENR-003, INV-ENR-005 | refresh Profile produz resultado normalizado | integração com double HTTP |
| ☐ | ENR-013 | P1 | INV-ENR-003, INV-ART-007 | refresh Portrait valida/materializa asset permitido | integração com double HTTP |
| ☐ | ENR-014 | P1 | INV-ENR-003 | refresh Discography persiste catálogo coerente | integração com double HTTP |
| ☐ | ENR-015 | P1 | INV-ART-007 | refresh Covers valida e persiste artwork gerenciado | integração com double HTTP |
| ☐ | ENR-016 | P1 | INV-ENR-003 | refresh PopularTracks persiste ranking normalizado | integração com double HTTP |
| ☐ | ENR-017 | P1 | INV-ENR-003 | refresh SimilarArtists persiste resultado normalizado | integração com double HTTP |
| ☐ | ENR-018 | P1 | INV-ENR-002 | sync release metadata usa somente cache local e não faz rede | integração |
| ☐ | ENR-019 | P1 | INV-ENR-009 | override editorial prevalece no campo correspondente | integração |
| ☐ | ENR-020 | P1 | INV-ENR-009 | clear override volta ao valor derivado do snapshot | integração |
| ☐ | ENR-021 | P1 | INV-ENR-008 | clear provider remove somente dados do provider escolhido | integração |
| ☐ | ENR-022 | P2 | INV-ENR-006 | fresh TTL satisfaz request sem rede | unidade |
| ☐ | ENR-023 | P2 | INV-ENR-006 | stale continua legível nos fluxos offline/fallback permitidos | integração |
| ☐ | ENR-024 | P1 | INV-ENR-003 | enabled=false impede chamada ao transport | integração com double HTTP |
| ☐ | ENR-025 | P1 | INV-ENR-003 | offline=true impede chamada ao transport | integração com double HTTP |
| ☐ | ENR-026 | P2 | INV-ENR-006 | NotFound cria cache negativo com política vigente | unidade |
| ☐ | ENR-027 | P2 | INV-ENR-006 | falha transitória é classificada/retida pelo TTL vigente | unidade |
| ☐ | ENR-028 | P2 | INV-ENR-006 | rate limit/retry-after produz status e retry metadata coerentes | unidade |
| ☐ | ENR-029 | P2 | INV-ENR-007 | requests equivalentes concorrentes produzem uma única execução remota | integração com double HTTP |
| ☐ | ENR-030 | P2 | — | resultado de refresh contém status/diagnóstico por seção correto | integração com double HTTP |
| ☐ | ENR-031 | P1 | INV-ART-007 | artwork remoto inválido não entra no cache; válido é normalizado | integração com double HTTP |
| ☐ | ENR-032 | P2 | INV-ENR-009 | DTO normalizado preserva attribution sem expor payload de provider | contrato |

### Last.fm

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | LFM-001 | P1 | — | status desconectado/conectado reflete session key e username | integração |
| ☐ | LFM-002 | P1 | INV-LFM-001, INV-LFM-002 | configure valida credenciais e invalida sessão antiga quando mudam | integração |
| ☐ | LFM-003 | P1 | INV-LFM-001, INV-SEC-001 | api_secret/session_key ficam no secret store, não no JSON comum | integração |
| ☐ | LFM-004 | P1 | — | auth token request é assinado e URL de aprovação é formada | integração com double HTTP |
| ☐ | LFM-005 | P1 | INV-LFM-002 | poll session persiste username/session key após resposta válida | integração com double HTTP |
| ☐ | LFM-006 | P1 | INV-LFM-003 | play/start envia Now Playing normalizado quando conectado | integração com double HTTP |
| ☐ | LFM-007 | P1 | INV-LFM-004 | pause acumula tempo ativo e encerra período corrente | unidade |
| ☐ | LFM-008 | P1 | INV-LFM-004 | resume inicia novo período sem contar pausa | unidade |
| ☐ | LFM-009 | P1 | INV-LFM-005 | threshold <30s, 50% e teto 240s | unidade |
| ☐ | LFM-010 | P1 | INV-LFM-003, INV-LFM-005 | completion elegível envia scrobble uma vez | integração com double HTTP |
| ☐ | LFM-011 | P1 | INV-LFM-005 | completion inelegível não envia scrobble | integração com double HTTP |
| ☐ | LFM-012 | P1 | INV-LFM-006 | disconnect deixa status desconectado | integração |
| ☐ | LFM-013 | P1 | INV-LFM-006 | disconnect remove secrets e dados locais de credencial | integração |
| ☐ | LFM-014 | P2 | INV-ENR-008, INV-LFM-006 | disconnect limpa somente snapshots Last.fm | integração |
| ☐ | LFM-015 | P2 | INV-ERR-004, INV-ERR-005 | erros auth/network/storage mapeiam para variante pública e não vazam secrets | contrato |

### Settings

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | SET-001 | P1 | INV-SET-002, INV-SET-004 | ler settings default/persistido retorna valores normalizados | integração |
| ☐ | SET-002 | P1 | INV-SET-001, INV-SET-003 | update válido persiste e altera runtime aplicável | integração |
| ☐ | SET-003 | P1 | INV-SET-001 | limites de crossfade/quality/source/path | unidade |
| ☐ | SET-004 | P2 | INV-SET-003 | crossfade novo afeta player sem reopen | integração |
| ☐ | SET-005 | P2 | INV-SET-003 | normalização de volume nova afeta player sem reopen | integração |
| ☐ | SET-006 | P1 | INV-SET-003, INV-SET-004 | settings sobrevivem a reopen | integração |
| ☐ | SET-007 | P1 | INV-SET-004 | open reaplica settings persistidos | integração |
| ☐ | SET-008 | P2 | INV-SET-002 | valores legados inválidos são normalizados nos defaults vigentes | unidade |
| ☐ | SET-009 | P1 | INV-SET-001, INV-ERR-002, INV-ERR-003 | input inválido retorna variante InvalidInput, sem depender da mensagem | contrato |

### Secure storage

| Check | ID | P | Invariantes | Cenário mínimo da baseline | Tipo principal |
| --- | --- | --- | --- | --- | --- |
| ☐ | SEC-001 | P1 | INV-SEC-001 | new carrega dados não sensíveis e separa área de secrets | integração |
| ☐ | SEC-002 | P1 | INV-SEC-001 | set_secret round-trip via adapter/plataforma controlada | integração de adapter |
| ☐ | SEC-003 | P1 | INV-SEC-001 | get_secret recupera valor correto sem expor em diagnostics | integração de adapter |
| ☐ | SEC-004 | P1 | INV-SEC-001, INV-SEC-002 | delete_secret remove valor e é idempotente para ausência suportada | integração de adapter |
| ☐ | SEC-005 | P2 | INV-SEC-002 | missing secret sinaliza ausência conforme contrato atual | unidade |
| ☐ | SEC-006 | P2 | INV-SEC-003 | legacy encrypted secret migra automaticamente | integração |
| ☐ | SEC-007 | P2 | INV-SEC-003 | cleanup legado só ocorre após migração persistida com sucesso | integração |
| ☐ | SEC-008 | P2 | INV-SEC-001 | KV não sensível set/get/delete mantém tipos/valores esperados | unidade |
| ☐ | SEC-009 | P2 | INV-SEC-001 | save_data persiste KV e new recarrega | integração |
| ☐ | SEC-010 | P2 | INV-SEC-004 | Unix cria/hardena diretório 0700 e arquivo 0600 | integração plataforma |
| ☐ | SEC-011 | P2 | INV-SEC-005 | falhas de keyring/mutex/fs retornam erro sem panic | unidade |
| ☐ | SEC-012 | P2 | INV-SEC-005, INV-ERR-003 | falha SecureStore na fronteira Last.fm vira CoreError::Storage | contrato |

## Evidência existente que deve ser reaproveitada

A auditoria durante a F0.06 encontrou cobertura interna já útil. Ela deve ser **mapeada e, quando necessário, elevada para teste de contrato/integração**, em vez de reescrita sem necessidade:

- `core_opens_with_mock_audio_and_persists_settings` — candidato para CORE-001/006/007 e SET.
- `completed_playback_advances_the_queue_and_records_history` — candidato para CORE-013/014, PLAY-023 e HIST-001.
- `repeated_track_completion_records_each_listen` — candidato para HIST-002.
- `pagination_is_bounded_and_reports_the_next_offset` — candidato para LIB-010/013 e HIST-004.
- `artwork_paths_must_be_contained_by_the_covers_directory` — candidato para META-013/014/015.
- `gapless_queue_reorder_cancels_the_old_successor`, `repeat_one_and_single_track_repeat_all_restart_without_a_control_poll` e testes correlatos de `audio::player` — candidatos para PLAY-022–027.
- `library_paths_can_be_added_listed_and_removed`, `library_pages_are_bounded_and_stably_ordered`, `scan_folder_skips_file_and_directory_symlinks`, `scan_folder_stops_when_cancellation_is_requested` e `audio_file_filter_only_accepts_enabled_playback_formats` — candidatos para LIB/SCAN.
- `hybrid_save_updates_tags_index_search_and_undo_restores_bytes`, `database_only_edit_survives_rescan_without_touching_file`, `failed_file_write_is_journaled_and_leaves_index_unchanged`, `invalid_edit_creates_no_journal_or_mutation` — candidatos para META-004–009.
- `remote_webp_and_gif_are_normalized_and_truncated_images_rejected`, `artwork_limits_reject_excessive_bytes_before_decoding`, `replay_gain_parser_accepts_valid_bounded_db_values` — candidatos para artwork/PLAY-026.
- `legacy_secret_migrates_automatically`, `secure_permissions_enforced_on_unix`, `poisoned_data_mutex_returns_errors_instead_of_panicking` e demais testes de `secure_store` — candidatos para SEC.
- Testes de `lastfm.rs` para auth token, session poll, now playing, scrobble, payload vazio e diagnostics — candidatos para LFM.

## Ordem de fechamento da checklist

A ordem segue a F0.04:

1. **Gates transversais P0** — API Rust, UniFFI, Swift e GTK.
2. **Lifecycle P0** — DB novo, DB existente/migration e open.
3. **Library P0** — scan básico, formatos, symlinks, paginação e cancelamento não destrutivo.
4. **Playback P0** — play/state/queue/session/automatic advancement.
5. **P1 local** — playlists, history, metadata editing, settings e secure store.
6. **P1 remoto** — enrichment e Last.fm usando doubles.
7. **P2** — diagnostics, TTL/failure policy, artwork edge cases, ratings/hidden/suggest-less e compatibilidades específicas.

## Checklist agregada

| Grupo | P0 | P1 | P2 | Total | Estado F0.06 |
| --- | ---: | ---: | ---: | ---: | --- |
| Casos de uso F0.03 | 44 | 97 | 39 | 180 | matriz definida |
| Gates transversais | 6 | 0 | 0 | 6 | 3 já existentes no CI; 3 precisam de evidência explícita |
| **Total rastreável** | **50** | **97** | **39** | **186** | cobertura a fechar nas próximas etapas |

> Os 186 itens rastreáveis não significam 186 testes. Testes de integração bem desenhados devem cobrir múltiplos IDs/invariantes sem esconder qual contrato protegem.

## Critério de conclusão da F0.06

- [x] todos os 180 IDs da F0.03 aparecem exatamente uma vez na matriz;
- [x] criticidades da F0.04 foram preservadas: 44 P0, 97 P1 e 39 P2;
- [x] invariantes da F0.05 foram ligados aos casos de uso relevantes;
- [x] cada caso possui cenário mínimo e tipo principal de teste;
- [x] gates de API Rust, UniFFI, Swift e GTK foram registrados separadamente;
- [x] cobertura existente foi identificada como material reutilizável;
- [x] a regra para marcar uma linha como concluída foi definida;
- [x] a matriz pode ser usada como checklist de implementação da baseline;
- [x] nenhuma alteração de código de produção foi necessária nesta etapa.

A Fase 0 poderá ser considerada protegida quando as caixas aplicáveis desta matriz estiverem marcadas e os gates definidos permanecerem verdes.
