# Estado da refatoração arquitetural do core

Última atualização: 23 de setembro de 2026

Commit de referência: `fa8c335 refactor(core): isolate catalog preference persistence`

Estado adicional: consulta individual de faixa isolada e ainda não commitada

## Visão geral

A refatoração incremental está avançada e estável. Os Marcos 1–5 foram
concluídos, o Marco 6 está em andamento e o Marco 7 ainda não começou.

O roteiro de referência permanece em
[`arquitetura/roteiro-implementacao-direto.md`](arquitetura/roteiro-implementacao-direto.md).

## Progresso por marco

| Marco | Estado | Resultado |
| --- | --- | --- |
| 1 — Base mínima de testes | Concluído | Infraestrutura temporária, fixtures, `TestCore`, lifecycle e contratos públicos |
| 2 — Baseline P0 | Concluído | Biblioteca, playback, fila, sessão, avanço automático, cancelamento e históricos protegidos |
| 3 — `PlaybackApplication` | Concluído | Coordenação completa de playback removida da fachada |
| 4 — `LibraryApplication` | Concluído | Scan, paths, catálogo, busca e consultas migrados |
| 5 — Fachada por domínio | Concluído | History, playlists, metadata/artwork, settings, enrichment, Last.fm e preferências extraídos |
| 6 — Modelos e infraestrutura | Em andamento | IDs de domínio de catálogo introduzidos; SQLite, rows, ports e adapters ainda pendentes |
| 7 — Composição e redução da API | Não iniciado | `DurvaldCore::open`, accessors e exports legados ainda precisam ser tratados |

## Estrutura implementada

O diretório `src/application/` contém oito serviços:

- `PlaybackApplication`;
- `LibraryApplication`;
- `HistoryApplication`;
- `PlaylistApplication`;
- `MetadataApplication`;
- `SettingsApplication`;
- `EnrichmentApplication`;
- `LastFmApplication`.

Durante a extração, `src/core.rs` caiu de aproximadamente 2.903 para 1.349
linhas, uma redução próxima de 54%, mantendo 89 operações assíncronas
públicas. A API foi preservada enquanto a implementação interna foi deslocada
para serviços de aplicação.

O Marco 6 também introduziu `src/domain/ids.rs`, com `TrackId`, `ReleaseId`,
`ArtistId`, `PlaylistId` e `PlaybackHistoryId`. A fachada converte os valores
`i64` da API pública e
as operações de catálogo migradas recebem apenas IDs já validados.

## Implementações concluídas

### Proteção de comportamento

A baseline cobre:

- abertura, reabertura e diretórios do core;
- persistência de settings e sessão;
- contrato público Rust e erros;
- scan, paginação, formatos, symlinks e cancelamento;
- reprodução, pause, resume, stop, seek e volume;
- fila, navegação, shuffle e repeat;
- restauração e persistência de sessão;
- avanço automático sem polling;
- separação entre histórico de navegação e histórico de audição.

### Playback

O `PlaybackApplication` coordena:

- estado e snapshot;
- comandos básicos;
- fila e navegação;
- shuffle e repeat;
- persistência e restauração da sessão;
- completion automático;
- preloading e gapless;
- integração do acompanhamento de reprodução com Last.fm.

`DurvaldCore` atua essencialmente como delegador para essas operações.

### Biblioteca

O `LibraryApplication` concentra:

- scan explícito e configurado;
- cancelamento e progresso;
- paths da biblioteca;
- busca;
- listagem e paginação;
- consultas de tracks, releases e artistas;
- consultas derivadas por artista e release;
- favorito, ocultação, `suggest less` e rating de tracks e releases.

### History

O `HistoryApplication` concentra:

- leitura integral;
- paginação;
- remoção individual;
- limpeza completa.

### Playlists

O `PlaylistApplication` concentra:

- consultas;
- criação, atualização e exclusão;
- tracks ordenadas;
- inserção, remoção e movimentação;
- artwork de playlist;
- preferências específicas de playlist.

### Metadata e artwork

O `MetadataApplication` concentra:

- leitura de `TrackInfo`;
- extração de metadata de arquivo;
- edição;
- undo;
- leitura segura de artwork;
- validação de confinamento dos arquivos ao diretório de capas.

### Settings e secure storage

O `SettingsApplication` concentra leitura, normalização, validação, persistência
e aplicação runtime das configurações de áudio. O secure storage permanece
encapsulado no `LastFmClient`, que é seu consumidor concreto; não foi criado um
port sem necessidade de substituição identificada.

### Enrichment

O `EnrichmentApplication` concentra leituras locais, configuração, identidade,
refresh, overrides e sincronização de metadata de lançamentos. O serviço mantém
a coordenação remota já decomposta e a fachada apenas delega os casos de uso.

### Last.fm

O `LastFmApplication` concentra estado, autenticação, polling de sessão,
configuração, desconexão e integração com enrichment/playback. O accessor
concreto de `LastFmClient` permanece apenas como compatibilidade transitória.

## Situação detalhada do Marco 5

A ordem definida no roteiro é:

1. playlists e history — **concluído**;
2. metadata e artwork — **concluído**;
3. settings e secure storage — **concluído**;
4. enrichment — **concluído**;
5. Last.fm — **concluído**;
6. preferências de tracks e releases — **concluído em `LibraryApplication`**.

Com a remoção dos helpers genéricos de mutação SQLite de `DurvaldCore`, a
fachada deixou de coordenar diretamente os casos de uso previstos neste marco.

## Responsabilidades ainda presentes em `DurvaldCore`

As maiores concentrações restantes são:

- construção e composição de banco, player, serviços, enrichment e Last.fm;
- conversão de tipos da API pública para tipos internos;
- adaptação entre modelos públicos e representações internas ainda legadas;
- accessors concretos para banco, player, Last.fm e diretório de capas.

A fachada está significativamente mais fina, mas ainda não atingiu o estado
final previsto no Marco 7.

## Validação atual

Na implementação mais recente foram aprovados:

- `rustfmt`;
- `git diff --check`;
- Clippy com a feature UniFFI e warnings tratados como erro;
- suíte completa do core: **287 testes aprovados e 3 ignorados**.

Os gates globais de UniFFI, Swift e GTK foram executados no início da extração
arquitetural, incluindo a correção de `process_mock_audio`, e o lockfile GTK foi
atualizado deliberadamente no macOS. Eles não foram repetidos após todas as
fatias posteriores dos Marcos 5 e 6. O código Rust está verde no estado atual,
mas o gate multiplataforma completo precisa ser renovado no próximo checkpoint.

## Marcos pendentes

### Marco 6

Já foi concluído:

- criação do módulo interno `domain`;
- introdução de `TrackId`, `ReleaseId`, `ArtistId`, `PlaylistId` e `PlaybackHistoryId`;
- conversão de IDs na fronteira pública das operações migradas;
- uso de IDs tipados nas mutações e consultas de catálogo;
- remoção da validação primitiva duplicada dos serviços migrados;
- criação inicial de `infrastructure/sqlite` para histórico de reprodução;
- separação entre row SQLite, modelo de domínio e DTO público em histórico;
- aplicação do mesmo corte arquitetural à persistência de settings;
- retirada de pool e conexão SQLite de `MetadataApplication`;
- extração incremental da persistência de paths de `LibraryApplication`;
- extração das mutações de preferências de tracks e releases;
- início da extração das consultas de catálogo pela consulta individual de faixa.

Ainda falta:

- separação sistemática entre DTO público, domínio e row SQLite;
- estender IDs de domínio às demais áreas estabilizadas;
- ampliar `infrastructure/sqlite` para as demais áreas;
- ports pequenos para dependências substituíveis;
- retirada das chamadas diretas a `database::operations` dos serviços de aplicação.

Os serviços atuais ainda recebem implementações concretas, especialmente o pool
SQLite. Isso é deliberado e compatível com a etapa atual do roteiro.

### Marco 7

Ainda falta:

- criar um composition root explícito;
- retirar a montagem de dependências de `DurvaldCore`;
- revisar e remover accessors concretos;
- reduzir exports internos legados;
- regenerar bindings;
- validar Swift e GTK;
- consolidar a documentação arquitetural final.

## Próximo passo recomendado

Continuar a introdução gradual de IDs de domínio nas áreas já estabilizadas:

1. concluir `ArtistId` nas consultas de catálogo e sua ponte com enrichment — **concluído**;
2. levar `TrackId` às entradas de playback e metadata — **concluído**;
3. introduzir `PlaylistId` nas operações de playlist — **concluído**;
4. manter a conversão de `i64` concentrada na fachada pública;
5. somente depois separar rows SQLite dos DTOs públicos de uma área pequena;
6. extrair adapters adicionais em `infrastructure/sqlite`, sem reescrever queries;
7. renovar UniFFI, bindings Swift, build macOS e GTK no fechamento do checkpoint.

## Resumo executivo

O padrão arquitetural foi replicado em oito serviços e o Marco 5 foi concluído.
A fachada pública está reduzida principalmente à delegação, composição e
conversão de fronteira. O Marco 6 começou pela tipagem dos IDs de catálogo; os
próximos blocos são ampliar essa tipagem e iniciar a separação controlada entre
DTOs públicos, modelos de domínio e rows SQLite.

## Histórico de atualizações

| Data | Commit | Alteração registrada |
| --- | --- | --- |
| 23/09/2026 | `1697eab` | Criação do relatório após concluir a extração de metadata e artwork |
| 23/09/2026 | `9011762`–`ff1f021` | Conclusão de settings, secure storage, enrichment e Last.fm |
| 23/09/2026 | `1d5ff1b`–`f4a41b3` | Conclusão das preferências de catálogo e do Marco 5 |
| 23/09/2026 | `8558dbc`–`903fe71` | Início do Marco 6 com IDs de domínio para catálogo |
| 23/09/2026 | `7fa544e` | Extensão de `ArtistId` às consultas de catálogo e à ponte de enrichment |
| 23/09/2026 | `345a2a1` | Extensão inicial de `TrackId` às entradas de playback |
| 23/09/2026 | `1734345` | Extensão de `TrackId` às entradas de metadata |
| 23/09/2026 | `90fa77e` | Introdução de `PlaylistId` nas operações de playlist |
| 23/09/2026 | `2ff6571` | Introdução de `PlaybackHistoryId` na remoção de histórico |
| 23/09/2026 | `ca94106` | Extensão de `ArtistId` às entradas de enrichment |
| 23/09/2026 | `47ca7e7` | Primeiro adapter SQLite e modelo de domínio para histórico |
| 23/09/2026 | `e1f5a9f` | Adapter SQLite e modelo de domínio para settings |
| 23/09/2026 | `5b58adf` | Leitura inicial de settings redirecionada ao adapter SQLite |
| 23/09/2026 | `c1a0596` | Persistência de metadata isolada em adapter SQLite |
| 23/09/2026 | `9b8ddaa` | Persistência de paths da biblioteca isolada em adapter SQLite |
| 23/09/2026 | `fa8c335` | Preferências de catálogo isoladas em adapter SQLite |
| 23/09/2026 | estado não commitado | Consulta individual de faixa isolada em adapter SQLite |
