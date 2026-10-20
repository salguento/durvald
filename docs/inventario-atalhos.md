# Inventário de atalhos — fase 1, item 3

Data: 20/10/2026. Base: commit `f8a490f`.
Status: inventário do estado anterior por leitura do código. O recorte 5 foi
implementado em 20/10/2026; ver [mapa atual e contrato](features/keyboard-commands.md).
Compilação e 53 testes unitários passaram. A validação interativa segue pendente
porque o macOS impediu a inicialização do runner de interface por autenticação em
andamento. O item 3 ainda não tem sua validação completa concluída.

Escopo principal: cliente macOS. Inclui uma verificação do cliente GTK e das
fronteiras com o core. Este documento registra o que existe e prepara o recorte
de implementação; não estabelece novas combinações nem afirma conformidade com
um padrão universal da indústria.

## 1. Atalhos explícitos do aplicativo macOS

Há **nove combinações** em `AppKeyboardShortcuts`, além das duas teclas locais
compartilhadas pelos sliders. A disponibilidade abaixo é a declarada no código;
a precedência real entre editor, botão, janela e menu precisa de teste.

| Ação | Combinação atual | Onde está ligada | Disponibilidade e observações |
| --- | --- | --- | --- |
| Focar pesquisa da biblioteca | `⌘K` | Menu de edição, `AppCommands`; ação da cena em `ContentView` | Desabilitada sem `openLibrarySearch` da cena focada. Chama `requestSearchFocus`. |
| Voltar na navegação | `⌘←` | Botão da toolbar em `ContentView` | Desabilitado sem histórico anterior. Há teste que exige navegação mesmo com a busca em edição. |
| Avançar na navegação | `⌘→` | Botão da toolbar em `ContentView` | Desabilitado sem histórico seguinte. Mesma questão de precedência com edição de texto. |
| Mostrar/ocultar fila | `⌘⌥L` | Botão da toolbar em `ContentView` | Sem condição explícita de habilitação; alterna o painel direito. |
| Reproduzir/pausar | `Espaço` | Botão em `PlayerBar` | Desabilitado sem faixa ou durante a troca de estado do botão. O item equivalente no menu Reprodução não declara esse atalho. |
| Aumentar volume | `⌘↑` | Menu Reprodução em `AppCommands` | Passo de 5 pontos percentuais; menu sem condição explícita de habilitação. |
| Diminuir volume | `⌘↓` | Menu Reprodução em `AppCommands` | Passo de 5 pontos percentuais; mesma observação. |
| Alternar shuffle | `⌘⇧S` | Menu Reprodução em `AppCommands` | Sem condição explícita no menu; usa `store.toggleShuffle()`. |
| Alternar repetição | `⌘⇧R` | Menu Reprodução em `AppCommands` | Sem condição explícita no menu; alterna desativada → tudo → uma faixa. |

Cinco combinações são declaradas nos menus principais: pesquisa, os dois volumes,
shuffle e repetição. As outras quatro são declaradas nos controles da interface.
A lista central contém as teclas; a execução e a disponibilidade continuam
espalhadas entre menu e views.

Fontes: [definições](../durvald-macos/Durvald/Durvald/Commands/AppKeyboardShortcuts.swift),
[menus](../durvald-macos/Durvald/Durvald/Commands/AppCommands.swift),
[navegação](../durvald-macos/Durvald/Durvald/ContentView.swift),
[player](../durvald-macos/Durvald/Durvald/Features/Player/PlayerBar.swift).

## 2. Teclas locais, controles nativos e mídia

| Contexto | Entrada atual | Comportamento identificado |
| --- | --- | --- |
| Slider de progresso focado | `←` / `→` | Recuar/avançar cinco segundos; só focável com faixa. |
| Slider de volume focado | `←` / `→` | Diminuir/aumentar cinco pontos percentuais. |
| Prévia de busca aberta | `↑` / `↓` | Selecionar sugestão/resultado; limitada às extremidades, sem circular. |
| Prévia de busca aberta | `Return` / Enter numérico | Abrir o item selecionado ou submeter a consulta. |
| Campo de busca | `Return` | Executar `onSubmit` quando fornecido. |
| Campo de busca | `Esc` | Se `clearsOnEscape` e há texto, limpar e manter foco; caso contrário, retirar foco. A prévia deixa Esc para o editor. |
| Botão nativo de estrela focado | `←` / `→` | Em meias estrelas, escolher a metade inferior ou a estrela inteira daquele botão e executar a ação. |
| Criação/edição de playlist e regras | `Esc` / ação padrão | Cancelar ou confirmar, conforme os botões e sua habilitação. |
| Info de faixa e edição em lote | `Esc` / ação padrão | Fechar/cancelar e salvar/aplicar conforme a tela; lote desabilita ações durante trabalho. |
| Importação/exportação de playlist | Ação padrão | Fechar o resumo do resultado. |
| Reparo da biblioteca | `Esc` | Fechar a apresentação. |
| Equalizador | Ação padrão | Botão de confirmação da apresentação. |
| Janela de ajustes | `Esc` | Monitor local fecha a janela via `performClose`; verifica a janela, sem checar o editor ou modificadores. |
| Tabela de músicas | Comportamentos de `NSTableView` | Seleção múltipla está habilitada. Não há implementação própria de Return, Delete ou seleção total por comando do app. |
| Fila | Comportamentos de `NSTableView` | Reprodução explícita por botão/duplo clique e remoção por menu. Não há tratamento próprio de Return/Delete. |
| Botões e links | Navegação/ativação nativa por foco | Alguns controles revelam play ou sublinhado ao receber foco. A ordem completa de Tab não foi auditada em execução. |

O monitor da prévia só trata teclas na janela de origem, com painel aberto e sem
Command, Control ou Option. Shift não é excluído. Isso precisa entrar nos testes
de seleção de texto por `⇧↑/⇧↓` enquanto há sugestões.

Fontes: [busca global](../durvald-macos/Durvald/Durvald/Features/Search/GlobalSearchField.swift),
[monitor da prévia](../durvald-macos/Durvald/Durvald/Features/Search/SearchPreviewAnchor.swift),
[campo nativo](../durvald-macos/Durvald/Durvald/Features/Library/ToolbarSearchTextField.swift),
[estrelas](../durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryNativeControlCell.swift),
[janelas](../durvald-macos/Durvald/Durvald/WindowTrafficLights.swift).

### Comandos de mídia do sistema

`NowPlayingCoordinator` registra play, pause, toggle play/pause, faixa anterior,
próxima faixa e alteração de posição pelo `MPRemoteCommandCenter`. A habilitação
considera presença de faixa e pausa. Esse caminho é independente dos atalhos de
teclado da janela; o código não vincula diretamente teclas F7/F8/F9 nem instala
um capturador global de teclado. A entrega por teclas de mídia depende do sistema.

Fonte: [NowPlayingCoordinator](../durvald-macos/Durvald/Durvald/CoreBridge/NowPlayingCoordinator.swift).

### Comandos herdados da plataforma

A cena usa `WindowGroup` e `SwiftUI.Settings`, sem substituir todos os grupos de
menu nativos. Encerrar, fechar janela, ajustes, copiar, colar, desfazer e selecionar
tudo devem ser conferidos no menu/responder ativo durante a validação. Não foram
contados entre os nove atalhos explícitos nem considerados implementações próprias.

## 3. Ações existentes ainda sem atalho explícito

P1/P2 abaixo indicam a ordem proposta dentro desta entrega de atalhos, não mudança
na prioridade das outras features do roadmap. “Sem atalho” significa ausência de
ligação explícita encontrada; não implica que o controle seja inacessível por Tab.

| Grupo | Ação já disponível | Superfície atual / requisito para o comando | Ordem |
| --- | --- | --- | --- |
| Reprodução | Próxima faixa; faixa anterior | Menu Reprodução e player; unificar disponibilidade com presença de faixa. | P1 |
| Reprodução | Iniciar a faixa/ocorrência focada | Play nas linhas e duplo clique; precisa alvo de foco próprio, distinto de pausar o player global. | P1 |
| Reprodução | Play/shuffle da coleção aberta | `CollectionPlaybackControls`; preservar origem e ocorrência conforme contrato existente. | P1 |
| Reprodução | Seek relativo fora do slider | Slider já usa `store.seek`; decidir se haverá comando de janela e qual incremento. | P2 |
| Reprodução | Mutar/restaurar volume | Botão em `PlayerBar`; estado de mute e volume anterior são locais à view e precisam ser compartilhados para um comando. | P1 |
| Navegação | Mostrar/ocultar barra esquerda | Botão `navigation.sidebar`; manter janela ativa e layout compacto. | P1 |
| Navegação | Ir à Home, músicas, álbuns, artistas, playlists e Retrospectiva | Barra lateral e atalhos visuais da Home; centralizar destinos pela navegação existente. | P1 |
| Navegação | Abrir álbum/artista da faixa ativa | Links do player e menus; não confundir faixa ativa com seleção de uma listagem. | P2 |
| Busca | Focar filtro da página | Controles locais já existem; distinguir da pesquisa global de `⌘K`. | P1 |
| Busca | Navegar entre categorias/resultados | Há prévia com setas; falta um contrato de foco para a página inteira de resultados. | P2 |
| Fila | Tocar de próxima; adicionar ao fim | Menus de faixa/álbum/playlist e seleção da tabela; publicar alvo e seleção ativos. | P1 |
| Fila | Remover item; limpar fila | Menu/botões da fila; remoção atual desabilita posição zero e limpeza possui confirmação. | P1 |
| Fila | Reordenar item | Arraste na fila; oferecer ação equivalente por teclado e preservar regras do item atual. | P2 |
| Seleção | Info/editar metadados de uma faixa ou lote | `TrackInfoCoordinator`, menu Info e janela de metadados; precisa seleção ativa por janela. | P1 |
| Seleção | Copiar nome/título | Menus Compartilhar; responder ao contexto e preservar copiar texto no editor. | P2 |
| Seleção | Favoritar/desfavoritar | Menus e botões; respeitar alvo e seleção múltipla. | P2 |
| Seleção | Avaliar/limpar avaliação | Menu de avaliações; respeitar preferência de exibição, granularidade e operação em curso. | P2 |
| Seleção | Ir ao álbum/artista da seleção | Menus; múltiplos destinos já abrem submenus, sem um único destino implícito. | P2 |
| Playlists | Criar playlist; criar inteligente | Menu de criação na página; encaminhar para os sheets existentes. | P1 |
| Playlists | Adicionar seleção à playlist | Seletor de playlists nos menus; abrir seletor em vez de escolher destino silenciosamente. | P1 |
| Playlists | Editar detalhes/regras; excluir playlist | Menu e toolbar; exclusão deve manter a confirmação existente. | P2 |
| Playlists | Importar; exportar M3U8 | Menu de criação/opções; exportação tem caminhos relativos ou absolutos. | P2 |
| Playlists | Reordenar faixas manualmente | Arraste em playlist manual, sem filtro e na ordem da playlist; respeitar essas condições. | P2 |
| Replay | Salvar Replay; mudar modo/opções | Banner e apresentações existentes; só habilitar quando há draft elegível. | P2 |
| Biblioteca | Atualizar biblioteca | Já está em `AppCommands`; desabilitado durante scan ou sem pastas. | P1 |
| Biblioteca | Adicionar pasta; cancelar scan | Ajustes/controles de scan; refletir operação atual. | P2 |
| Apresentação | Abrir opções da listagem/colunas | Toolbar e janela de opções; somente na superfície compatível. | P2 |
| Ajuda | Mostrar lista de atalhos | Não foi encontrada uma apresentação própria; criar como parte da entrega. | P1 |

Remover uma faixa da playlist e apagar arquivos da biblioteca não foram tratados
como simples atalhos pendentes: não foi encontrada uma ação correspondente na
`PlaylistView`/listagem principal auditada. Essas ações exigem inventário funcional
próprio antes de ganhar Delete. Remover da fila, excluir playlist e apagar arquivo
são operações diferentes.

Fontes: [menus compartilhados](../durvald-macos/Durvald/Durvald/Features/Library/LibraryMenuDefinition.swift),
[menus nativos](../durvald-macos/Durvald/Durvald/Features/Library/NativeLibraryMenu.swift),
[tabela de músicas](../durvald-macos/Durvald/Durvald/Features/Library/MusicLibraryTableView.swift),
[fila](../durvald-macos/Durvald/Durvald/Features/Player/QueueTableView.swift),
[playlist](../durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistView.swift),
[criação/importação](../durvald-macos/Durvald/Durvald/Features/Playlists/PlaylistsView.swift).

## 4. Pontos que precisam ser resolvidos antes de ampliar o mapa

1. **Edição versus navegação:** `⌘←/⌘→` têm uso explícito para histórico, inclusive
   com busca focada, exigido por `testCommandArrowsFollowAvailableNavigationHistory`.
   Há conflito de intenção com movimentação no texto. A implementação deve definir
   a precedência e atualizar o teste se a regra mudar; isso não é um bug comprovado
   apenas por leitura do código.
2. **Espaço:** está no botão do player, sem política central que reconheça campos
   de texto e controles locais. Validar busca, renomeação, descrições, sliders,
   estrelas e botões focados antes de adicionar outro handler de Espaço.
3. **Disponibilidade divergente:** o player desabilita anterior/próxima/play sem
   faixa; os itens do menu Reprodução não declaram as mesmas condições. Reutilizar
   uma regra comum e manter comandos de janelas auxiliares no contexto correto.
4. **Seleção por janela:** só a busca publica `FocusedValues`. Nenhuma seleção de
   faixa/álbum/playlist é publicada ali para comandos globais. `NSTableView` tem
   seleção múltipla, enquanto linhas SwiftUI não oferecem o mesmo contrato.
5. **Menus contextuais:** os `NSMenuItem` próprios usam `keyEquivalent` vazio.
   Não basta acrescentar uma tecla ao menu de contexto: criar comandos acessíveis
   nos menus principais e encaminhá-los ao alvo ativo.
6. **Esc e Return:** preservar prioridade de popovers, editores e sheets. O monitor
   de Esc dos ajustes fecha a janela diretamente; precisa de teste com edição e
   apresentação subordinada abertas.
7. **Descoberta dos atalhos:** não há tela própria de ajuda. `.help` e rótulos dos
   botões em geral descrevem a ação, sem incluir a combinação. Menu e ajuda devem
   derivar do mesmo catálogo para evitar divergência.
8. **Identidade:** iniciar/remover/reordenar deve usar a ocorrência da coleção/fila,
   não apenas o ID da faixa. Playlists podem conter duplicatas. A semântica de
   repeat/shuffle já implementada deve continuar sendo reutilizada.

## 5. Recorte proposto para a implementação

1. Montar catálogo de comandos com identificador, título, combinação opcional,
   escopo e disponibilidade; manter execução nas camadas que já possuem as ações.
2. Publicar ações da janela e da seleção ativa via foco; distinguir seleção,
   coleção aberta e faixa em reprodução. Centralizar mute no estado compartilhado.
3. Resolver conflitos de edição e unificar os nove atalhos atuais entre controles
   e menus. Em seguida, atribuir combinações às ações P1 após conferir convenções
   macOS e colisões com menus nativos. Nenhuma combinação nova foi fixada aqui.
4. Expor os comandos nos menus apropriados e numa apresentação “Atalhos de teclado”,
   com ações indisponíveis identificadas conforme o contexto.
5. Entregar as ações P2 em seguida; não condicionar os comandos principais à
   implementação de tags, Listen List, plugins ou outras features futuras.

O core continua responsável pelas operações de reprodução/persistência. Teclas,
foco, menu e combinação pertencem ao cliente; este inventário não indica migração
de banco nem uma nova API Rust obrigatória para a primeira entrega.

## 6. Cobertura encontrada e matriz de validação pendente

Há testes de interface para `⌘K`, envio por Return, foco de busca, Esc e navegação
com `⌘←/⌘→`, além de testes de menus, avaliação e reprodução. Isso comprova presença
de cenários no repositório, não uma nova execução ou uma cobertura completa.

Fonte: [testes de interface](../durvald-macos/Durvald/DurvaldUITests/DurvaldUITests.swift).

| Cenário a validar na implementação | Resultado esperado |
| --- | --- |
| Digitar texto com espaços e atalhos de edição | Texto é editado sem pausar/reproduzir ou executar ações na seleção musical. |
| Busca com prévia; setas, Shift+setas, Return e Esc | Seleção e editor seguem a precedência definida, sem capturar combinações não destinadas à prévia. |
| Sem faixa, em pausa, carregando e em reprodução | Menu, botão e atalho têm a mesma disponibilidade. |
| Janela principal, Info e Ajustes; sheet aberto | Comando atinge a janela/contexto correto; fechar não fecha outra apresentação. |
| Uma faixa, múltiplas faixas e nenhuma seleção | Info, copiar, favoritos, avaliação e enqueue usam o alvo correto ou ficam desabilitados. |
| Playlist com faixa repetida; fila reordenada | Play e remoção atingem a ocorrência escolhida. |
| Slider/estrela/botão focado | Setas e ativação local preservam seu comportamento. |
| Barra lateral recolhida, fila aberta e janela compacta | Atalhos continuam disponíveis independentemente de um botão estar visível. |
| Exclusão, limpeza, importação e scan em andamento | Confirmações e bloqueios existentes são preservados. |
| Layouts de teclado e menus nativos | Combinações escolhidas são digitáveis, exibidas corretamente e sem colisões identificadas. |
| Tab e navegação de teclado do macOS | Ordem previsível, foco visível e controles acionáveis sem mouse. |
| Ajuda versus menu versus execução | Mesmo título, combinação e disponibilidade para cada comando. |

## 7. Cliente GTK

Foi encontrado um único acelerador explicitamente registrado: `<Primary>q` para
`app.quit`, em [main.rs](../durvald-gtk/src/main.rs). Não foram encontrados outros
`set_accels_for_action`, `EventControllerKey` ou handlers de tecla no cliente.
Isso não elimina os comportamentos nativos dos widgets GTK. Paridade deve ser
planejada por ação disponível naquele cliente, usando convenções da plataforma,
sem copiar literalmente os modificadores do macOS.
