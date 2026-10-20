# Comandos e atalhos de teclado no macOS

Implementação do recorte 5 do [inventário](../inventario-atalhos.md), em 20/10/2026.
A validação interativa do recorte foi executada em 20/10/2026, com correções de foco e integração nativa descritas abaixo.

## Catálogo e execução

`AppCommandID` contém 65 comandos, dos quais 39 têm combinação atribuída. Cada
entrada define identidade, título, grupo, escopo e apresentação da combinação.
Menus e ajuda usam esse catálogo. Os comandos sem combinação continuam acessíveis
pelos menus, respeitando a disponibilidade do contexto.

`AppCommandTarget` publica ações da janela, da página e da seleção por
`FocusedValues`. A presença de uma ação determina sua disponibilidade. O dispatcher
exige a janela principal ativa e sem sheet anexado. Uma seleção ausente não é
substituída silenciosamente pela faixa em reprodução. Comandos próprios de faixa
ativa possuem entradas separadas.

O estado de mute e o volume de restauração pertencem a `DurvaldCoreStore` e são
compartilhados pelo botão e pelo comando. A disponibilidade dos transportes também
considera mudanças de faixa em andamento. A janela publica sinais específicos de
reprodução, evitando depender da posição do relógio para atualizar todo o catálogo.

## Mapa principal

| Ação | Combinação |
| --- | --- |
| Pesquisa global, que abre/foca a Home | `⌘K` |
| Filtro da página atual | `⌘F` |
| Voltar / avançar na navegação | `⌘[` / `⌘]` |
| Mostrar/ocultar barra lateral / fila | `⌃⌘S` / `⌥⌘L` |
| Início / músicas / álbuns / artistas / playlists / Retrospectiva | `⌘1` a `⌘6` |
| Reproduzir/pausar a faixa ativa | `Espaço` |
| Faixa anterior / próxima | `⌃⌘←` / `⌃⌘→` |
| Volume | `⌘↑` / `⌘↓` |
| Mutar/restaurar volume | `⇧⌘M` |
| Shuffle / repetição | `⇧⌘S` / `⇧⌘R` |
| Recuar/avançar cinco segundos | `⌥⌘←` / `⌥⌘→` |
| Reproduzir a seleção focada | `Return` |
| Reproduzir / embaralhar a coleção aberta | `⌘Return` / `⇧⌘Return` |
| Tocar seleção de próxima / adicionar ao fim da fila | `⌥⌘N` / `⌥⌘E` |
| Escolher playlist de destino para a seleção | `⇧⌘P` |
| Info / copiar nome / favoritar seleção | `⌘I` / `⇧⌘C` / `⇧⌘L` |
| Remover a ocorrência selecionada da fila | `Delete` (`⌫`) |
| Mover item para cima / baixo | `⌃⌘↑` / `⌃⌘↓` |
| Nova playlist / nova playlist inteligente | `⌘N` / `⇧⌘N` |
| Atualizar biblioteca | `⌘R` |
| Opções da listagem de músicas | `⌘J` |
| Ajuda de atalhos | `⌥⌘/` |

A ajuda abre pelo menu Ajuda e mostra a disponibilidade do contexto em que foi
aberta. `⌥⌘/` evita a combinação `⇧⌘/`, capturada pela busca nativa do menu Ajuda
do macOS. O grupo nativo de novos itens é substituído pelas ações de criação de
playlists, evitando que `⌘N` fique registrado também como nova janela.

Os atalhos de histórico anteriores `⌘←/⌘→` foram substituídos. Essas combinações
ficam disponíveis para o editor de texto. As escolhas foram revistas com as
[orientações Apple para teclados](https://developer.apple.com/design/human-interface-guidelines/keyboards/)
e os [atalhos do Música no Mac](https://support.apple.com/guide/music/mus1019/mac).
As combinações específicas de seleção, fila e destinos são decisões deste app.

## Foco e controles locais

Espaço, Return e Delete são tratados depois dos controles SwiftUI focados, sem
registrar equivalentes de menu que capturem essas teclas em editores nativos.
Os menus mostram sua combinação no título. Uma ponte local limitada à janela
trata as teclas de tabelas nativas e da janela sem controle ativo. Ela ignora
modificadores e não repete o transporte ao manter a tecla pressionada.

Sliders preservam setas locais e protegem suas teclas simples. Editores preservam
seleção, espaços, Return e Delete; comandos de seleção e transportes que conflitam
com a edição ficam indisponíveis. A prévia da pesquisa deixa Shift+setas para a
seleção de texto. Esc nos ajustes não fecha diretamente a janela quando há editor,
modificadores ou sheet subordinado.

As tabelas nativas de músicas e fila expõem o alvo da seleção pelo primeiro
respondedor, além dos valores de foco SwiftUI. A seleção de músicas só fica
ativa enquanto a página está apresentada. Clicar na tabela transfere o foco
para ela, preservando a seleção múltipla por Shift+setas. Linhas SwiftUI de faixas
também transferem o foco para um respondedor nativo ao clicar, sem depender da
preferência de navegação por teclado do sistema. Info reutiliza a confirmação existente de edição em lote e sua
preferência de não perguntar novamente. Linhas focáveis de faixa, cartões de
álbum e playlist publicam seus próprios alvos. Destinos ambíguos de artista/álbum
ficam indisponíveis em vez de escolher arbitrariamente um deles.

## Coleções e ações complementares

- Álbuns, playlists, artistas e Replay reutilizam `PlaybackCollection`, mantendo
  contexto, ordem, repetição e shuffle existentes.
- Linhas de playlist preservam a posição original da ocorrência, inclusive quando
  a mesma faixa está repetida. A reordenação mantém foco na posição de destino e
  só está disponível no modo manual, sem filtro e sem gravação de ordem pendente.
- A fila impede remoção e movimentação do item atual. Mudanças estruturais limpam
  a seleção, evitando aplicar o próximo comando a outra ocorrência que ocupou a
  mesma posição; selecionar novamente habilita os comandos para o novo item.
- O seletor de playlist exige escolha explícita e oferece criação de uma nova.
  Playlists inteligentes não são oferecidas como destino manual; copiar uma
  playlist também exclui a própria playlist dos destinos.
- Favoritos, avaliações em meias estrelas ou inteiras e limpeza de avaliação usam
  as operações existentes. Avaliar zero e remover avaliação permanecem distintos.
- Edição, exclusão, importação e exportação de playlists, abrir/salvar Replay,
  atualização da biblioteca, escolha de pasta e cancelamento de scan estão nos menus.
  Editar regras exige a página de detalhes da playlist carregada.
- Exclusão de playlist e limpeza de fila pedem confirmação. Exclusão de arquivos
  de áudio e remoção de uma faixa da playlist não foram adicionadas por atalhos.

O cliente GTK e a API/banco Rust permanecem sem mudanças nesta entrega.

## Correções durante a validação

- A publicação dos comandos da janela foi separada da observação dos comandos
  focados em `CommandInputModifier`. A ação da ajuda captura valores locais,
  evitando um ciclo de closures no grafo de foco que travava a abertura de álbuns.
- Uma ponte removida da hierarquia não pode mais apagar a referência da nova
  janela; a execução verifica a janela realmente ativa.
- Tabelas e linhas clicadas fornecem o alvo pelo primeiro respondedor. A mudança
  de foco invalida a disponibilidade dos menus, e editores mantêm sua proteção.
- A playlist solicita foco na ocorrência selecionada e na posição de destino
  depois de mover um item, inclusive com faixas repetidas.
- As fixtures de interface passaram a simular busca, volume, reprodução e
  reordenação sem acessar o ponteiro Rust ausente nessas fixtures.

## Verificação

Os testes de interface usam bibliotecas isoladas e fixtures de reprodução,
sem modificar a biblioteca pessoal. Cobrem navegação/histórico, busca global
com barra lateral oculta, filtro, edição de texto, ajuda/Esc, mute/volume,
seleção nativa/Return/Espaço, reprodução de coleção, Tab nos sliders,
confirmação de Info em lote, janela auxiliar e ocorrência repetida após mover
uma linha. A regressão inclui reprodução por clique em playlist e artista.

Os testes unitários verificam catálogo, resolução de alvo, proteção do editor,
seleção em lote, ocorrências repetidas, volume compartilhado, respondedor nativo
e troca de janela. A regressão inclui reprodução, contexto de origem,
coordenação de dados, pesquisa, menus nativos e tabela da fila.

O bloqueio de autenticação das tentativas anteriores não ocorreu nesta execução.
O layout ativo foi Colemak; outros layouts físicos não foram exercitados. O teste
de Tab ativa a navegação por teclado apenas nos argumentos do aplicativo de teste,
sem alterar as preferências globais do macOS.

Resultado após as correções: compilação aprovada, **55 testes unitários e 11
cenários de interface passaram**, considerando as reexecuções dos cenários
corrigidos. O teste de Tab deixou de depender do item dinâmico “Fill” do menu
Window; a validação usa a janela existente. A ajuda também foi conferida por
captura de tela. O diff passou na verificação de whitespace. Não houve alteração
de bindings, schema ou cliente GTK.
