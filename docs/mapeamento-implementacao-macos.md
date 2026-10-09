# Mapeamento da implementação macOS

Data: 04/10/2026. Referência: commit `66f859f` (árvore limpa no início da análise).

## Escopo e método

O levantamento cobre o inventário dos **66 arquivos Swift mantidos manualmente** em `durvald-macos/Durvald/Durvald` (19.897 linhas no snapshot), as configurações do projeto Xcode e os testes relevantes. Foram pesquisadas estruturas, renderers, tarefas, acesso a arquivos, caches, geometria, estado e pontos de reutilização; a leitura aprofundada foi dirigida aos caminhos encontrados. A cobertura por arquivo está no inventário ao final.

Não inclui uma auditoria interna do Rust, do cliente GTK ou dos binários. O bridge UniFFI `durvald_core.swift` e a cópia em `Generated/arm64` são código gerado: entram como dependência arquitetural, não como alvo de edição manual. Não foi executado Instruments, benchmark ou teste de UI para este documento. Os achados de eficiência descrevem trabalho presente no código e hipóteses de impacto, sem inventar tempos, CPU, RAM ou FPS.

O projeto usa deployment target macOS 26.5 e Swift 5.0 nas configurações encontradas do `.pbxproj`; isso não descreve todas as opções do compilador nem impõe adoção imediata de Swift 6.

**Nativo** significa estrutura/controle do SwiftUI ou AppKit. Uma `NSViewRepresentable`, uma subclasse de `NSTableView` ou uma view SwiftUI própria não deixam de usar APIs nativas. O critério 1 identifica onde o app **compõe manualmente um comportamento que poderia ser entregue por um controle ou contêiner nativo especializado**, além das customizações legítimas. Não há framework de UI web/HTML nos arquivos inspecionados; a arquitetura visual é SwiftUI + AppKit.

As referências locais usam caminhos absolutos e linhas do snapshot para abrir no Codex. Números de linha precisam ser revistos após refatorações.

## Prioridades e grau de certeza

| Nível | Significado |
| --- | --- |
| P1 | Alta exposição a regressões de UI ou trabalho que cresce com catálogo/histórico; priorizar diagnóstico e consolidação. |
| P2 | Padronização ou eficiência com benefício plausível e dependência de validação dirigida. |
| P3 | Especialização legítima, limpeza ou oportunidade de menor urgência. |

Presença de código duplicado, polling, loop ou leitura síncrona é uma constatação estática. A gravidade em produção é uma hipótese quando não há medição. A regressão recente da topbar com sidebar aberta e as divergências de picker/placeholder têm evidência da sessão, mas esta análise não reexecutou esses cenários.

## Visão geral da arquitetura

| Camada | Implementação atual | Avaliação |
| --- | --- | --- |
| Janela e comandos | SwiftUI App/WindowGroup/Settings/Commands, auxiliares AppKit | Base nativa; políticas customizadas em janelas secundárias. |
| Navegação | NavigationSplitView + LibraryNavigationHistory + linhas próprias | Split nativo; rotas e apresentação de itens centralizadas parcialmente. |
| Sidebar direita | Overlay SwiftUI + safeAreaInset + NSVisualEffectView | Composição própria com maior custo de coordenação do chrome. |
| Topbar | ToolbarContent SwiftUI + NSHostingView/medidas + caminhos específicos de background | Controles nativos/composição própria; exceções recentes devem ser preservadas. |
| Coleções | CollectionListingLayout/Item/Sorter | Reutilização boa; preparação de dados ainda desigual por página. |
| Faixas | NSTableView para Músicas/fila; linhas SwiftUI nas outras telas | Dois renderers úteis; modelos/comandos/estilos ainda podem ser compartilhados. |
| Artwork | ImageIO/AppKit + ArtworkRepository, base64/preview separados | Bom pipeline central para artwork do core; fontes alternativas fragmentadas. |
| Estado/core | DurvaldCoreStore MainActor/Observation + UniFFI + presentation de Músicas | Fachada ampla; cache e preparação fora da UI já existem em Músicas. |
| Integrações | FSEvents, MediaPlayer/Now Playing, NSWorkspace, importação de arquivos | Uso nativo real; não reimplementar sem uma necessidade concreta. |

## 1. Componentes sem controle ou estrutura nativa especializada

### N01 — Sidebar direita composta como overlay (P1)

**Evidência:** [ContentView.swift:121](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/ContentView.swift:121); [Features/Player/QueueView.swift:5](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueView.swift:5).

A esquerda usa NavigationSplitView; a direita usa overlay de largura fixa, reserva com safeAreaInset e NSVisualEffectView separado. É uma composição customizada de APIs nativas, sem um contêiner nativo de inspector/split para o painel.

**Consequência:** Geometria, largura útil, fundo, animação e topbar precisam ser coordenados manualmente. A regressão de legibilidade corrigida no commit de referência é evidência concreta desse acoplamento.

**Direção:** Avaliar inspector(isPresented:) ou um NSSplitViewController com item apropriado num protótipo isolado. O inspector não garante a mesma aparência da sidebar esquerda: preservar o visual aprovado é condição de adoção.

### N02 — Fundo e hover da topbar com infraestrutura própria (P1)

**Evidência:** [TopbarHoverObserver.swift:6](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/TopbarHoverObserver.swift:6); [ContentView.swift:738](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/ContentView.swift:738); [Features/Library/ArtistView.swift:4](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:4).

O fundo usa material nativo headerView, mas seu posicionamento pela contentLayoutRect e sua ativação são próprios. Há três caminhos: automático sem painel, backdrop explícito com painel e preferências próprias do artista.

**Consequência:** Não é um fundo desenhado com cor arbitrária. É uma exceção de integração nativa, atualmente necessária e validada; remove-la sem reproduzir o defeito reintroduz risco conhecido.

**Direção:** Encapsular numa política de chrome com testes de estado e geometria. Só substituir pelo compositor automático depois de comprovar equivalência com o painel aberto.

### N03 — Busca não usa um controle de pesquisa especializado (P1)

**Evidência:** [Features/Library/ToolbarSearchTextField.swift:4](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ToolbarSearchTextField.swift:4); [Features/Library/MusicLibraryToolbarControls.swift:56](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryToolbarControls.swift:56); [ContentView.swift:305](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/ContentView.swift:305).

O campo editável é NSTextField nativo, mas lupa, limpar, placeholder, vidro, expansão, foco e Escape são compostos manualmente. Não há NSSearchField ou NSSearchToolbarItem nesse caminho.

**Consequência:** Exige implementar e sincronizar recursos normalmente próprios do controle de busca. A diferença de fonte do placeholder global foi um exemplo recente de divergência.

**Direção:** Comparar NSSearchField/NSSearchToolbarItem com o requisito de busca que recolhe para um círculo; se incompatível, manter a composição e consolidar seu contrato num único componente.

### N04 — Seletores de abas das duas sidebars (P2)

**Evidência:** [Features/Navigation/LibrarySideBarView.swift:472](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/LibrarySideBarView.swift:472); [Features/Player/QueueView.swift:226](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueView.swift:226).

Ambos simulam segmented control com HStack, Buttons, Capsule e glassEffect. Não usam Picker segmented ou NSSegmentedControl.

**Consequência:** A seleção, a navegação por teclado e os estados de aparência são responsabilidade do app. Labels de acessibilidade já existem; equivalência funcional completa com segmented control precisa ser verificada.

**Direção:** Testar Picker(.segmented) como referência funcional. A largura variável da aba selecionada da esquerda pode justificar um componente próprio compartilhado com política de distribuição configurável.

### N05 — Sliders de progresso e volume desenhados pelo app (P2)

**Evidência:** [Features/Player/PlayerBar.swift:612](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlayerBar.swift:612).

Trilho, preenchimento, thumb, glow e arraste usam Shapes e DragGesture. O controle visual não é Slider/NSSlider; há accessibilityRepresentation com Slider e tratamento de teclado nos consumidores.

**Consequência:** Personalização legítima para a playerbar, com custo de manutenção de hit testing, valores, foco e término do gesto. Não classificar como ausência total de acessibilidade.

**Direção:** Preservar o visual e expor um contrato único de slider. Comparar eventos de edição/cancelamento com NSSlider; reutilizar a abstração somente onde a interação for equivalente.

### N06 — Navegação e seleção da sidebar esquerda (P2)

**Evidência:** [Features/Navigation/LibrarySideBarView.swift:355](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/LibrarySideBarView.swift:355); [Features/Navigation/LibrarySideBarView.swift:413](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/LibrarySideBarView.swift:413).

O contêiner é NavigationSplitView nativo, mas as linhas e a seleção usam Buttons e fundos próprios em vez de List(selection:) para toda a navegação.

**Consequência:** Visual consistente com o produto, mas foco, seleção e múltiplos modos devem continuar sendo coordenados manualmente.

**Direção:** Avaliar List com selection para a seção de navegação. Não forçar listas de cards a terem o mesmo renderer de linhas de navegação.

### N07 — Reordenação de faixas da playlist (P2)

**Evidência:** [Features/Playlists/PlaylistView.swift:10](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistView.swift:10); [Features/Player/QueueTableView.swift:106](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueTableView.swift:106).

Playlist usa DropDelegate e estado próprio; fila usa drag/drop de NSTableView. A playlist não usa diretamente onMove de List ou a infraestrutura da tabela.

**Consequência:** Duas implementações de índices de inserção, item arrastado e término do drop; o atraso de 0,2 s é uma sincronização manual.

**Direção:** Separar o cálculo de reordenação do renderer. Avaliar List/onMove ou tabela para playlists grandes sem comprometer o layout atual.

### N08 — Regras próprias de janela e botões de sistema (P2)

**Evidência:** [WindowTrafficLights.swift:94](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/WindowTrafficLights.swift:94); [WindowTrafficLights.swift:18](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/WindowTrafficLights.swift:18); [DurvaldApp.swift:56](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/DurvaldApp.swift:56).

Usa APIs nativas para ocultar traffic lights, fechar com monitor de Escape e restringir a janela de metadados em relação à janela principal. As políticas de posicionamento/zoom são próprias.

**Consequência:** Não são traffic lights falsos, mas uma alteração do comportamento padrão de janelas. Janelas pequenas, múltiplos monitores e foco exigem cobertura específica.

**Direção:** Concentrar numa política de apresentação e manter os comandos padrão sempre que compatíveis. Tratar as dimensões fixas dos sheets como decisões explícitas, não como norma global.

### N09 — Desenho customizado em componentes AppKit (P2)

**Evidência:** [Features/Library/MusicLibraryTableView.swift:934](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryTableView.swift:934); [Features/Library/MusicLibraryTableView.swift:440](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryTableView.swift:440); [Features/Library/MusicLibraryNativeControlCell.swift:4](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryNativeControlCell.swift:4).

A tabela, seleção, células e botões são AppKit, com subclasses e renderização própria de fundo/grupos/hover. Existe cor RGB fixa no grupo de álbum em dark mode.

**Consequência:** Usar AppKit não elimina divergências visuais: desenho de fundo e cor fixa podem descolar dos materiais e de outras telas.

**Direção:** Preferir cores semânticas quando viável e extrair tokens intencionais. Manter NSTableView e a atualização incremental já implementada.

### N10 — Animações e elementos visuais específicos do produto (P3)

**Evidência:** [Features/Player/PlayerMarqueeText.swift:4](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlayerMarqueeText.swift:4); [Features/Player/PlaybackActivityIndicator.swift:7](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlaybackActivityIndicator.swift:7); [Features/Player/SpectrumAnalyzerView.swift:3](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/SpectrumAnalyzerView.swift:3); [Features/Library/RatingControl.swift:11](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/RatingControl.swift:11).

Marquee, indicador por CALayer, espectro por Shapes e avaliação por estrelas são componentes próprios. Não há equivalente nativo obrigatório que reproduza todos esses requisitos.

**Consequência:** Customização não é defeito por si só. Marquee já respeita reduce motion/visibilidade; o indicador evita reiniciar animações existentes.

**Direção:** Preservar componentes especializados. Validar acessibilidade, energia e estados de janela em vez de substituir apenas por serem customizados.

## 2. Componentes e estruturas com trabalho ineficiente ou risco de custo

### E01 — Carregamento integral repetido do catálogo (P1)

**Evidência:** [Features/Library/AlbumsView.swift:114](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumsView.swift:114); [Features/Library/ArtistsView.swift:93](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistsView.swift:93); [Features/Library/MusicLibraryPresentation.swift:110](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryPresentation.swift:110); [CoreBridge/DurvaldCoreStore.swift:405](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift:405).

Há loops de páginas para coletar todos os lançamentos/faixas em Álbuns, Artistas, apresentação de Músicas e importação M3U8. Cada consumidor mantém suas próprias necessidades e parte de seus próprios arrays.

**Impacto e limite da conclusão:** Custo estrutural confirmado: leituras FFI e materialização podem se repetir por visita/revisão. Não há medição de tempo ou RAM neste levantamento.

**Direção:** Preferir agregações específicas no core para resumo/IDs locais e um repositório de catálogo compartilhado com invalidação por revisão. Não remover a paginação do store nem bloquear o primeiro frame pelo catálogo completo.

**Correção iniciada em 08/10/2026:** o store passou a manter caches compartilhados de faixas e lançamentos (`CatalogPageCache`), com uma carga paginada em segundo plano por entidade/revisão. Álbuns, Artistas, apresentação de Músicas e importação M3U8 usam esses snapshots. Cargas concorrentes são compartilhadas; cancelar uma tela não cancela a carga dos demais consumidores. Mudanças de metadados, atualização do catálogo e troca de core invalidam o cache; resultados de revisões antigas são descartados. As coleções visíveis continuam paginadas, e faixas já integralmente carregadas no store são reutilizadas sem nova consulta.

Esta etapa elimina os loops integrais independentes dos quatro consumidores. Agregações específicas no core e compartilhamento de leitura de tamanhos de arquivos continuam como oportunidades posteriores; não foram medidos tempo, RAM ou FPS. A cobertura em `CatalogRepositoryTests` verifica paginação completa, compartilhamento, invalidação, cancelamento, falhas e importação M3U8 com faixas de páginas posteriores. Na validação inicial, a suíte unitária passou com exclusão de dois testes existentes (restauração de scroll e ordem do menu de álbum), cujas falhas também foram reproduzidas numa cópia do commit anterior neste ambiente macOS 27.0.1. A investigação posterior confirmou expectativas desatualizadas: o cabeçalho nativo mede 28 pontos e o AppKit aplica esse inset no clip view, posicionando o topo em −28; o deslocamento salvo é relativo a esse topo, comportamento já implementado no commit `ba790f3`. O teste de scroll passou a usar a geometria nativa. O teste do menu foi atualizado para incluir “Avaliação” quando habilitada e verificar sua ausência quando desabilitada, restaurando a preferência ao terminar. Ambos passaram sem alteração no código de produção. A validação final executou os 81 testes unitários, sem exclusões, com zero falhas.

### E02 — Histórico recarrega e resolve dados em vários níveis (P1)

**Evidência:** [Features/Library/HistoryView.swift:69](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:69); [Features/Library/HistoryView.swift:102](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:102); [CoreBridge/DurvaldCoreStore.swift:1908](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift:1908).

Enquanto a tela está montada, HistoryView chama refreshHistory a cada segundo, busca playbackHistory completo quando store.history muda, e resolve faixas ausentes uma a uma durante busca.

**Impacto e limite da conclusão:** Amplifica consultas e recomputações. A renovação do store publica arrays e a task da tela usa o array como identidade; necessidade do polling deve ser medida, mas o caminho redundante está presente.

**Direção:** Atualização por evento/revisão, snapshot de histórico compartilhado, resolução em lote e dicionário de faixas. Preservar busca que alcança páginas antigas e histórico de faixas ainda não carregadas.

**Correção implementada em 08/10/2026:** `PlaybackHistoryRepository`, pertencente ao store, compartilha o histórico completo e seu índice de faixas entre visitas. A busca usa esse snapshot, incluindo registros antigos e faixas fora das páginas visíveis do catálogo. O core expõe `playback_history_revision`, mantida por triggers SQLite na mesma transação de inserções, atualizações e exclusões; exclusões por cascata também alteram a revisão. O loop de reconciliação de playback já existente verifica essa revisão depois que o histórico é solicitado, sem novo loop de polling na tela. A verificação lê um escalar; o histórico completo só é consultado quando sua revisão muda. A atualização roda numa tarefa separada para não atrasar o progresso do player.

Faixas ausentes são consultadas pela nova API `tracks_by_ids`, em lotes de até 200 IDs no cliente, com consultas SQL `IN` limitadas no core. O repositório reutiliza os IDs resolvidos, inclusive ausências, enquanto a revisão do catálogo não muda. Alterações de metadados renovam o índice sem reler o histórico. As linhas recebem faixas pelo índice, sem buscas lineares nem consultas individuais; tasks usam revisões e consulta, em vez de arrays completos. Cargas concorrentes são compartilhadas, cancelamentos de uma tela não cancelam os demais consumidores, e resultados de revisões antigas não substituem snapshots novos.

A cobertura em `PlaybackHistoryRepositoryTests` verifica busca em registros antigos, resolução em lote, revisões inalteradas, novos eventos e exclusões, metadados, faixas ausentes, concorrência, cancelamento, falhas e atualização automática sem troca de ID da faixa. Os testes Rust verificam revisão transacional, reabertura, rollback, cascatas e resolução por IDs. O bridge e a biblioteca embarcada foram regenerados; o script de geração agora mantém a fonte compilada pelo app sincronizada. Os 91 testes unitários macOS (incluindo dez novos testes de histórico) e o smoke test UniFFI passaram. Os três testes Rust dirigidos de paginação/revisão, conclusão de faixa e repetição também passaram. Na suíte Rust completa, 218 testes passaram, três foram ignorados e duas falhas existentes foram reproduzidas no commit anterior: `similar_artist_snapshot_materializes_targets_and_their_identities_atomically` e `legacy_rows_survive_migration_and_reopening`. Não foram medidos tempo, RAM ou FPS.

### E03 — Ordenação e índices refeitos no caminho de renderização (P1)

**Evidência:** [Features/Library/AlbumsView.swift:173](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumsView.swift:173); [Features/Library/ArtistsView.swift:71](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistsView.swift:71); [Features/Library/CollectionListing.swift:80](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/CollectionListing.swift:80); [Features/Library/HistoryView.swift:45](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:45).

Computed properties filtram, constroem Dictionary/Set e ordenam coleções. O comparador de artistas extrai máximos de lançamentos repetidamente dentro do sort.

**Impacto e limite da conclusão:** Trabalho O(n), O(n log n) e varreduras adicionais por comparação no caminho de atualização da UI. Frequência e tempo precisam de Instruments.

**Direção:** Preparar um snapshot por chave de revisão/consulta/ordem; pré-calcular recência/data/nota por artista. Usar MusicLibraryPresentation como referência, não executar um novo detached task em todo body.

**Correção implementada em 08/10/2026:** `PreparedLibraryListing` prepara snapshots fora do MainActor, acionados por chaves escalares de revisão do catálogo/coleções, consulta, filtros e ordem. Álbuns, Artistas, Histórico, Playlists e as coleções da sidebar renderizam os arrays preparados; filtros, índices e resumos não são reconstruídos em `body`. A mesma chave reutiliza o resultado concluído. Mudanças de chave cancelam o trabalho anterior e uma geração impede a publicação de resultados antigos, inclusive ao retornar à consulta já armazenada.

O store expõe revisões de lançamentos, artistas e playlists para invalidar esses snapshots sem comparar ou interpolar arrays completos. Os comparadores de artistas e playlists usam critérios pré-calculados antes da ordenação, preservando desempates e valores ausentes; a ordenação alfabética dispensa os cálculos de metadados. A apresentação de artistas também prepara o índice de artwork de fallback. Testes cobrem reutilização, invalidação, cancelamento, resultados atrasados, execução fora da thread principal, filtros, resumos, busca na sidebar e os seis modos de ordenação de artistas/playlists. O ganho em tempo e frequência ainda requer medição com Instruments.

### E04 — Lookups lineares em linhas e cards (P1)

**Evidência:** [Features/Library/HistoryView.swift:162](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:162); [Features/Library/ArtistsView.swift:137](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistsView.swift:137); [Features/Library/ArtistView.swift:2170](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:2170).

Linhas de histórico procuram a faixa no array do store; cards de artista procuram lançamento por artista; detalhes do artista buscam lançamento/faixa por título/ID em arrays.

**Impacto e limite da conclusão:** Cada lookup é linear; a combinação de muitas linhas com muitos dados pode multiplicar esse trabalho. Parte do artista já usa dicionários, portanto a oportunidade é localizada.

**Direção:** Índices por ID/artistID/releaseID preparados uma vez por revisão. Preservar as regras atuais de fallback de artwork e de títulos normalizados.

**Correção implementada em 08/10/2026:** o Histórico já recebe faixas pelo índice compartilhado de E02, e a lista principal de Artistas usa o índice de artwork preparado em E03. A sidebar agora também consulta esse índice, preservando a escolha do primeiro lançamento do artista, inclusive quando ele não possui artwork.

Nos detalhes do artista, `ArtistLookupSnapshot` prepara em segundo plano índices de faixas/lançamentos por ID, grupos externos por MusicBrainz ID e lançamento local, e durações por lançamento/título normalizado. Revisões escalares dos dados locais invalidam o snapshot; o mecanismo de E03 descarta resultados atrasados. Cards do último lançamento, ranking popular, links de artwork e fila de reprodução consultam esses índices. Identificadores repetidos mantêm o primeiro registro. O índice de títulos guarda a posição original para preservar a primeira correspondência entre todas as formas normalizadas: duração remota inválida usa o fallback local, que considera somente durações positivas. Testes cobrem essas precedências, normalização de pontuação/sufixos, ausência de dados, atualização de metadados e remoção de identificadores obsoletos. O store também mantém índices compartilhados das coleções carregadas por ID, sincronizados nas atribuições e edições dos arrays. Menus de faixas/álbuns, player, fila e detalhes do álbum usam esses índices; a revisão observável preserva as atualizações da UI e metadados otimistas. Testes verificam inicialização, substituição das coleções e edições de favorito/avaliação. Não houve medição com Instruments.

### E05 — Identidades de tasks com arrays completos (P1)

**Evidência:** [Features/Library/HistoryView.swift:20](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:20); [Features/Library/HistoryView.swift:69](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:69); [DurvaldApp.swift:60](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/DurvaldApp.swift:60).

History usa entries e store.history em chaves de task. A janela de edição usa lista de IDs como identidade; esse segundo caso pode ser apropriado e normalmente pequeno.

**Impacto e limite da conclusão:** No histórico grande, comparar coleções e reiniciar tarefas por payload custa mais que uma revisão escalar. Não declarar toda identidade-array como erro.

**Direção:** Introduzir historyRevision + chave de consulta/revisão; manter arrays como payload. MusicLibraryPresentation já documenta esse padrão.

**Correção implementada em 08/10/2026:** as tarefas do Histórico já usam identidade escalar do core, revisões de catálogo/faixas/histórico, consulta e ordem desde E02/E03; entries e índices são somente payload. A revisão dos demais consumidores encontrou e removeu o array de IDs da fila como chave de tarefa: `queueRevision` muda quando o snapshot da fila muda, enquanto atualizações de progresso/pausa mantêm a identidade. `QueueMenuTrackRequest` combina essa revisão com core e revisões de catálogo/faixas; `QueueMenuTrackPresentation` lê a fila dentro da tarefa, reutiliza metadados ao reordenar, remove registros fora da fila e invalida o cache na troca de fonte/metadados. Cancelamento e geração impedem a publicação de respostas antigas.

A tarefa de último lançamento do artista usa `discographyPageRevision`, incrementada na publicação da página, em vez de comparar `ArtistDiscographyPage` com todos os seus itens. A identidade da edição em lote (`.id(trackInfo.trackIDs)`) foi preservada: ela representa a seleção editada e reinicia corretamente o estado do formulário. Testes cobrem estabilidade durante progresso/pausa, mudanças da fila, reutilização após reordenação, metadados atualizados, troca de core, cancelamento e respostas atrasadas. Não houve medição com Instruments.

### E06 — Leitura e decodificação síncronas de arquivos em ações de UI (P1)

**Evidência:** [Features/Library/TrackInfoSheet.swift:336](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackInfoSheet.swift:336); [Features/Playlists/CreatePlaylistSheet.swift:152](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/CreatePlaylistSheet.swift:152); [CoreBridge/DurvaldCoreStore.swift:405](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift:405).

Callbacks de importação leem Data(contentsOf:) e criam NSImage; o store MainActor também lê M3U8 síncrono antes de chamadas async.

**Impacto e limite da conclusão:** Risco verificável de bloquear a UI com arquivos grandes ou volumes lentos. Tamanho/frequência reais não foram medidos.

**Direção:** Serviço de importação em executor de I/O, thumbnail ImageIO e publicação no MainActor. Manter o security scope aberto até o término da leitura; não presumir que async significa fora da thread principal.

**Correção implementada em 08/10/2026:** `FileImportService` executa leitura de arquivos, decodificação ImageIO, conversão base64, parsing M3U8 e resolução de symlinks em worker fora do MainActor. O worker abre o security scope e o fecha com `defer`, após terminar a leitura/uso dos bytes; o cancelamento do consumidor não encerra o acesso enquanto uma leitura síncrona ainda está em andamento. Verificações de cancelamento impedem a publicação do resultado e evitam decodificar uma leitura já cancelada.

TrackInfoSheet e CreatePlaylistSheet usam `ArtworkImportState`: mostram progresso, publicam a prévia no MainActor e descartam seleções antigas/canceladas. A prévia ImageIO aplica orientação e limita o maior lado a 1024 pixels na faixa e 512 na playlist; os bytes originais da playlist são preservados para salvar, sem substituir a imagem pela thumbnail. A capa existente da playlist também é decodificada de forma assíncrona, incluindo data URLs. O M3U8 mantém ordem, duplicatas, caminhos relativos e o primeiro registro do catálogo por caminho canônico; leitura e indexação de caminhos precedem a criação da playlist. Testes cobrem execução fora da thread principal, limite da prévia, bytes originais, scope em sucesso/erro/cancelamento, base64, parsing M3U8, symlinks e descarte de respostas antigas. Não houve medição com Instruments.

### E07 — Thumbnails de playlists sem cache compartilhado (P2)

**Evidência:** [Features/Playlists/PlaylistArtworkThumbnail.swift:52](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistArtworkThumbnail.swift:52); [Features/Player/ArtworkRepository.swift:53](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/ArtworkRepository.swift:53).

Cada PlaylistArtworkThumbnail decodifica seu base64 em task própria por request. Não passa pelo cache/deduplicação de ArtworkRepository.

**Impacto e limite da conclusão:** Boa prática existente: decode fora do MainActor e publicação protegida contra cancelamento. Ainda há repetição entre sidebar/listagem/detalhe e tamanhos próximos; o detached task não recebe cancelamento explícito.

**Direção:** Repositório de thumbnails com identidade da imagem, buckets de tamanho e compartilhamento de requests. Reutilizar infraestrutura, não fingir que a origem base64 é igual à artwork gerenciada pelo core.

**Correção implementada em 08/10/2026:** `PlaylistArtworkThumbnail` passou a usar `ArtworkRepository.shared` na sidebar, listagem e detalhes. Requests de playlists possuem uma origem própria, identificada por SHA-256 do conteúdo base64 e bucket de tamanho, independente dos IDs de artwork/core. O digest é calculado fora do MainActor, usando os bytes UTF-8 contíguos sem cópia quando disponíveis; o cache concluído guarda somente essa chave compacta e a thumbnail, sem reter o base64 original. Imagens iguais compartilham o resultado mesmo entre playlists diferentes; mudança do conteúdo usa outra chave.

São reutilizados os buckets de 64 a 1024 pixels, cache com limites de bytes/quantidade, gate de carga e controle de consumidores de ArtworkRepository. A decodificação usa ImageIO em worker por meio de FileImportService, incluindo orientação e data URLs; imagens inválidas recebem cache negativo limitado por quantidade. O cancelamento de um consumidor não interrompe os restantes; o último cancela a carga e resultados cancelados ou de cargas antigas não entram no cache. A view limpa a prévia ao mudar o request e só publica resultados do consumidor ativo. Testes cobrem reutilização, concorrência, cancelamento parcial/total, substituição de carga, limites, imagem inválida e separação entre fontes de playlist/core. Não houve medição com Instruments.

### E08 — Cache de artwork e gate serial com operações lineares (P2)

**Evidência:** [Features/Player/ArtworkRepository.swift:4](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/ArtworkRepository.swift:4); [Features/Player/ArtworkRepository.swift:191](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/ArtworkRepository.swift:191).

LRU usa array removeAll/removeFirst em hits/evicções; gate usa fila de continuations e removeFirst. Um carregamento completo por vez limita memória de bytes originais.

**Impacto e limite da conclusão:** O(n) confirmado, mas n do cache é limitado a 600 e o orçamento a 64 MiB. A serialização é uma proteção deliberada, não um erro a remover indiscriminadamente.

**Direção:** Medir fila/latência antes de mudar; avaliar deque/LRU O(1) ou NSCache com controle adicional. NSCache tem limites de evicção diferentes: não substitui automaticamente o orçamento estrito atual.

**Correção implementada em 08/10/2026:** o LRU de ArtworkRepository usa `CostLimitedLRU` com uma lista encadeada indexada por chave (`OrderedKeyedQueue`), substituindo as varreduras/deslocamentos do array em hits, promoção e remoção. Essas operações têm custo médio O(1); uma inserção ainda pode remover vários registros para respeitar o orçamento. Os limites estritos de bytes/quantidade, cache negativo, substituição de entradas e rejeição de imagens maiores que o orçamento foram preservados. A evicção ocorre antes da soma dos custos, evitando overflow inclusive com orçamento Int.max.

O gate mantém uma carga completa por vez e FIFO. Sua fila usa `CircularFIFO`, com retirada O(1) e inserção O(1) amortizada no crescimento do buffer; slots consumidos são zerados para liberar as capturas das continuations. Os testes cobrem recência/evicção, substituição, orçamento estrito, custo zero, contabilidade no limite inteiro, crescimento/wrap/reuso da fila, liberação de referências e exclusão serial/FIFO. A suíte de compartilhamento/cancelamento das thumbnails também passou.

**Medição sintética em 08/10/2026:** microbenchmark Swift compilado com `-O`, chaves/valores Int, mediana de cinco execuções. Com 600 entradas e 50.000 hits, o LRU anterior levou 15,89 ms e o novo 11,68 ms. Esvaziar FIFO de 6.000 itens levou 1,25 ms com removeFirst e 0,29 ms com o buffer circular; para 600 itens, 0,013 ms e 0,031 ms, respectivamente, mostrando o overhead da estrutura em filas pequenas. Esses números isolam as estruturas, não incluem I/O/decodificação nem demonstram ganho de latência nas telas; isso ainda requer Instruments. A medição descartou o uso da lista indexada no gate em favor do buffer circular.

### E09 — Polling de hover da topbar (P2)

**Evidência:** [TopbarHoverObserver.swift:90](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/TopbarHoverObserver.swift:90).

Observer lê ponteiro e geometria a cada 100 ms enquanto anexado à janela, inclusive sem alteração de hover. Há cleanup do timer quando muda de janela/deinit.

**Impacto e limite da conclusão:** Até 10 leituras por segundo por observer; dispatch adicional ao MainActor. Custo de energia é hipótese para medição, não vazamento confirmado.

**Direção:** Avaliar NSTrackingArea em uma região real da topbar ou monitor compartilhado por janela. Resolver o recorte da região antes de remover o polling que atualmente evita interceptar os botões nativos.

**Correção implementada em 08/10/2026:** TopbarHoverObserver substitui o timer de 100 ms por NSTrackingArea instalada no frame nativo da janela. A faixa acima de contentLayoutRect é recortada horizontalmente à largura da página, excluindo sidebar/fila e evitando que o recorte do próprio observer elimine a região da titlebar. Nenhuma view de captura é adicionada; hitTest continua retornando nil para preservar os controles nativos.

Entrada, saída, movimento/drag do mouse e mudanças de layout, janela ou ativação da aplicação atualizam o hover. A área só é recriada quando host/retângulo mudam, e as áreas/notificações são removidas ao desmontar, trocar/fechar a janela ou desalocar o observer. Publicações do binding são adiadas e invalidadas por revisão para evitar writes durante layout e atualizações antigas após mudanças de estado. Os testes cobrem geometria, estados inativos/ocultos/minimizados, resize, cleanup e hit-test do botão nativo de fechar. A remoção das leituras periódicas foi verificada no código; o ganho de energia ainda não foi medido com Instruments.

**Validação em 08/10/2026:** build e 149 testes unitários passaram, incluindo sete testes novos de TopbarHoverObserver. O teste visual testScrollEffectAcrossLibraryAndQueue não encontrou a janela principal antes de executar as interações. A mesma falha ocorreu com o observer anterior compilado a partir de HEAD; portanto, essa execução não validou visualmente o hover/scroll da implementação nova.

### E10 — Layout síncrono forçado na toolbar (P2)

**Evidência:** [ContentView.swift:877](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/ContentView.swift:877); [ContentView.swift:919](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/ContentView.swift:919).

Host chama layoutHostedContent em frame, bounds e layout, que força layoutSubtreeIfNeeded. Observer de largura é coalescido e ignora live resize.

**Impacto e limite da conclusão:** Potencial de múltiplas passagens; há uma justificativa explícita para evitar frame antigo e glitches. Não se comprovou que este custo supera o benefício.

**Direção:** Medir Long Platform View Updates durante resize. Guardar por mudança efetiva/tamanho se equivalente, preservando o canvas síncrono no instante de transição da busca.

**Correção implementada em 08/10/2026:** LibraryToolbarHostingView força layoutSubtreeIfNeeded somente quando o frame do NSHostingView difere dos bounds do host, incluindo tamanho e origem. Chamadas redundantes de setFrameSize, setBoundsSize e layout deixam de forçar uma nova passagem. Mudanças reais continuam ajustando e fazendo layout do canvas antes de retornar, preservando a sincronização necessária nas transições compacta/expandida. A atualização de rootView e o layout normal de conteúdo invalidado no mesmo tamanho foram preservados; a negociação de largura e seu observer não foram alterados.

Quatro testes novos usam um NSHostingView instrumentado para observar as passagens e a geometria efetiva. Após o primeiro layout, 300 chamadas com a mesma geometria não forçam nenhuma passagem adicional; uma sequência de 100 larguras diferentes com chamadas redundantes de bounds/layout força exatamente 100 passagens. Os testes também cobrem transições entre larguras compacta/expandida, alteração da origem dos bounds e conteúdo invalidado sem resize. Esses resultados verificam a eliminação do trabalho redundante no host, não medem latência da interface nem Long Platform View Updates; o perfil com Instruments continua pendente.

**Validação em 08/10/2026:** build e 153 testes unitários passaram. Os testes de interface testLibraryToolbarKeepsSizeAndSearchFocusAcrossNativeWindowResizes e testLibraryToolbarKeepsControlSizesWhenPanelsToggle falharam ao aguardar a janela principal, antes das interações com a toolbar. A falha de inicialização já havia sido reproduzida na validação do E09 com o observer anterior; resize/foco na interface real ainda não foram validados nesta execução.

### E11 — Cálculo de cor média e composição do header do artista (P2)

**Evidência:** [Features/Library/ArtistView.swift:375](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:375); [Features/Library/ArtistView.swift:2281](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:2281).

Imagem nítida e imagem desfocada usam ArtworkView; callback calcula cor média criando CIContext em cada cálculo. O cache de imagem evita concluir que sempre há dois decodes.

**Impacto e limite da conclusão:** Contexto/render de Core Image e blur de área grande são custos possíveis de CPU/GPU. Não há perfil de GPU nesta análise.

**Direção:** Cache da cor média por artwork/revisão e contexto reutilizável; considerar worker para cálculo. Preservar enquadramento, transição gradual e altura do header aprovado.

**Correção implementada em 08/10/2026:** ArtworkColorRepository calcula a cor em um actor fora do MainActor, com CIContext criado sob demanda e reutilizado. O LRU guarda até 256 resultados escalares, incluindo resultados ausentes, por core, artworkID e bucket de pixels. Os IDs dos arquivos gerenciados incorporam o hash do conteúdo (artwork.rs); substituir a imagem produz outra identidade. A serialização do cálculo e o cache evitam cálculos concorrentes duplicados para a mesma chave, sem reter as imagens no cache de cores.

ArtworkView só solicita a cor quando há callback interessado; publica a imagem antes de aguardar a amostra e verifica cancelamento antes de publicar a cor, impedindo callbacks antigos em views recicladas. Ausência de imagem/cor limpa a tonalidade anterior. ArtistView recebe a cor pronta e mantém a animação easeInOut de 0,45 s. Foram preservados a amostra dos 35% inferiores, sRGB/alpha opaco, proporção 1,4, alinhamento superior, altura, blur de raio 30 e gradientes da composição. As duas camadas continuam compartilhando thumbnail e cargas por ArtworkRepository; não se acrescentou outra decodificação nem se alterou o efeito visual para presumir ganho de GPU.

**Validação em 08/10/2026:** build e 160 testes unitários passaram. Sete testes novos cobrem a cor real/recorte inferior, cache/evicção, identidade por artwork/core/bucket, resultados ausentes, requisições concorrentes e cancelamento. O teste concorrente verifica uma única execução fora da thread principal para 20 consumidores. Não foi realizado perfil de CPU/GPU com Instruments; a validação visual permanece limitada pela falha de inicialização da janela dos fixtures registrada em E09/E10.

### E12 — Espectro com polling de 50 ms (P2)

**Evidência:** [Features/Player/SpectrumAnalyzerView.swift:48](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/SpectrumAnalyzerView.swift:48); [Features/Player/PlayerMarqueeText.swift:20](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlayerMarqueeText.swift:20).

Espectro atualiza até cerca de 20 vezes/s enquanto montado, com animação de 80 ms. Reduce motion remove a animação, mas não muda esse polling; não há guard de scenePhase nessa view.

**Impacto e limite da conclusão:** Tráfego FFI e atualização frequente são confirmados. Marquee já limita a 15 fps e pausa por cena/visibilidade: não agrupar os dois como igualmente ineficientes.

**Direção:** Pausar aquisição quando cena inativa/sem reprodução e usar um stream ou cadence apropriada se houver suporte no core. Medir impacto antes de redesenhar em Canvas.

**Correção implementada em 08/10/2026:** SpectrumAnalyzerView só registra aquisição com core disponível, cena ativa, view apresentada (onAppear/onDisappear) e reprodução em andamento. A chave da task usa identidade do core e flags escalares; DurvaldCoreStore expõe isPlaybackPlaying, atualizado apenas quando o estado muda, evitando observar o snapshot completo a cada avanço do relógio. Em estado inativo as bandas são zeradas e não há novas consultas de espectro. Resultados idênticos deixam de provocar atualização/animação de estado.

SpectrumPollingCoordinator compartilha um loop por core entre consumidores do store. O mesmo worker serializa ativação, leitura e desativação: sair um consumidor não desliga os demais; o último a sair desativa o analisador após concluir a operação/espera corrente. Uma nova inscrição durante a desativação é reconciliada pelo mesmo worker, evitando que o cleanup antigo desligue a nova sessão. Leituras que terminam sem consumidores não são publicadas nem seguidas por outra leitura. Fora de uma sessão não fica timer/loop ocioso; durante reprodução ativa foi mantida a espera de 50 ms e a animação de 80 ms. Reduce Motion continua eliminando a animação e sua mudança atualiza a task.

Cada task da view identifica sua sessão para recusar callbacks de uma inscrição anterior após reiniciar/desaparecer. O core expõe apenas set_spectrum_enabled e spectrum_snapshot, sem stream de espectro; a desativação interrompe a coleta e limpa a fila do analisador no transport. Não houve alteração de FFI, callback de áudio ou renderização em Canvas.

**Validação em 08/10/2026:** build e 166 testes unitários passaram. Seis testes novos cobrem elegibilidade, estado inicial/pausa/resume, compartilhamento de leituras, cancelamento antes/durante aquisição e substituição durante uma desativação suspensa. O componente não tem callsite de montagem nas telas atuais; os testes exercitam a política/coordenador diretamente, sem demonstrar ganho de energia na aplicação. Perfil com Instruments e validação visual permanecem pendentes.

### E13 — Fila dá reloadData completo e procura seção por linha (P2)

**Evidência:** [Features/Player/QueueTableView.swift:96](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueTableView.swift:96); [Features/Player/QueueTableView.swift:133](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueTableView.swift:133).

Mudança de rows ou janela ativa recarrega a tabela inteira. heightOfRow/viewFor consultam firstIndex para achar a primeira faixa futura.

**Impacto e limite da conclusão:** Recarga total e buscas lineares confirmadas; relevância depende do tamanho típico da fila. NSTableView já reutiliza células.

**Direção:** Pré-calcular índice de seção e aplicar diferenças quando justificadas; atualizar somente aparência no foco. Usar a lógica incremental de MusicLibraryTableView como referência, sem copiar seu agrupamento.

**Correção implementada em 08/10/2026:** o coordenador prepara firstUpcomingRow e os índices de linhas atuais quando rows muda. heightOfRow, viewFor e feedback de drop passam a consultar o índice preparado, sem varredura por linha. Pausa, metadata, posições e flags de seção usam reloadData(forRowIndexes:columnIndexes:) apenas nas linhas alteradas. Mudanças efetivas de altura notificam noteHeightOfRows, incluindo o vizinho que ganha/perde o header. Troca de core atualiza as células para invalidar artwork da origem anterior; snapshots equivalentes não alteram a tabela.

Mudança de foco modifica somente a cor do título das células atuais já materializadas, sem recriação, atualização de altura ou nova carga de artwork. Mudanças de quantidade/sequência de trackIDs ainda usam reloadData estrutural: não foi introduzido diff por identificador presumidamente único, pois a fila pode repetir a mesma faixa e posições são renumeradas. O drag existente continua usando moveRow, mas agora atualiza os headers, alturas e tags dos botões no intervalo movido. O eco do core que apenas renumera posições recebe atualização parcial, preservando a tabela.

**Validação em 08/10/2026:** build e 173 testes unitários passaram. Sete testes novos cobrem atualização de pausa/metadata, foco sem reload/recriação, seções/alturas, duplicatas, fallback estrutural, troca de core e movimento com eco renumerado. Uma NSTableView real com 100 linhas também verifica seleção/scroll preservados em metadata/foco e alturas recalculadas após movimento/troca de flags de seção. Não há medição de latência com fila grande ou Instruments nesta alteração.

### E14 — Ordenação de sugestões repete normalização de strings (P2)

**Evidência:** [Features/Playlists/PlaylistMusicPicker.swift:133](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistMusicPicker.swift:133); [Features/Playlists/PlaylistMusicPicker.swift:141](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistMusicPicker.swift:141).

Ordena todos os resultados antes de prefix(10); o comparador recalcula folding do título e da consulta. A computed property é lida também por linhas/divisores.

**Impacto e limite da conclusão:** Trabalho evitável mesmo que o core limite os resultados. Escala máxima e impacto não foram medidos.

**Direção:** Preparar rank/chave normalizada uma vez por consulta e payload; guardar dez resultados ordenados num snapshot.

**Correção implementada em 08/10/2026:** PlaylistSuggestionSnapshot prepara as sugestões uma vez ao concluir cada busca. O folding da consulta acontece uma vez e o de cada título uma vez, com o mesmo locale. Rank e título normalizado são calculados antes da comparação. Em vez de ordenar todo o payload, a preparação mantém os dez melhores candidatos em uma lista ordenada de no máximo onze itens durante a inserção, com trabalho O(n × 10) e memória auxiliar limitada. Empates preservam a ordem de entrada: faixas, álbuns e artistas. Os IDs, títulos originais e prioridade exata/prefixo/demais resultados foram preservados.

PlaylistMusicPicker prepara o snapshot fora do MainActor e publica somente após verificar o cancelamento da busca. Renderização, linhas e divisores leem o array armazenado; não há mais ordenação/folding em computed property nem retenção do payload completo em state. Limpar/fechar a busca limpa o snapshot. Cinco testes novos verificam prioridade, acentos/case, empates/IDs entre tipos, limite de dez, substituição de consulta/payload e normalização única. A seleção limitada é comparada à ordenação completa anterior com 600 candidatos, seis consultas e três locales. Não foi medida latência da tela com Instruments.

**Validação em 08/10/2026:** build e 178 testes unitários passaram, incluindo os cinco testes novos de PlaylistSuggestionSnapshot.

### E15 — Estatísticas de tamanho de arquivos reexecutadas por consumidores (P2)

**Evidência:** [Features/Library/MusicLibrarySummary.swift:78](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibrarySummary.swift:78); [Features/Library/AlbumsView.swift:144](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumsView.swift:144); [Features/Library/MusicLibraryPresentation.swift:145](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryPresentation.swift:145).

A mesma leitura de atributos percorre paths únicos em detached task por consumidor. A implementação tem cancelamento e não bloqueia diretamente o MainActor.

**Impacto e limite da conclusão:** Custo de I/O duplicável; cache em MusicLibraryPresentation não é compartilhado com Álbuns.

**Direção:** Repositório de metadados de arquivo com invalidação por evento/revisão e agregações por coleção. Não manter tamanhos para sempre sem atualização quando o arquivo muda.

**Correção implementada em 08/10/2026:** FileMetadataRepository, compartilhado pelos consumidores do DurvaldCoreStore, lê atributos em um actor fora do MainActor. Paths repetidos e coleções sobrepostas reutilizam as leituras concluídas da mesma revisão, incluindo o marcador -1 para arquivos indisponíveis. O cache LRU é limitado a 50.000 paths; entradas expiradas ou evictadas são relidas. Mudança de libraryCatalogRevision descarta o cache anterior, cobrindo invalidações do catálogo/metadata, scans e os scans acionados por FSEvents. Requisições de revisão anterior são recusadas e o store verifica novamente a revisão antes de entregar o resultado.

Entradas expiram após 30 s pelo relógio monotônico, inclusive resultados ausentes, e são atualizadas na próxima solicitação; não há timer novo nem promessa de refresh periódico de arquivos fora dos roots monitorados. Músicas, Álbuns e busca passam pelo mesmo repositório. Reabrir Músicas consulta metadados novamente, aproveitando entradas válidas ou renovando as expiradas, sem recarregar o catálogo nem aumentar catalogVersion. A busca consulta os paths apresentados em vez de confiar indefinidamente no dicionário local. As agregações continuam nos resumos/snapshots de coleção já existentes, preservando a contagem única de paths e o tamanho desconhecido quando qualquer arquivo falta.

Cancelamento é verificado entre paths e após cada stat; cancelar um consumidor não cancela os demais. Oito testes novos cobrem compartilhamento concorrente e thread de leitura, expiração com arquivos reais criados/modificados/removidos, LRU limitado, revisão antiga, cancelamento durante leitura, invalidação durante leitura e atualização do resumo sem recarga do catálogo. Validação: build e suíte DurvaldTests aprovados, com 186 testes e nenhuma falha (CODE_SIGNING_ALLOWED=NO). Não foi medido ganho de latência em volume lento ou com Instruments.

### E16 — Polling e estados de settings (P3)

**Evidência:** [CoreBridge/DurvaldCoreStore.swift:1970](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift:1970); [Features/Settings/EqualizerSettingsView.swift:97](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/EqualizerSettingsView.swift:97); [Features/LastFM/LastFMViewModel.swift:6](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/LastFM/LastFMViewModel.swift:6).

Áudio é consultado a cada 2 s no store; equalizador consulta métricas a cada 1 s na view. Last.fm usa ObservableObject enquanto o store/presentation usam Observation.

**Impacto e limite da conclusão:** São mecanismos existentes, não necessariamente gargalos. A publicação de settings pode reaplicar rascunhos de edição nas views; investigar se dados não editados são publicados durante uma edição.

**Direção:** Auditar mudança efetiva antes de publicar e separar draft de snapshot remoto. Avaliar eventos de dispositivo no core antes de substituir polling; migrar Last.fm só se simplificar ou reduzir updates medidos.

**Correção implementada em 08/10/2026:** O store compara Settings, AudioOutputState e EqualizerMetrics antes de atribuir os snapshots observáveis. Falha ao consultar settings não apaga o último snapshot válido; respostas dos refreshes e do polling de áudio/métricas canceladas ou de um core substituído não são publicadas. Geral e Equalizador usam SettingsDraft com valor editável separado do último snapshot remoto: seções sem edição pendente acompanham o remoto, enquanto uma seção com edição pendente mantém seu rascunho. O reconhecimento do valor salvo limpa o rascunho apenas quando ele coincide com o snapshot, preservando alterações feitas durante o salvamento. Cada seção observa apenas seus próprios valores; aliases antigos de presets são normalizados antes da comparação, sem alterar as curvas.

O seletor de áudio envia comandos exclusivamente pelo setter do Binding, sem disparar ações ao sincronizar o snapshot. Uma escolha pendente sobrevive aos snapshots de polling; o controle fica desabilitado durante a aplicação, e uma falha restaura a preferência confirmada. As métricas mantêm a cadência de 1 s apenas enquanto a aba Equalizador está selecionada e a cena está ativa, com cancelamento da task ao sair dessa condição.

O polling de saída de 2 s permanece: a interface UniFFI atual não expõe eventos de dispositivos, e audio_output_state em application/settings.rs também chama reconcile_output_device para recuperar a saída preferida ou aplicar fallback. Remover essa consulta exigiria mudar o contrato do core. Last.fm permanece com ObservableObject: os campos editáveis já são separados do status, e não houve evidência medida que justificasse a migração. Não foi medido ganho com Instruments nem validada reconexão de hardware físico nesta implementação.

Validação: build e suíte DurvaldTests aprovados, com 195 testes e nenhuma falha (CODE_SIGNING_ALLOWED=NO). Nove testes novos cobrem rascunhos por seção, snapshots externos, edição durante salvamento, aliases de presets, seleção de áudio pendente/rollback, notificações de Observation, falhas de consulta/salvamento e cancelamento de métricas em voo. A condição de ativação da task de métricas foi compilada, sem nova validação visual automatizada da troca de abas.

## 3. Implementações múltiplas e oportunidades de reutilização

### R01 — Família de campos de busca (P1)

**Ocorrências:** [ContentView.swift:305](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/ContentView.swift:305); [Features/Library/MusicLibraryToolbarControls.swift:56](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryToolbarControls.swift:56); [Features/Navigation/LibrarySideBarView.swift:557](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/LibrarySideBarView.swift:557); [Features/Playlists/PlaylistMusicPicker.swift:5](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistMusicPicker.swift:5); [Features/Library/AlbumView.swift:274](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumView.swift:274); [Features/Playlists/PlaylistView.swift:274](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistView.swift:274).

Existem busca global, busca compactável de coleção/artista, busca da sidebar, busca de playlist picker e filtros de álbum/playlist. Placeholder, foco, limpar, altura e backgrounds diferem por implementação.

**Contrato de reutilização sugerido:** Extrair SearchFieldStyle/placeholder/clear/focus policy, com modos toolbar, inline e compactável. Global ainda duplica o overlay do placeholder: foi padronizado visualmente, mas não por componente.

**Implementação em 08/10/2026:** Features/Search/SearchField.swift concentra SearchFieldStyle, ícone, padding/altura, backgrounds e acessórios de limpar/fechar. ToolbarSearchField reutiliza o editor AppKit existente e um único overlay de placeholder, compartilhado pela busca global e pelo LibraryToolbarSearchField compactável (coleções e artista). InlineSearchField usa TextField/FocusState para sidebar, filtros de álbum/playlist e picker de músicas. Os estilos preservam toolbar de 36 pt com glass interativo, sidebar de 32 pt com glass, filtros de 147 × 36 pt e background discreto, e picker de 36 pt com background quaternário; dimensões externas continuam no consumidor.

Limpar em uma toolbar zera o Binding e envia um novo pedido de foco, permitindo que o editor ativo receba o texto vazio sem perder o mecanismo que protege cursor/seleção durante atualizações de resultados. A busca global e a sidebar reservam o espaço do botão de limpar; coleções/artista só o exibem com texto. Filtros de álbum/playlist mantêm ausência de botão, e o picker mantém o botão de fechar sempre disponível. IDs de acessibilidade existentes são preservados, inclusive os IDs usados diretamente como container nos filtros e como campo no picker. Escape permanece definido pelo consumidor: toolbar sai do foco sem apagar texto; filtros limpam e saem do foco; sidebar limpa ou recolhe quando vazia; picker fecha. O modo compacto mantém a remoção física do editor nativo enquanto recolhido e a reserva da largura enquanto houver foco.

Validação: build e suíte DurvaldTests aprovados, com 202 testes e nenhuma falha (CODE_SIGNING_ALLOWED=NO). Sete testes novos usam NSTextField/NSWindow e NSHostingView para verificar foco pendente até anexar à janela, preservação de cursor, Escape nativo, atualização de Binding, limpeza do editor ativo, ausência/presença do editor em modo compacto e label/placeholder/altura da toolbar. O xcresult registrou um aviso interno de inversão de QoS nos testes de hosting; não foi medido impacto no aplicativo. Os fluxos completos de sidebar/picker/filtros não receberam nova validação visual ou de UI automatizada nesta implementação.

### R02 — Política de topbar, safe area e largura disponível (P1)

**Ocorrências:** [ContentView.swift:113](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/ContentView.swift:113); [TopbarHoverObserver.swift:6](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/TopbarHoverObserver.swift:6); [Features/Library/ArtistView.swift:130](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:130); [Features/Navigation/ContentShellState.swift:14](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/ContentShellState.swift:14).

Visibilidade, hover, offset, largura útil, material e insets são coordenados por arquivos diferentes; ArtistView mede frames globais e trata o header separadamente.

**Contrato de reutilização sugerido:** Um PageChromePolicy e um contrato de viewport/insets compartilhado, com exceções explícitas do artista. Evitar nova API única que imponha espelhamento ou header expandido à direita.

**Implementação em 08/10/2026:** PageChromePolicy concentra a política de material/hover, o limiar de scroll (> 1 pt), as reservas da fila e o deslocamento da pesquisa global. Páginas comuns mantêm material automático sem fila; com fila usam material nativo limitado à página e desabilitam o automático. O artista mantém sua exceção: topo oculto, hover visível e scroll com material automático, além das regras explícitas de safe area para viewport vertical e canvas horizontal. O estado de navegação/restauração de scroll continua no shell, e o hover continua com tracking nativo sem polling.

PageViewport descreve os frames visível e de canvas no mesmo espaço de coordenadas, deriva os insets laterais e distingue largura medida, largura visível e expansão horizontal. ArtistView usa esse contrato no header, highlights, discografia e footer: artwork expande somente à esquerda; título/controles permanecem centrados na coluna visível; scrollers abrangem os insets dos dois lados. Insets são limitados a valores não negativos, preservando a largura visível durante frames transitórios de resize. Não há espelhamento nem expansão do artwork sobre o painel direito. O shell distingue a medida da coluna antes da reserva da fila da medida total depois dela, usando fallback com reserva apenas quando a medida total ainda não existe.

PageToolbarLayout concentra mínimo/preferência do host, extrapolação de medidas nativas por resize, reservas dos painéis e distribuição entre resumo/pesquisa/menus. Compactness usa a largura realmente atribuída pelo AppKit, mantendo as medidas independentes por configuração da sidebar. A preferência de background passa a PageToolbarBackgroundPreferenceKey. PageTopbarBackground e TopbarHoverObserver passam a usar a mesma região nativa da titlebar, recortada horizontalmente à página, para alinhar material e hover sem cobrir sidebar/fila ou bloquear hit testing.

Validação: build e suíte DurvaldTests aprovados, com 212 testes e nenhuma falha (CODE_SIGNING_ALLOWED=NO). Dez testes novos cobrem combinações de scroll/hover/fila, safe areas do artista, insets assimétricos e frames transitórios, fallback de medidas sem dupla reserva, limites de compactness e extrapolação por resize/sidebar. Um teste com NSWindow verifica coincidência entre material e tracking, bounds do overlay e ausência de hit testing após resize; a suíte específica foi reexecutada com essa asserção adicional e passou. Permanece o aviso interno de QoS em SearchFieldTests registrado no R01. Não foi feita nova validação visual completa das telas ou medição com Instruments.

### R03 — Tabelas e linhas de faixas (P1)

**Ocorrências:** [Features/Library/MusicLibraryTableView.swift:80](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryTableView.swift:80); [Features/Player/QueueTableView.swift:15](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueTableView.swift:15); [Features/Library/AlbumView.swift:488](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumView.swift:488); [Features/Playlists/PlaylistView.swift:552](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistView.swift:552); [Features/Library/ArtistView.swift:2299](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:2299); [Features/Library/HistoryView.swift:155](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:155).

Músicas e fila usam tabelas AppKit; álbum, playlist, popular ranking, histórico e pesquisa compõem linhas SwiftUI diferentes. Parte dos trailing controls já é compartilhada.

**Contrato de reutilização sugerido:** Compartilhar TrackRowModel, artwork/title/meta, regras de favorito/rating e comandos, mantendo renderers AppKit/SwiftUI diferentes quando necessários para performance e interação.

**Implementação em 08/10/2026:** TrackRowModel concentra o payload de apresentação (identidade local opcional, título, artista, álbum, artwork, duração, favorito e avaliação), labels de acessibilidade/fila/favorito e formatação de duração. A formatação preserva arredondamento a segundos, zero nas linhas locais e duração desconhecida no ranking externo, além de tratar valores não finitos/fora do intervalo sem conversão inválida. TrackRowText compartilha título/subtítulo entre álbum, playlist, histórico, pesquisa e ranking do artista, mantendo subtítulos específicos, spacing/line limits, links externos e destaque de faixa ativa. O destaque continua observando activeTrackID no componente da linha; playlists mantêm override por ocorrência e cor inativa própria. ArtworkView continua sendo o renderer compartilhado de capas, com dimensões e ação de abrir álbum definidas pelo consumidor.

MusicLibraryTableView e QueueTableView consomem o mesmo payload/labels mantendo células AppKit nativas, seleção, reuse, drag, menus e atualizações incrementais. O modelo não é usado como identidade de linha: posições de playlist/fila e IDs de reprodução do histórico continuam separados do ID da faixa. TrackRowPlayback centraliza dispatch de reprodução avulsa, álbum a partir da faixa e playlist a partir da posição; menus e duplo clique dos consumidores usam o mesmo destino, preservando faixas repetidas e contexto da coleção. As ações específicas da fila continuam nos seus callbacks por posição.

Os controles existentes recebem favorito/avaliação do payload e compartilham texto de duração e labels, mantendo visibilidade de avaliações, estado otimista e callbacks locais. Reducers/rollback da edição pessoal ficam para R04; esta extração não substitui os renderers nem a política de erro dessa edição. Não foi feita nova validação visual completa das linhas ou medição com Instruments.

Validação: build e suíte DurvaldTests aprovados, com 221 testes e nenhuma falha (CODE_SIGNING_ALLOWED=NO). Nove testes novos cobrem snapshot de metadados pessoais, identidade local ausente/externa, labels sem artista vazio, duração local/remota e valores inválidos, ocorrências repetidas na fila, reprodução avulsa sem substituição por coleção, álbum ordenado a partir da faixa, playlist a partir da ocorrência correta e posição inválida sem alteração da fila. Os testes existentes de tabelas nativas, seleção, scroll e atualizações incrementais também passaram. Permanece o aviso interno de QoS em SearchFieldTests registrado no R01.

### R04 — Avaliação e favorito em renderers diferentes (P1)

**Ocorrências:** [Features/Library/RatingControl.swift:11](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/RatingControl.swift:11); [Features/Library/MusicLibraryNativeControlCell.swift:4](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryNativeControlCell.swift:4); [Features/Library/TrackContextMenu.swift:83](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackContextMenu.swift:83); [Features/Player/PlayerBar.swift:195](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlayerBar.swift:195).

Estrelas e toggles têm labels e callbacks próprios em SwiftUI/AppKit/player. Trailing controls e células mantêm estado otimista local; o player delega a mutação ao store. A célula nativa foi otimizada para reuse e deve continuar nativa.

**Contrato de reutilização sugerido:** Compartilhar reducer/comando de edição, fallback após erro e semântica de acessibilidade, mantendo apresentações especializadas. Testar o toggle de limpar rating e rollback de favorito em cada renderer.

**Implementação em 08/10/2026:** PersonalValueEdit compartilha valor confirmado, valor visível e tickets de edição entre RatingControl, TrackListTrailingControls e MusicLibraryNativeControlCell. O reducer preserva a edição mais recente, restaura o último valor confirmado após erro, ignora conclusões de uma identidade anterior e não desfaz uma confirmação por receber novamente o mesmo snapshot antigo. RatingControl recebe uma identidade explícita de faixa/álbum para invalidar tickets quando o componente é reutilizado. PersonalValueLabels compartilha a regra de clicar novamente na nota para limpar, valores/labels de avaliação e semântica de favorito entre SwiftUI, AppKit e player. Células nativas mantêm botões AppKit, dimensões, hover, tint de seleção e reuse.

O store usa PersonalWriteQueue por entidade/propriedade e executa confirmação/rollback dentro da gravação serializada, evitando que uma falha antiga apague uma edição pendente ou que duas falhas restaurem outro valor otimista que também falhou. Favorito passa a ser otimista no catálogo/player; avaliação de faixa e álbum seguem o mesmo mecanismo. Os comandos retornam sucesso para os controles, aceitam snapshots de fallback para itens fora da página carregada e liberam entradas de edição após concluir. Troca de core invalida estados anteriores. Rollback também avança metadataRevision para atualizar coleções que mantêm snapshots próprios. Snapshots do playback preservam favorito/avaliação pendentes até a confirmação ou o rollback, evitando substituição pelo polling.

Álbum e playlist deixam de editar arrays em paralelo aos reducers dos controles; seus snapshots são atualizados pela revisão de metadados após a gravação. Player, menus, ranking e Info da faixa continuam delegando ao store; o RatingControl da janela Info passa a usar confirmação assíncrona. Menus do álbum também usam o reducer para restaurar sua nota após falha sem apagar edições mais recentes. Não houve troca dos renderers nem nova validação visual completa ou medição com Instruments.

Validação: 11 testes direcionados passaram, sem falhas ou avisos de runtime (CODE_SIGNING_ALLOWED=NO): nove novos testes de PersonalValueEditTests e dois testes existentes ajustados. Cobrem limpar/restaurar avaliação, confirmações fora de ordem, duas falhas consecutivas, snapshots antigos, rollback de álbum/favorito, botões AppKit reais e reuse, serialização de gravações e preservação da nota pendente no playback. Os testes do reducer validam a lógica compartilhada usada pelo SwiftUI; não executam uma interação visual completa desses renderers. Build final aprovado após integrar o reducer ao menu do álbum. A suíte completa não foi repetida nesta alteração.

### R05 — Pickers das duas sidebars (P2)

**Ocorrências:** [Features/Navigation/LibrarySideBarView.swift:472](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/LibrarySideBarView.swift:472); [Features/Player/QueueView.swift:226](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueView.swift:226).

Compartilham cápsula, padding 3, altura 30 e material regular, mas cada um copia a implementação. Esquerda tem largura variável e foreground selecionado/secundário; direita usa divisão uniforme.

**Contrato de reutilização sugerido:** GlassTabPicker com modos de distribuição e estilo comum. Tornar diferenças de layout parâmetros; não espalhar cópias de opacidade/spacing para manter aparência.

**Implementação em 08/10/2026:** Features/Shared/GlassTabPicker.swift centraliza opções identificáveis, Binding de seleção, cápsula/material regular, padding e spacing de 3 pt, altura de 30 pt, área clicável, destaque selecionado e opacidades de janela ativa/inativa. Distribuição e foreground são parâmetros: selectedExpands/selectedPrimary preserva a sidebar esquerda, enquanto equal/allPrimary mantém as três abas da direita com largura uniforme. A animação de seleção de 0,18 s permanece configurada somente na direita; a animação de ativação da janela continua compartilhada em 0,15 s.

Na esquerda, GeometryReader continua sem contribuir largura ideal dos labels ao NavigationSplitView; abas não selecionadas reservam 28 pt e a selecionada ocupa o restante. ViewThatFits mantém o limiar comum baseado no maior label completo, com fallback para ícone. Labels, help, traits de seleção e identificadores de acessibilidade existentes são preservados. Na direita, o inset horizontal externo de 8 pt continua no consumidor, e os cálculos de máscara/inset da fila passam a usar a altura do componente compartilhado.

Validação: build macOS aprovado (CODE_SIGNING_ALLOWED=NO) e diff sem erros de whitespace. Por se tratar de extração de apresentação, não foram adicionados testes que apenas reproduzem a implementação nem repetida a suíte completa. Resize e aparência das duas sidebars não receberam nova validação visual nesta alteração.

### R06 — Botões de opções circulares e menus de visualização (P2)

**Ocorrências:** [Features/Library/HistoryView.swift:125](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:125); [Features/Library/MusicLibraryToolbarControls.swift:4](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryToolbarControls.swift:4); [Features/Library/CollectionListing.swift:174](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/CollectionListing.swift:174); [Features/Library/ArtistView.swift:2482](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:2482).

Label, círculo 36, menuIndicator hidden, help, clip, glass e accessibility são repetidos entre menus. O conteúdo dos menus tem escopo diferente.

**Contrato de reutilização sugerido:** ToolbarOptionsButton/Style compartilhado com conteúdo de Menu injetado; reunir tokens 36/spacing/vidro. Não unir ordenação de artista/faixa/coleção numa enum sem domínio claro.

### R07 — Controles de reprodução de coleção (P2)

**Ocorrências:** [Features/Library/CollectionPlaybackControls.swift:3](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/CollectionPlaybackControls.swift:3); [Features/Library/ArtistView.swift:1621](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:1621); [Features/Player/PlayerBar.swift:5](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlayerBar.swift:5).

Álbum e playlist já compartilham CollectionPlaybackControls. Artista mantém Play/Shuffle próprios; player é outra apresentação legitimamente distinta.

**Contrato de reutilização sugerido:** Ampliar CollectionPlaybackControls com variantes necessárias ao artista e manter comandos PlayCollection/ShuffleCollection únicos. Não substituir todos os controles de player por essa view.

### R08 — Pipeline de artwork e escolha de imagem (P2)

**Ocorrências:** [Features/Player/ArtworkRepository.swift:29](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/ArtworkRepository.swift:29); [Features/Playlists/PlaylistArtworkThumbnail.swift:5](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistArtworkThumbnail.swift:5); [Features/Library/TrackInfoSheet.swift:336](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackInfoSheet.swift:336); [Features/Playlists/CreatePlaylistSheet.swift:152](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/CreatePlaylistSheet.swift:152); [Features/Library/ArtistsView.swift:146](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistsView.swift:146).

Artwork gerenciada, base64 de playlist, preview/importação, retrato e fallback têm pipelines diferentes. Borda de artwork já é um modifier compartilhado.

**Contrato de reutilização sugerido:** ArtworkSource + serviço de decode/downsample/cache + política de fallback. Compartilhar escolha de arquivo/security scope e validação entre editores; manter overrides e precedência local/manual do artista.

### R09 — Formatação de duração, resumo e tipografia (P2)

**Ocorrências:** [Features/Library/MusicLibrarySummary.swift:27](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibrarySummary.swift:27); [Features/Library/AlbumsView.swift:152](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumsView.swift:152); [Features/Library/HistoryView.swift:108](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:108); [Features/Library/TrackContextMenu.swift:153](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackContextMenu.swift:153); [Features/Library/TrackInfoSheet.swift:434](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackInfoSheet.swift:434).

Duração usa formatos locais em várias telas; resumos alternam horas/minutos e relógio; fonte/altura de toolbar/card existem em múltiplos enums e números literais.

**Contrato de reutilização sugerido:** DurationFormatter com contextos track/library/history e SummaryPresentation por domínio. Design tokens de typography/metrics/material. Diferentes textos informativos não precisam ser artificialmente idênticos.

### R10 — Coordenação de dados e estado fora do renderer (P1)

**Ocorrências:** [CoreBridge/DurvaldCoreStore.swift:8](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift:8); [Features/Library/ArtistView.swift:39](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:39); [Features/Library/MusicLibraryPresentation.swift:7](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryPresentation.swift:7); [Features/Library/BatchMetadataSheet.swift:9](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/BatchMetadataSheet.swift:9).

Store acumula playback, catálogo, metadata, filesystem, importação, device/equalizer e enriquecimento. ArtistView acumula carregamento, identidade, edição, catálogo e UI em 2559 linhas.

**Contrato de reutilização sugerido:** Separar por responsabilidade (PlaybackCoordinator, LibraryRepository, ArtistPresentation, ArtworkImportService), mantendo a fachada do store na migração. Tamanho do arquivo sozinho não prova lentidão, mas a concentração é risco de manutenção confirmado.

### R11 — Busca assíncrona e debounce (P2)

**Ocorrências:** [Features/Library/LibrarySearchView.swift:38](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/LibrarySearchView.swift:38); [Features/Library/MusicLibraryView.swift:242](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryView.swift:242); [Features/Playlists/PlaylistMusicPicker.swift:141](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistMusicPicker.swift:141); [Features/Library/HistoryView.swift:20](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:20).

Cada tela mantém loading/resultados/consulta comprometida/cancelamento e tempos de debounce. Pesquisa global também possui uma task de revisão que publica resultados sem o mesmo guard após await.

**Contrato de reutilização sugerido:** SearchPresentation com generation token e debounce configurável; garantir que resultado antigo não substitua consulta nova. Histórico busca num domínio diferente e deve reutilizar mecanismo, não necessariamente backend de pesquisa.

### R12 — Menus nativos e pontes de captura (P2)

**Ocorrências:** [Features/Library/TrackContextMenu.swift:197](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackContextMenu.swift:197); [Features/Library/TrackContextMenu.swift:394](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackContextMenu.swift:394); [Features/Library/TrackContextMenu.swift:483](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackContextMenu.swift:483).

Existe bom núcleo compartilhado de comandos nativos em TrackMenuController, mas seis bridges context/options para track/album/playlist, captures e trailing Menu coexistem no mesmo arquivo.

**Contrato de reutilização sugerido:** Separar modelo de ações, executor e presenters. Extrair lifecycle/captura comum onde equivalente; não substituir NSMenu por SwiftUI Menu por princípio, pois o bridge suporta drag/contexto específico.

### R13 — Estado de edição de settings e metadados (P2)

**Ocorrências:** [Features/Settings/SettingsView.swift:67](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/SettingsView.swift:67); [Features/Settings/EnrichmentSettingsView.swift:77](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/EnrichmentSettingsView.swift:77); [Features/Settings/EqualizerSettingsView.swift:128](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/EqualizerSettingsView.swift:128); [Features/Library/TrackInfoSheet.swift:32](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackInfoSheet.swift:32); [Features/Library/BatchMetadataSheet.swift:9](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/BatchMetadataSheet.swift:9).

As telas mantêm cópias locais e reaplicam snapshots; single/batch metadata usam drafts e receipts com semânticas próprias.

**Contrato de reutilização sugerido:** Shared EditingState (baseline, dirty, saving, error, refresh), com distinção explícita de valor misto em batch. Reutilizar validação de campo/undo, sem tratar single/batch como o mesmo draft.

### R14 — Infraestrutura de inspector sem ponto de uso encontrado (P3)

**Ocorrências:** [Features/Navigation/WindowSplitLayout.swift:183](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/WindowSplitLayout.swift:183); [Features/Navigation/WindowSplitLayout.swift:244](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/WindowSplitLayout.swift:244); [Features/Navigation/WindowSplitLayout.swift:33](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/WindowSplitLayout.swift:33).

Busca por símbolos no código macOS encontra definições desses tipos/método, mas nenhuma chamada fora do próprio arquivo. O painel atual é overlay; ainda há comentário de inspector/nested split.

**Contrato de reutilização sugerido:** Marcar como legado candidato a remoção ou reintegrar num protótipo de inspector. Confirmar projeto/configurações antes de excluir; remover comentários que descrevem uma hierarquia que não está ativa.

## O que já está bem compartilhado ou otimizado

- `CollectionListingLayout`, `CollectionListingItem` e `CollectionListingSorter` são usados por coleções; `AlbumCard` também aparece fora de Álbuns. Consolidar em cima disso, sem começar outro sistema de cards.
- `LibraryToolbarSearchField` já atende coleções e artista; o trabalho restante é incorporar outros consumidores e centralizar style/focus.
- `CollectionPlaybackControls` já atende álbum e playlist. `TrackListTrailingControls`, `ActiveTrackTitle`, `AlbumTrackPosition` e `playTrackOnDoubleClick` reduzem repetição em faixas.
- `ArtworkRepository` já oferece downsample, orçamento, buckets de pixel size, deduplicação de requests e cancelamento por consumidor. `NowPlayingCoordinator` reutiliza esse pipeline.
- `MusicLibraryPresentation` usa chaves de revisão, arrays como payload e snapshots preparados fora do MainActor. O estado persiste no shell entre navegações.
- `MusicLibraryTableView` usa reuse, IDs e atualização incremental; botões de favorito/avaliação são células nativas. A existência de `AnyView`/hosting pontual não prova gargalo.
- `DurvaldCoreStore` usa Observation e separa activeTrackID/queue/isPlaybackPaused do relógio; polling ativo/idle já tem intervalos diferentes e comandos publicam snapshots imediatamente.
- FSEvents tem lifecycle explícito; monitoramento do store faz debounce/reconexão/rescan. Now Playing usa MediaPlayer. Essas integrações já são nativas.
- `ArtistPresentationPolicy` e `ArtistEnrichmentDiagnostics` separam regras testáveis da UI. São exemplos para extrair o restante da ArtistView.

## Contratos sugeridos para padronização

| Contrato | Responsabilidade única | Consumidores | Cuidado |
| --- | --- | --- | --- |
| PageChromePolicy / PageViewport | Largura visível, insets, material e ativação da topbar | ContentView e páginas | Artista preserva header sem expansão à direita; corpo pode continuar sob os painéis. |
| SearchField / SearchFieldStyle | Placeholder, limpar, foco, vidro e layout por variante | Global, coleções, sidebar, filtros e picker | Separar apresentação de backend/debounce. |
| GlassTabPicker | Material, seleção, fonte e padding | Duas sidebars | Esquerda variável, direita uniforme. |
| ToolbarOptionsStyle | Círculo, dimensões, hover, acessibilidade | Menus de todas as páginas | Conteúdo específico do domínio continua separado. |
| TrackRowModel / TrackActions | Dados formatados e ações comuns | Tabela, fila, álbum, playlist, artista, histórico, pesquisa | Manter renderers adequados a seleção/reorder/performance. |
| LibraryRepository / CollectionPresentation | Cache de dados, índices e snapshots por revisão | Coleções, resumos, busca e importação | Preferir agregações no core; não obrigar todas as telas a carregar tudo. |
| ArtworkSource / ArtworkImportService | Decode, downsample, scope, cache e preview | Playlist, retrato, editor, artwork do core | Preservar precedência de imagem local/manual. |
| EditingState / MetadataValidation | Baseline, dirty, erro, save/undo | Settings e editores | Valores mistos de batch são uma semântica distinta. |
| Formatters / DesignMetrics | Duração, contagem, bytes, fontes e métricas comuns | Todo o cliente | Contextos diferentes podem ter apresentações diferentes. |

São propostas de responsabilidade, não APIs já existentes. Não é necessário criar todos esses tipos nem uma camada de abstração para cada Button.

## Sequência recomendada de trabalho

1. **Consolidar chrome e busca (N01–N04, R01–R02/R05–R06).** Primeiro documentar invariantes do comportamento aprovado, depois extrair componentes mantendo a implementação atual. Protótipo nativo de inspector/search é trabalho separado, com comparação visual e funcional.
2. **Eliminar consultas redundantes de catálogo/histórico (E01–E05/E15).** Contar chamadas por revisão/visita e tamanho dos payloads; escolher agregações ou cache por domínio. Evitar uma nova cópia de catálogo em cada presentation.
3. **Mover I/O de importação e unificar artwork (E06–E08, R08).** Compartilhar worker e thumbnail; manter limites de memória e ciclo de security scope.
4. **Compartilhar modelo/comandos das faixas e edição (R03–R04/R07/R09/R12–R13).** Migrar consumidor por consumidor, mantendo células AppKit onde já funcionam melhor.
5. **Medir antes de otimizar polling/layout/animação (E09–E14/E16).** SwiftUI Instrument, Time Profiler e energia com catálogo grande, playback ativo/pausado e janela em resize. Nenhuma medição foi executada para este relatório.
6. **Separar responsabilidades dos arquivos centrais e limpar legado (R10/R14).** Não misturar mudanças visuais, performance, comandos e exclusão de legado num único patch grande.

## Invariantes e validação dirigida para futuras alterações

| Família | Invariantes a preservar | Validação apropriada |
| --- | --- | --- |
| Chrome | Fundo legível com rolagem e painel aberto; sem espelhar componentes; fora da sidebar esquerda; topbar não empurra conteúdo | Estado/geometria em teste pequeno; captura somente dos estados afetados. |
| Artista | Header adapta à largura restante à direita; body estendido; controles estáveis ao abrir página; search expande quando há espaço | Capturas com painel aberto/fechado, resize e scroll só quando essa família mudar. |
| Busca/picker | Placeholder secundário com fonte padronizada; foco/Escape/limpar; abas com material regular | Verificação de contrato/teclado e um consumidor por variante. |
| Faixas | Favorite/rating com rollback e reuse; seleção; duplo clique; drag/drop e identidade da faixa | Testes de comandos/células existentes e casos de reorder/índices. |
| Dados | Busca/histórico completos; IDs locais corretos; revisão invalida cache; primeiro frame independente do resumo | FakeDurvaldCore, contagem de chamadas e catálogo paginado. |
| Artwork | Precedência de imagem local/manual, decode fora da UI, cancelamento e orçamento | Testes de cache/source e importação com arquivos grandes/volume lento quando pertinente. |
| Janela/motion | Accessibility/Reduce Motion, foco, múltiplos monitores e pausa em cena inativa | Teste dirigido ao comportamento alterado; evitar suite de UI inteira para documentação/estilo isolado. |

Os testes existentes em `MusicLibraryPerformanceTests` verificam revisões, identidade de tabela, updates incrementais e preparação de catálogo; o nome não implica que todos sejam benchmarks cronometrados. `ArtistPresentationPolicyTests`, `ArtistEnrichmentDiagnosticsTests`, `TrackMetadataLayoutTests` e `DurvaldUITests` já cobrem regras/layout/cenários úteis. Antes de criar testes novos, localizar e ampliar a cobertura correspondente. Este documento não executou esses testes.

## Inventário completo dos arquivos mantidos manualmente

“Sem achado localizado” ou “preservar” significa que o inventário não encontrou um problema específico suficiente para registrar; não é certificação de ausência de bugs. IDs indicam relações com as três listas acima.

| Arquivo | Componentes, papel e classificação |
| --- | --- |
| [Commands/AppCommands.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Commands/AppCommands.swift:1) | Commands e atalhos nativos; ações passam pelo store. Preservar. |
| [Commands/AppKeyboardShortcuts.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Commands/AppKeyboardShortcuts.swift:1) | Constantes de atalhos compartilhadas. Preservar. |
| [ContentView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/ContentView.swift:1) | N01–N03, E10, R01–R02/R06; shell, toolbar, navegação e composição. |
| [CoreBridge/DurvaldCoreStore.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift:1) | E01/E02/E06/E16, R10; fachada central MainActor/Observation. |
| [CoreBridge/LibraryFileWatcher.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/LibraryFileWatcher.swift:1) | FSEvents nativo; lifecycle e debounce no store. Nenhuma duplicação relevante localizada. |
| [CoreBridge/NowPlayingCoordinator.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/NowPlayingCoordinator.swift:1) | MediaPlayer nativo; comandos de sistema e artwork reutilizam repository. Preservar. |
| [CoreBridge/PlayerNavigationFixture.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/CoreBridge/PlayerNavigationFixture.swift:1) | Fixture de testes DEBUG; não tratar como renderer alternativo de produção. |
| [DurvaldApp.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/DurvaldApp.swift:1) | N08; WindowGroup, Settings e janelas nativas; bootstrap e fixtures DEBUG. |
| [Features/LastFM/LastFMSettingsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/LastFM/LastFMSettingsView.swift:1) | Form/TextField/SecureField nativos; view model específico. |
| [Features/LastFM/LastFMViewModel.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/LastFM/LastFMViewModel.swift:1) | E16; ObservableObject separado, integração via core e NSWorkspace. |
| [Features/Library/ActiveTrackTitle.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ActiveTrackTitle.swift:1) | Título ativo reutilizável; especialização visual legítima. |
| [Features/Library/AlbumTrackPosition.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumTrackPosition.swift:1) | Política compartilhada de posição/indicador; preservar. |
| [Features/Library/AlbumView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumView.swift:1) | N07 por contraste de listas; R01/R03/R07/R09; header e linhas próprias. |
| [Features/Library/AlbumsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/AlbumsView.swift:1) | E01/E03/E15, R08/R09; cards reaproveitados no artista/home. |
| [Features/Library/ArtistEnrichmentDiagnostics.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistEnrichmentDiagnostics.swift:1) | Política de mensagens/diagnóstico separada, com testes; preservar. |
| [Features/Library/ArtistPresentationPolicy.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistPresentationPolicy.swift:1) | Política pura de retrato/ranking/biografia/categorias, testada; preservar. |
| [Features/Library/ArtistView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistView.swift:1) | N02, E04/E11, R02/R03/R06–R10; concentração de estado e UI. |
| [Features/Library/ArtistsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ArtistsView.swift:1) | E01/E03/E04, R08/R09; portrait e filtro local. |
| [Features/Library/BatchMetadataSheet.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/BatchMetadataSheet.swift:1) | R10/R13; edição em lote e undo são domínio específico. |
| [Features/Library/CollectionListing.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/CollectionListing.swift:1) | E03, R06/R09; layout e itens já compartilhados entre coleções. |
| [Features/Library/CollectionPlaybackControls.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/CollectionPlaybackControls.swift:1) | R07; reutilização existente em álbum e playlist. |
| [Features/Library/HistoryView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HistoryView.swift:1) | E02–E05, R03/R06/R09/R11; List nativa com pipeline próprio. |
| [Features/Library/HomeView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/HomeView.swift:1) | ScrollView/LazyVGrid nativos e AlbumCard compartilhado; cards de biblioteca próprios. |
| [Features/Library/LibraryDestination.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/LibraryDestination.swift:1) | Modelo compartilhado de destinos; preservar contrato com histórico de navegação. |
| [Features/Library/LibrarySearchView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/LibrarySearchView.swift:1) | R03/R11; List nativa, resultados por entidade e debounce. |
| [Features/Library/MusicLibraryNativeControlCell.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryNativeControlCell.swift:1) | N09, R04; NSButton nativo reutilizável em células. |
| [Features/Library/MusicLibraryPresentation.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryPresentation.swift:1) | E01/E15; bom exemplo de snapshot/cache, revision e trabalho fora do MainActor. |
| [Features/Library/MusicLibrarySummary.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibrarySummary.swift:1) | E15, R09; agregação e arquivo em worker; resumo já compartilhado. |
| [Features/Library/MusicLibraryTableView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryTableView.swift:1) | N09, R03; NSTableView incremental, hosting pontual, grupos próprios. |
| [Features/Library/MusicLibraryToolbarControls.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryToolbarControls.swift:1) | N03, R01/R06; busca e opções compartilhadas parcialmente. |
| [Features/Library/MusicLibraryView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryView.swift:1) | R03/R11; presentation persistente e tabela nativa; busca própria. |
| [Features/Library/MusicLibraryViewPreferences.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryViewPreferences.swift:1) | Modelo de ordenação compartilhado; preservar. |
| [Features/Library/RatingControl.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/RatingControl.swift:1) | N10/R04; estrelas SwiftUI reutilizáveis. |
| [Features/Library/ToolbarSearchTextField.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/ToolbarSearchTextField.swift:1) | N03/R01; NSTextField, foco e monitores locais próprios. |
| [Features/Library/TrackContextMenu.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackContextMenu.swift:1) | R03/R04/R09/R12; NSMenu compartilhado, bridges e coordinators concentrados. |
| [Features/Library/TrackInfoSheet.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackInfoSheet.swift:1) | E06, R08/R09/R13; editor e seleção de artwork. |
| [Features/Library/TrackPlaybackGesture.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Library/TrackPlaybackGesture.swift:1) | Double-click compartilhado; preservar. |
| [Features/Navigation/ContentShellState.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/ContentShellState.swift:1) | R02; restauração de scroll e estado de shell compartilhados. |
| [Features/Navigation/LibraryNavigationHistory.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/LibraryNavigationHistory.swift:1) | Histórico de rotas próprio adequado ao produto; centralizado. |
| [Features/Navigation/LibrarySideBarView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/LibrarySideBarView.swift:1) | N04/N06, R01/R05; layout e seleção próprios sobre split nativo. |
| [Features/Navigation/SideBarSection.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/SideBarSection.swift:1) | Modelo único de abas; preservar. |
| [Features/Navigation/WindowSplitLayout.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Navigation/WindowSplitLayout.swift:1) | R14; bridge de sidebar ativo e inspector aparentemente legado. |
| [Features/Player/ArtworkRepository.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/ArtworkRepository.swift:1) | E08/R08; cache limitado, single-flight e downsample existentes. |
| [Features/Player/ArtworkView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/ArtworkView.swift:1) | R08; consumidor shared, task por request e borda comum. |
| [Features/Player/LyricsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/LyricsView.swift:1) | ScrollView/texto nativos; renderer reutilizado em painel/popover. |
| [Features/Player/PlaybackActivityIndicator.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlaybackActivityIndicator.swift:1) | N10; CALayer em bridge AppKit, stop/lifecycle próprios. |
| [Features/Player/PlayerBar.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlayerBar.swift:1) | N05, R04/R07/R09; responsividade, slider e metadata links próprios. |
| [Features/Player/PlayerMarqueeText.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/PlayerMarqueeText.swift:1) | N10/E12; motion e cadence limitados, componente específico. |
| [Features/Player/QueueTableView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueTableView.swift:1) | N07, E13, R03; NSTableView e drag/drop nativos. |
| [Features/Player/QueueView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/QueueView.swift:1) | N01/N04, R05; composição de painel e material sidebar. |
| [Features/Player/SpectrumAnalyzerView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Player/SpectrumAnalyzerView.swift:1) | N10/E12; atualização FFI/Shapes a 50 ms. |
| [Features/Playlists/CreatePlaylistSheet.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/CreatePlaylistSheet.swift:1) | E06, R08/R13; draft e importação de capa próprios. |
| [Features/Playlists/PlaylistArtworkThumbnail.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistArtworkThumbnail.swift:1) | E07/R08; decode base64 sem cache shared. |
| [Features/Playlists/PlaylistMusicPicker.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistMusicPicker.swift:1) | E14, R01/R03/R11; sugestões, busca e linhas próprias. |
| [Features/Playlists/PlaylistTransfer.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistTransfer.swift:1) | M3U8/service e relatório separados; manter parser independente da UI. |
| [Features/Playlists/PlaylistView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistView.swift:1) | N07, R01/R03/R07/R09; reorder/drop e filtros próprios. |
| [Features/Playlists/PlaylistsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistsView.swift:1) | E01 por dados de ordenação; CollectionListing shared, importação/toolbar próprias. |
| [Features/Playlists/SmartPlaylistSheet.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Playlists/SmartPlaylistSheet.swift:1) | Picker/Form e regras do core; sem duplicação integral de renderer identificada. |
| [Features/Settings/AudioOutputSettingsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/AudioOutputSettingsView.swift:1) | E16/R13; Picker nativo e seleção local/remota. |
| [Features/Settings/EnrichmentSettingsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/EnrichmentSettingsView.swift:1) | R13; Form nativa e apply de snapshot. |
| [Features/Settings/EqualizerSettingsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/EqualizerSettingsView.swift:1) | E16/R13; NSSlider vertical nativo, métricas por polling. |
| [Features/Settings/LibraryRepairView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/LibraryRepairView.swift:1) | List/dialog nativos; suggestions filtra coleção por item, custo a medir. |
| [Features/Settings/LibrarySettingsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/LibrarySettingsView.swift:1) | UI nativa de paths/scan; usa store e watcher centralizado. |
| [Features/Settings/SettingsView.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/Features/Settings/SettingsView.swift:1) | N08/R13; TabView/Form nativos com tamanho e janela customizados. |
| [TopbarHoverObserver.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/TopbarHoverObserver.swift:1) | N02, E09, R02; backdrop nativo explícito e hover por polling. |
| [WindowTrafficLights.swift:1](/Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald/WindowTrafficLights.swift:1) | N08; política customizada de janelas e Escape. |

## Outros artefatos e limites de cobertura

- Projeto: `durvald-macos/Durvald/Durvald.xcodeproj/project.pbxproj`; recursos do app (`Assets.xcassets`), entitlements/configuração e binários/headers UniFFI são infraestrutura. Não foram classificados como componentes visuais não nativos.
- Bridge: `durvald-macos/Durvald/Durvald/durvald_core.swift` e `durvald-macos/Durvald/Generated/arm64/durvald_core.swift`. Corrigir origem/geração quando o contrato FFI mudar; não refatorar código gerado por estética.
- Testes: inventário e leitura dirigida dos cenários relacionados; sem execução nesta tarefa. Cobertura comportamental/visual ampla não é comprovada por uma busca por nomes de testes.
- Core Rust: contratos consumidos foram observados do cliente. Propostas de agregações/streams precisam de avaliação no core antes de assumir que novas APIs existem.
- As APIs nativas sugeridas são alternativas a comparar, não garantia de reprodução exata da aparência do Apple Music. Mudanças recentes aprovadas não devem ser removidas como “workaround” sem comprovação de equivalência.

## Referências primárias da Apple

- [NSSearchField](https://developer.apple.com/documentation/appkit/nssearchfield): controle de busca com edição e ações próprias; referência para N03/R01.
- [NSSearchToolbarItem.searchField](https://developer.apple.com/documentation/appkit/nssearchtoolbaritem/searchfield): alternativa específica para toolbar; avaliar compatibilidade com o modo compacto atual.
- [PickerStyle.segmented](https://developer.apple.com/documentation/swiftui/pickerstyle/segmented): referência funcional para N04/R05, sem obrigar a largura variável do produto a um layout uniforme.
- [inspector(isPresented:content:)](https://developer.apple.com/documentation/swiftui/view/inspector(isPresented:content:)): apresentação de inspector e restauração nativa; alternativa para N01, não promessa de material idêntico à sidebar.
- [NSVisualEffectView.Material](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum): materiais semânticos de sidebar/header/titlebar; o app já os usa em pontos próprios.
- [NSTrackingArea](https://developer.apple.com/documentation/appkit/nstrackingarea): tracking por eventos a avaliar em E09; precisa de uma região apropriada de view.
- [NSCache](https://developer.apple.com/documentation/foundation/nscache): cache transitório com evicção; sua semântica não substitui automaticamente o orçamento estrito do repository atual.
- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance): usar Instruments para localizar bodies/updates demorados e frequentes; fundamento da distinção entre custo estático e gargalo medido.
- [Improving your app’s rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency): referência para updates/animação, sem justificar remover animações úteis sem medir.

## Resultado do mapeamento

Foram registrados **10 grupos de composição visual/nativa, 16 grupos de eficiência e 14 grupos de reutilização**. Esses 40 registros não são 40 bugs independentes: há sobreposição proposital entre critérios, e várias entradas documentam especializações legítimas ou hipóteses que exigem medição.

As prioridades de maior alcance são chrome/busca, reuso do modelo de faixas, preparação compartilhada de catálogo/histórico, I/O de artwork e separação das responsabilidades de ArtistView/DurvaldCoreStore. O cliente já possui bases nativas e componentes reutilizáveis fortes; a migração deve ampliar essas bases sem desfazer o comportamento visual aprovado.
