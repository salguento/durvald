# Play no hover e reprodução da coleção de origem

Implementado em 19/10/2026 no core e no cliente macOS.

## Comportamento

- Nas linhas de playlist, álbum e Replay, a área do número vira um botão de play
  ao passar o mouse sobre a linha. O mesmo controle atende os rankings e faixas
  locais do artista. Quando recebe foco por teclado, o botão também mostra o ícone.
- Um clique inicia a ocorrência escolhida e substitui a fila da reprodução anterior.
  A faixa escolhida permanece como início mesmo com shuffle já ligado.
- A origem completa é enviada ao core. A fila visível é uma projeção dessa origem,
  não a única cópia da coleção disponível para repeat e shuffle.
- Exemplo, origem `[1, 2, 3, 4]`, clique na faixa 3: sem shuffle, a fila é `[3, 4]`.
  Em Repetir Tudo, após a 4 inicia um novo ciclo `[1, 2, 3, 4]`.
- Com shuffle, a faixa clicada toca primeiro e todas as demais entram aleatoriamente,
  incluindo as anteriores na ordem original. O próximo ciclo também é embaralhado.
- Desligar shuffle mantém o áudio atual e recompõe somente as seguintes na ordem
  original. Religá-lo inclui novamente todas as demais ocorrências elegíveis.
- Repetir Uma Faixa continua repetindo a faixa atual.
- Adições manuais são preservadas. Remoções explícitas da fila são respeitadas nas
  próximas reconstruções; limpar a fila descarta a origem completa da sessão.

## Implementação

`play_collection` é a operação compartilhada de início. Valida IDs, contextos e
posição, busca os metadados em lote e prepara o áudio antes da substituição.
Falha de validação ou de preparação não deixa a reprodução com uma fila parcialmente
apagada. Swift envia a coleção inteira em uma chamada e publica seu snapshot.

Cada ocorrência mantém posição original e contexto de destaque. Isso distingue
faixas repetidas em playlists e preserva o destaque contextual durante shuffle,
avanço, retorno e transições gapless. A ordem canônica é capturada no início da
reprodução; mudanças posteriores na playlist não reescrevem a sessão já iniciada.

O envelope de sessão evolui para a versão 2 quando existe uma coleção completa.
Armazena IDs, contextos, posições e exclusões; caminhos são resolvidos novamente
na restauração. Sessões antigas permanecem compatíveis. Quando não é possível
resolver toda a origem salva, a fila recuperável continua disponível sem presumir
uma coleção completa válida para reconstrução.

## Validação

- Regressão Rust: 348 testes passaram, três ignorados e três falhas preexistentes
  excluídas, conforme o registro da entrega de destaque contextual.
- Reprodução: 48 testes passaram, incluindo início no meio, repetição desde o
  começo, reversibilidade do shuffle, duplicatas, restauração, adições/remoções
  manuais, limpeza explícita e falha de preparação sem substituir a fila.
- Teste de player confirma o retorno gapless à primeira faixa após começar pela última.
- Testes reais de interface verificam o clique único no play da terceira faixa
  da playlist e do ranking do artista, o avanço automático do indicador no álbum
  e a ausência de destaque no álbum quando a reprodução veio de uma playlist.
  A execução usa um identificador exclusivo de testes para não conflitar com o
  aplicativo aberto; o identificador do projeto permanece inalterado.
- A suíte de testes macOS passou com as duas falhas visuais previamente registradas
  excluídas. Testes novos verificam que Swift envia a origem completa, a posição
  escolhida e todos os contextos, preservando a preferência atual de shuffle.
- Bindings Swift/UniFFI e biblioteca embarcada regenerados; smoke test UniFFI passou.
- Rodada final conjunta: 28 testes unitários macOS e quatro testes de interface
  passaram. A compilação com o identificador normal do aplicativo também passou.

Referência das falhas preexistentes: [destaque contextual](contextual-track-highlighting.md).

A validação do artista também corrigiu a altura mínima da seção de destaques:
um bloco de lançamento recente vazio não pode fazer o `LazyHStack` desenhar a
última linha do ranking fora da área interativa do scroll horizontal.
