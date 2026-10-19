# Destaque contextual da faixa

Implementado em 19/10/2026 no core e no cliente macOS.

O título e o indicador de reprodução de uma listagem consideram tanto a faixa
quanto a origem da ocorrência ativa. Navegar não altera a origem; iniciar uma
reprodução em outro contexto altera. Pausar preserva o destaque.

## Origens do cliente

| Origem | Identificação |
| --- | --- |
| Biblioteca de músicas | `library` |
| Álbum | `release:<id>` |
| Playlist salva | `playlist:<id>#<posição original, base zero>` |
| Busca global | `search:<consulta exibida>` |
| Faixas do artista | `artist:<id>` |
| Populares do artista | `artist:<id>:popular` |
| Prévia de Replay | `replay:<identidade do período>` |
| Entrada do histórico | `history:<id do evento>` |
| Ações manuais de fila | `queue` |
| Reprodução pelo menu do player | `player` |

O contexto é um identificador opaco para o core, separado de arquivo/provedor de
áudio e da página aberta. A playlist atribui a posição antes de embaralhar; a
ocorrência leva essa origem ao avançar, voltar, repetir e editar a fila.

O core publica `PlaybackSnapshot.source_context`, preserva as origens na sessão
e oferece `play_with_context`/`add_to_queue_with_context`. APIs antigas continuam
disponíveis e produzem contexto vazio. Listagens sem contexto não herdam destaque
por coincidência de ID. Controles globais e a indicação do item atual na fila
continuam identificando a reprodução ativa.

O cliente observa `activeSourceContext` separadamente do relógio de reprodução,
assim como já observa `activeTrackID`. A tabela nativa só recebe o ID ativo quando
a origem é a biblioteca; listas SwiftUI consultam o contexto da própria linha.

## Validação

- Testes de reprodução do core cobrem duplicatas, shuffle, navegação, alterações
  da fila, pausa, restauração e rejeição de contexto inválido.
- Testes do player cobrem propagação na transição gapless e nas repetições.
- Testes macOS cobrem a mudança de origem sem mudar de faixa, início em uma
  ocorrência repetida e preservação das posições durante shuffle.
- Bindings UniFFI e a biblioteca embarcada são regenerados em conjunto.

A rodada focada macOS passou nos 26 testes unitários afetados. Também passaram os
testes reais de interface para não destacar o álbum quando a origem é uma playlist
e para manter o indicador acompanhando o avanço automático no álbum de origem.
O smoke test real UniFFI passou.

A regressão Rust passou com 340 testes, três ignorados e três falhas preexistentes
excluídas após reprodução no código original: os testes
`similar_artist_snapshot_materializes_targets_and_their_identities_atomically`,
`legacy_rows_survive_migration_and_reopening` e
`application_layer_does_not_reference_database_internals`.

A rodada ampla macOS passou em 376 de 378 testes. Permaneceram duas falhas visuais
fora do fluxo alterado, também observadas sem paralelismo:
`TrackMetadataLayoutTests.testRenderMetadataWindow` (transição interna SwiftUI) e
`RetrospectiveChartTooltipTests.testRenderedChartCreatesTooltipRegionsForBothBarsOfEveryDay`
(view de tooltip ausente). Essas falhas não foram corrigidas por esta entrega.

Sessões antigas restauram somente a origem conhecida da faixa atual. Não é
possível reconstruir com segurança ocorrências de playlist que não foram salvas;
nesses casos, não se tenta deduzir o destaque pela sequência da fila.
