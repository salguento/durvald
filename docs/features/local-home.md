# Home local

A Home mostra dois carrosséis independentes, com até 24 álbuns cada:

- **Escutas recentes:** álbuns únicos pela última entrada no histórico de reprodução.
- **Adicionados recentemente:** primeira entrada de uma faixa local do álbum na biblioteca.

Ambos usam o ID do lançamento como desempate decrescente, excluem lançamentos
ocultos e exigem pelo menos uma faixa local visível. Escutas de faixas ocultas
não promovem álbuns no primeiro bloco. Lançamentos apenas do catálogo externo
não aparecem. O botão “Ver histórico” abre a Retrospectiva existente.

## Persistência e atualização

`home_library(limit)` entrega os dois blocos em uma transação de leitura SQLite,
com limite máximo de 50 por bloco. A consulta resolve os metadados no core e não
depende das páginas de biblioteca que o cliente já carregou.

A inicialização adiciona `release_library_entries` de forma idempotente e preenche
bibliotecas existentes com a menor data de importação disponível por lançamento.
Triggers registram a entrada de novas faixas e mudanças de álbum. A primeira data
é preservada em rescan, enriquecimento e remoção de uma faixa; excluir o lançamento
remove seu registro. Em bases antigas, a data recuperável é a das faixas ainda presentes.

O repositório da Home reutiliza o resultado enquanto as revisões de catálogo e
histórico não mudarem. Enquanto a página estiver aberta, consulta a revisão escalar
do histórico a cada dois segundos. Importação e edição invalidam pelo catálogo;
escutas e limpeza do histórico, pela revisão do histórico. Resultados cancelados
ou com revisão de histórico alterada durante a leitura são descartados. Falhas
mantêm o último resultado e permitem nova tentativa automática.

## Interface e reprodução

Os carrosséis usam `PageViewport`, margens de conteúdo compensadas e
`scrollClipDisabled`, como os rankings da Retrospectiva: cartões podem passar sob
as barras laterais esquerda e direita. Títulos e atalhos ficam na coluna visível.
Há mensagens próprias para cada bloco vazio e estados de carregamento e erro.

Os cartões reutilizam `AlbumCard`, com capa, título, artista, menu contextual,
navegação por ID e play pelo álbum. A reprodução usa `release:<id>`, sem criar
um contexto de mix da Home.

## Validação

- Testes SQLite cobrem limite, deduplicação, ordenação, desempate, ocultação,
  catálogo externo, limpeza do histórico e preservação/backfill da data de entrada.
- Testes do repositório macOS cobrem cache, revisões, retry e leitura concorrente
  com alteração de histórico.
- Teste de interface cobre rolagem com as barras laterais, abertura do álbum e
  navegação para o histórico.

Resultado da validação: 245 testes unitários Rust passaram (três ignorados e as
duas falhas preexistentes de enriquecimento/migração excluídas, conforme
[registro anterior](contextual-track-highlighting.md)); o teste público de
importação/rescan/reinício passou. No macOS, passaram nove testes unitários e um
teste de interface com captura conferida. Compilação, regeneração dos bindings e
smoke UniFFI passaram.
