# Comandos e atalhos de teclado no macOS

Implementação do recorte 5 do [inventário](../inventario-atalhos.md), em 20/10/2026.
A validação interativa está pendente pelo bloqueio de autenticação descrito abaixo.

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
| Ajuda de atalhos | `⇧⌘/` |

A ajuda abre pelo menu Ajuda e mostra a disponibilidade do contexto em que foi
aberta. O grupo nativo de novos itens é substituído pelas ações de criação de
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

A tabela de músicas publica sua seleção múltipla somente quando a página está
apresentada. Info reutiliza a confirmação existente de edição em lote e sua
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

## Verificação

- Testes unitários de catálogo verificam unicidade de IDs e combinações, resolução
  de alvo por contexto, proteção durante edição, seleção em lote, ocorrência
  repetida da playlist e restauração compartilhada de volume.
- A regressão macOS cobre reprodução, contexto de origem, coordenação de dados,
  pesquisa, menus nativos e tabela da fila.
- Foram adicionados testes de interface para texto com espaços, navegação por
  `⌘←` no editor, destinos, filtro e ajuda. O teste de histórico foi atualizado
  para `⌘[`/`⌘]`.
- Duas tentativas de iniciar o runner de interface foram impedidas pelo macOS:
  `Authentication canceled. System authentication is running.` Os testes não
  chegaram a executar; a validação completa de foco/Tab, layouts de teclado e
  interação real dos menus continua pendente. A autenticação do sistema não foi
  alterada para contornar o bloqueio.

Resultado final: compilação aprovada e 53 testes unitários macOS passaram. O diff
passou na verificação de whitespace. Não houve alteração de bindings ou schema.
