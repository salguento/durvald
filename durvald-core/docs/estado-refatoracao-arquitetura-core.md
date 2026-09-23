# Estado da refatoração arquitetural do core

Última atualização: 23 de setembro de 2026  
Commit de referência: `1697eab refactor(core): move artwork reading into application service`

## Visão geral

A refatoração incremental está avançada e estável. Os Marcos 1–4 foram
concluídos, o Marco 5 está em andamento e os Marcos 6 e 7 ainda não começaram.

O roteiro de referência permanece em
[`arquitetura/roteiro-implementacao-direto.md`](arquitetura/roteiro-implementacao-direto.md).

## Progresso por marco

| Marco | Estado | Resultado |
| --- | --- | --- |
| 1 — Base mínima de testes | Concluído | Infraestrutura temporária, fixtures, `TestCore`, lifecycle e contratos públicos |
| 2 — Baseline P0 | Concluído | Biblioteca, playback, fila, sessão, avanço automático, cancelamento e históricos protegidos |
| 3 — `PlaybackApplication` | Concluído | Coordenação completa de playback removida da fachada |
| 4 — `LibraryApplication` | Concluído | Scan, paths, catálogo, busca e consultas migrados |
| 5 — Fachada por domínio | Em andamento | History, playlists e metadata/artwork extraídos |
| 6 — Modelos e infraestrutura | Não iniciado | SQLite, rows, ports e adapters continuam no formato atual |
| 7 — Composição e redução da API | Não iniciado | `DurvaldCore::open`, accessors e exports legados ainda precisam ser tratados |

## Estrutura implementada

O diretório `src/application/` contém cinco serviços:

- `PlaybackApplication`;
- `LibraryApplication`;
- `HistoryApplication`;
- `PlaylistApplication`;
- `MetadataApplication`.

Durante a extração, `src/core.rs` caiu de aproximadamente 2.903 para 1.521
linhas, uma redução próxima de 48%, mantendo as mesmas 88 operações assíncronas
públicas. A API foi preservada enquanto a implementação interna foi deslocada
para serviços de aplicação.

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
- consultas derivadas por artista e release.

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

## Situação detalhada do Marco 5

A ordem definida no roteiro é:

1. playlists e history — **concluído**;
2. metadata e artwork — **concluído no escopo público identificado**;
3. settings e secure storage — **próximo**;
4. enrichment — **pendente**;
5. Last.fm — **pendente**.

Ainda existem operações de preferências de tracks e releases diretamente em
`core.rs`, como favorito, ocultação, `suggest less` e rating. Antes de fechar
definitivamente a fronteira de catálogo/metadata, será necessário decidir se
essas mutações pertencem a `LibraryApplication`, `MetadataApplication` ou a um
serviço próprio. Essa é uma pendência de organização, não uma regressão
funcional.

## Responsabilidades ainda presentes em `DurvaldCore`

As maiores concentrações restantes são:

- construção e composição de banco, player, enrichment e Last.fm;
- helpers genéricos de execução SQLite;
- settings;
- mutações de preferências de tracks e releases;
- chamadas de enrichment;
- autenticação e configuração Last.fm;
- accessors concretos para banco, player, Last.fm e diretório de capas.

A fachada está significativamente mais fina, mas ainda não atingiu o estado
final previsto no Marco 7.

## Validação atual

Na implementação mais recente foram aprovados:

- `rustfmt`;
- `git diff --check`;
- Clippy com a feature UniFFI e warnings tratados como erro;
- suíte completa do core: **281 testes aprovados e 3 ignorados**.

Os gates globais de UniFFI, Swift e GTK foram executados no início da extração
arquitetural, e o lockfile GTK foi atualizado deliberadamente. Entretanto, a
geração dos bindings, o build Swift e o build GTK não foram repetidos depois de
cada commit recente do Marco 5. O código Rust está verde no estado de referência,
mas o gate multiplataforma completo precisa ser renovado no próximo checkpoint.

## Marcos pendentes

### Marco 5

- criar `SettingsApplication`;
- mover leitura, validação, persistência e efeitos runtime de settings;
- definir a fronteira prática do secure storage;
- extrair coordenação de enrichment;
- extrair coordenação Last.fm;
- resolver as preferências de tracks e releases ainda na fachada.

### Marco 6

Ainda não houve:

- separação sistemática entre DTO público, domínio e row SQLite;
- introdução gradual de IDs de domínio;
- criação de `infrastructure/sqlite`;
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

Iniciar a terceira fatia do Marco 5: **settings e secure storage**, em incrementos
pequenos:

1. fechar a baseline diretamente afetada de settings;
2. criar `application/settings.rs`;
3. mover primeiro a leitura e normalização;
4. mover validação, persistência e atualização runtime do player;
5. avaliar a fronteira de secure storage sem criar um port antecipadamente;
6. executar o gate Rust;
7. ao fechar a fatia, renovar UniFFI, bindings Swift, build macOS e GTK.

## Resumo executivo

O padrão arquitetural foi provado e replicado em cinco serviços. A migração já
retirou da fachada playback, biblioteca, histórico, playlists e metadata/artwork.
O próximo bloco é settings; depois vêm os dois domínios mais acoplados e
sensíveis, enrichment e Last.fm.

## Histórico de atualizações

| Data | Commit | Alteração registrada |
| --- | --- | --- |
| 23/09/2026 | `1697eab` | Criação do relatório após concluir a extração de metadata e artwork |
