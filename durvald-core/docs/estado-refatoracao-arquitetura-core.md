# Estado da refatoração arquitetural do core

Última atualização: 27 de setembro de 2026

Commit de referência: `018fabe refactor(core): finish internalizing audio module`

Estado adicional: Marco 7 concluído e protegido por testes arquiteturais

## Visão geral

A refatoração incremental está concluída quanto à implementação dos Marcos
1–7. O `DurvaldCore` permanece como fachada pública, a composição está
centralizada e os módulos de implementação foram internalizados. O gate GTK
do checkpoint final permanece bloqueado apenas pela ausência das bibliotecas
nativas no macOS.

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
| 6 — Modelos e infraestrutura | Implementação concluída | IDs e modelos de domínio separados de DTOs/rows, adapters consolidados e fronteira arquitetural protegida por teste |
| 7 — Composição e redução da API | Concluído | Composition root centralizado, accessors concretos removidos e módulos internos retirados da API pública |

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

Durante a extração, `src/core.rs` caiu de aproximadamente 2.903 para 1.201
linhas, uma redução próxima de 59%, mantendo 89 operações assíncronas
públicas. A API foi preservada enquanto a implementação interna foi deslocada
para serviços de aplicação.

O Marco 6 também introduziu `src/domain/ids.rs`, com `TrackId`, `ReleaseId`,
`ArtistId`, `PlaylistId` e `PlaybackHistoryId`. A fachada converte os valores
`i64` da API pública e
as operações de catálogo migradas recebem apenas IDs já validados.

O diretório `src/infrastructure/sqlite/` contém atualmente doze adapters
concretos:

- histórico de reprodução;
- settings;
- persistência de metadata de faixa;
- paths da biblioteca;
- preferências de catálogo;
- consultas de faixas;
- consultas de lançamentos;
- consultas de artistas;
- busca agregada de catálogo;
- preparação, persistência dos lotes e reconciliação SQLite do scan da
  biblioteca;
- sessão de playback completamente isolada;
- playlists, incluindo listagem agregada, consulta individual, faixas,
  artwork, mutações e preferências.

Com a extração da busca, o helper genérico `LibraryApplication::run_database`
deixou de ter consumidores e foi removido. As leituras de catálogo não
relacionadas ao scan já não chamam `database::operations` diretamente.
Após a extração do ciclo de scan, `LibraryApplication` também deixou de receber
o pool SQLite diretamente. A extração de metadata passou a usar
`LocalMetadataExtractor`, fora do namespace de banco.

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
configuração, desconexão e integração com enrichment/playback. O cliente
concreto permanece encapsulado atrás da composição e do serviço de aplicação.

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

## Responsabilidades deliberadas em `DurvaldCore`

As responsabilidades restantes da fachada são:

- conversão de tipos da API pública para tipos internos;
- delegação dos casos de uso aos oito serviços de aplicação;
- inicialização pública por `open`, encaminhada ao composition root;
- adaptação entre modelos públicos e modelos internos.

A construção de banco, player, adapters, enrichment e Last.fm reside em
`composition.rs`. Não há accessors concretos públicos para infraestrutura.

## Validação atual

No checkpoint local de Rust de 27/09 foram aprovados:

- `rustfmt`;
- `git diff --check`;
- Clippy com a feature UniFFI e warnings tratados como erro;
- suíte completa do core com `test-support`: **287 testes aprovados e 3 ignorados**;
- compilação de toda a superfície UniFFI.

No checkpoint global anterior, preservado após o Marco 6, também foram
aprovados geração dos bindings, smoke test FFI, build Debug e `DurvaldTests` no
macOS e formatação do frontend GTK. Esses gates de cliente ainda devem ser
repetidos para o fechamento global definitivo do Marco 7.

Os comandos `cargo clippy --locked --all-targets -- -D warnings` e
`cargo build --locked` do GTK foram executados, mas não chegaram ao código do
projeto: `pkg-config` não encontrou as bibliotecas nativas `gtk4` e
`graphene-gobject-1.0` neste macOS. As dependências Rust bloqueadas no lockfile
foram baixadas normalmente. Portanto, UniFFI e Swift estão verdes; a compilação
GTK precisa ser repetida em ambiente com GTK 4 instalado.

## Situação dos marcos finais

### Marco 6 — implementação concluída

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
- conclusão da extração das consultas individuais de faixa, lançamento e artista;
- conclusão das consultas relacionais por lançamento e artista;
- extração das consultas completa e paginada da coleção de faixas;
- extração das consultas completa e paginada da coleção de lançamentos;
- extração da listagem completa da coleção de artistas;
- extração da busca agregada de catálogo;
- conclusão dos adapters de persistência e extração do scan;
- retirada de todas as resoluções diretas de faixa de `PlaybackApplication`;
- conclusão do adapter de sessão e retirada do pool de `PlaybackApplication`;
- consultas de playlist, suas faixas e artwork isoladas no adapter SQLite;
- criação de playlist isolada no adapter SQLite;
- atualização de playlist isolada no adapter SQLite;
- exclusão de playlist isolada no adapter SQLite;
- preferência de favorito de playlist isolada no adapter SQLite;
- preferência `suggest_less` de playlist isolada no adapter SQLite;
- inclusão de faixa em playlist isolada no adapter SQLite, com modelo de domínio
  próprio;
- remoção de faixa de playlist isolada no adapter SQLite;
- reordenação de faixa isolada no adapter SQLite e pool retirado de
  `PlaylistApplication`;
- row de playlist convertida para modelo de domínio dentro do adapter SQLite;
- row e serialização JSON da sessão de playback confinadas ao adapter SQLite;
- consultas direta, completa e paginada de faixas convertidas para modelo de
  domínio no adapter de catálogo;
- consulta de faixas por artista convertida para o mesmo modelo de domínio no
  adapter SQLite;
- consulta de faixas por release convertida para o mesmo modelo de domínio no
  adapter SQLite;
- faixas do resultado agregado de busca convertidas para o mesmo modelo de
  domínio no adapter SQLite;
- faixas de playlist convertidas para o mesmo modelo de domínio, removendo o
  último uso de `SongItem` em `application`;
- consultas principal, individual e paginada de releases convertidas para
  `CatalogRelease` no adapter SQLite;
- releases relacionados a artista convertidos para `CatalogRelease` no adapter
  SQLite;
- releases dos resultados de busca convertidos para `CatalogRelease`, removendo
  a última referência explícita a `database::models` em `application`, no
  adapter SQLite;
- consultas individual e completa de artistas convertidas para `CatalogArtist`
  no adapter SQLite;
- artistas dos resultados de busca convertidos para `CatalogArtist` no adapter
  SQLite;
- playlists dos resultados de busca convertidas para `PlaylistDetails`,
  concluindo a retirada de rows do retorno do adapter de busca;
- auditoria confirma que `application/` não referencia rows, operações, pool ou
  conexões SQLite;
- teste arquitetural protege essa independência contra regressões no working
  tree.

Acoplamentos SQLite diretos que permanecem nos serviços de aplicação:

| Serviço | Referências diretas | Escopo restante |
| --- | ---: | --- |
| `LibraryApplication` | 0 | scan coordenado por adapters de persistência e extração local |
| `PlaybackApplication` | 0 | catálogo, sessão e histórico acessados por adapters dedicados |
| `PlaylistApplication` | 0 | operações acessadas pelo adapter de playlists |
| Demais serviços | 0 | já usam serviços internos ou adapters dedicados |

O gate estrutural do Marco 6 está atendido nas áreas migradas: DTOs públicos,
modelos de domínio e rows SQLite estão separados, e os serviços de aplicação
não conhecem detalhes do banco. A auditoria de ports não identificou outra
dependência com necessidade concreta de substituição além das fronteiras já
isoladas; portanto, nenhum trait adicional foi criado.

Nenhum dos oito serviços de aplicação recebe o pool SQLite diretamente.

### Marco 7 — implementação concluída

Foi concluído:

- criação de `composition.rs` como composition root explícito;
- retirada da montagem de dependências de `DurvaldCore`;
- remoção dos accessors concretos públicos;
- remoção dos reexports legados da raiz;
- internalização de `core`, `database`, `enrichment`, `lastfm`, `secure_store`,
  `metadata` e `audio`;
- preservação de `api::*`, `DurvaldCore` e da superfície UniFFI como contratos
  públicos deliberados;
- proteção automatizada para impedir que módulos internos voltem a ser
  públicos acidentalmente.

Permanece como gate de ambiente, não como implementação do marco:

- repetir Clippy e build do GTK em ambiente com GTK 4 e Graphene instalados.

## Próximos passos recomendados

1. repetir Clippy e build GTK em ambiente com GTK 4 e Graphene instalados;
2. manter futuras mudanças arquiteturais em fatias pequenas, cada uma com sua
   fronteira e teste de regressão explícitos;
3. tratar codecs adicionais, integração com o sistema operacional e file
   watcher como iniciativas de produto separadas desta refatoração.

## Resumo executivo

O padrão arquitetural foi replicado em oito serviços e os Marcos 1–7 foram
concluídos quanto à implementação.
A fachada pública está reduzida principalmente à delegação, composição e
conversão de fronteira. No Marco 6, a tipagem dos IDs foi estabelecida, todas
as consultas comuns de catálogo foram deslocadas para adapters SQLite e o ciclo
de scan, o playback e playlists foram isolados. Nenhum serviço de aplicação
conhece rows, operações, pools ou conexões SQLite; esse limite agora é protegido
por teste arquitetural. A raiz da crate expõe deliberadamente apenas `api`, os
reexports de `api::*`, `DurvaldCore` e o módulo opcional `test_support`.

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
| 23/09/2026 | `255587e` | Consulta individual de faixa isolada em adapter SQLite |
| 23/09/2026 | `ec3dfce` | Consulta individual de lançamento isolada em adapter SQLite |
| 23/09/2026 | `14b2169` | Consulta individual de artista isolada em adapter SQLite |
| 23/09/2026 | `0b34097` | Consulta de faixas por lançamento isolada em adapter SQLite |
| 23/09/2026 | `e171c1a` | Consultas de lançamentos e faixas por artista isoladas em adapter SQLite |
| 23/09/2026 | `3e024dc` | Listagem completa de faixas isolada em adapter SQLite |
| 23/09/2026 | `59e11f4` | Paginação de faixas isolada em adapter SQLite |
| 23/09/2026 | `fc3e232` | Listagem completa de lançamentos isolada em adapter SQLite |
| 23/09/2026 | `d43aa85` | Paginação de lançamentos isolada em adapter SQLite |
| 23/09/2026 | `9bee74c` | Listagem completa de artistas isolada em adapter SQLite |
| 23/09/2026 | `3d366ac` | Busca agregada de catálogo isolada em adapter SQLite |
| 23/09/2026 | `c804cb2` | Preparação do scan isolada em adapter SQLite |
| 23/09/2026 | `14bfedf` | Persistência dos lotes do scan isolada em adapter SQLite |
| 23/09/2026 | `3eb964c` | Reconciliação SQLite do scan isolada em adapter SQLite |
| 24/09/2026 | `df9c31a` | Extração local de metadata isolada do namespace de banco |
| 24/09/2026 | `1f53002` | Resolução inicial de faixa do playback redirecionada ao adapter de catálogo |
| 24/09/2026 | `71b8fee` | Helper interno de faixa do playback redirecionado ao adapter de catálogo |
| 24/09/2026 | `c7ff0bd` | Resolução da faixa atual do snapshot redirecionada ao adapter de catálogo |
| 24/09/2026 | `915f6a8` | Resolução da faixa do tracking Last.fm redirecionada ao adapter de catálogo |
| 24/09/2026 | `b485216` | Resolução da duração na conclusão redirecionada ao adapter de catálogo |
| 24/09/2026 | `5afd7f0` | Leitura pública da última sessão isolada em adapter SQLite |
| 24/09/2026 | `296b1db` | Persistência automática da sessão isolada em adapter SQLite |
| 24/09/2026 | `90498bf` | Update de progresso da sessão isolado em adapter SQLite |
| 24/09/2026 | `f3f427f` | Update de volume da sessão isolado em adapter SQLite |
| 24/09/2026 | `87e4765` | Escrita pública da última sessão isolada em adapter SQLite |
| 24/09/2026 | `c4fb369` | Registro de conclusão isolado no adapter de histórico |
| 24/09/2026 | `3968e15` | Listagem agregada de playlists isolada em adapter SQLite |
| 24/09/2026 | `534198a` | Consulta individual de playlist isolada em adapter SQLite |
| 24/09/2026 | `baeae60` | Consulta de faixas da playlist isolada em adapter SQLite |
| 24/09/2026 | `571dd1c` | Consulta de artwork da playlist isolada em adapter SQLite |
| 24/09/2026 | `738eb32` | Criação de playlist isolada em adapter SQLite |
| 24/09/2026 | `de80601` | Atualização de playlist isolada em adapter SQLite |
| 24/09/2026 | `6078256` | Exclusão de playlist isolada em adapter SQLite |
| 24/09/2026 | `f40a587` | Preferência de favorito de playlist isolada em adapter SQLite |
| 24/09/2026 | `a0a2108` | Preferência `suggest_less` de playlist isolada em adapter SQLite |
| 24/09/2026 | `82f3903` | Inclusão de faixa em playlist isolada em adapter SQLite |
| 24/09/2026 | `b221236` | Remoção de faixa de playlist isolada em adapter SQLite |
| 24/09/2026 | `154fcde` | Reordenação de faixa isolada e pool retirado de `PlaylistApplication` |
| 24/09/2026 | `8ab8b63` | Row de playlist convertida para modelo de domínio no adapter SQLite |
| 24/09/2026 | `c1b39b6` | Row e JSON da sessão confinados ao adapter SQLite |
| 24/09/2026 | `d0e0ba5` | Consultas principais de faixa convertidas para modelo de domínio |
| 24/09/2026 | `7da46dc` | Faixas por artista convertidas para modelo de domínio |
| 24/09/2026 | `0010feb` | Faixas por release convertidas para modelo de domínio |
| 24/09/2026 | `8123c98` | Faixas da busca convertidas para modelo de domínio |
| 24/09/2026 | `e389be0` | Faixas de playlist convertidas para modelo de domínio |
| 24/09/2026 | `ffa8ac2` | Consultas principais de release convertidas para modelo de domínio |
| 24/09/2026 | `84b5567` | Releases por artista convertidos para modelo de domínio |
| 24/09/2026 | `2ec8417` | Releases da busca convertidos para modelo de domínio |
| 24/09/2026 | `0962a2c` | Consultas de artista convertidas para modelo de domínio |
| 24/09/2026 | `7de6227` | Artistas da busca convertidos para modelo de domínio |
| 24/09/2026 | `aadfd77` | Playlists da busca convertidas para modelo de domínio |
| 24/09/2026 | `f9f89a3` | Auditoria e teste da fronteira entre application e banco |
| 24/09/2026 | estado não commitado | Regeneração UniFFI e checkpoint global do Marco 6 |
| 24–25/09/2026 | `157bfa9`–`50cc77a` | Criação e consolidação do composition root |
| 25/09/2026 | `fe833a5` | Remoção dos accessors concretos da fachada |
| 25/09/2026 | `c2b95bd`–`760bacd` | Remoção de reexports legados e internalização dos módulos de implementação |
| 27/09/2026 | `018fabe` | Internalização final de áudio e proteção automatizada da superfície pública |
