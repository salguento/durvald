# Coleções — fase 3, item 8

Coleções organizam lançamentos inteiros com identidade própria. Não são playlists
de faixas nem itens de Ouvir depois. O mesmo álbum pode participar de várias
coleções; cada coleção manual inclui uma edição local no máximo uma vez.

## Interface

- **Coleções** na sidebar Biblioteca abre a página central, com busca,
  ordenação por nome ou quantidade e criação pelo menu da topbar ou estado vazio.
- Coleções manuais têm nome, descrição, adição de álbuns da biblioteca, remoção,
  edição e ordem persistida. Os botões de mover respeitam a ordem completa mesmo
  quando a busca esconde outros itens; o menu também ordena por título ou artista.
- O menu de qualquer álbum local oferece **Adicionar à coleção…**, com
  escolha de coleção manual existente ou criação de uma nova coleção.
- Coleções inteligentes têm regras combinadas por todas/qualquer, e ordem por
  título, artista, ano ou avaliação, crescente ou decrescente. Editar as regras
  atualiza o resultado; a inclusão e remoção manual ficam restritas ao modo manual.
- A edição preserva o tipo da coleção. A exclusão exige confirmação e remove
  somente a coleção, mantendo os álbuns da biblioteca e de outras coleções.
- Nome, contagem, busca e opções usam a topbar compartilhada das outras páginas.

## Regras inteligentes

As regras disponíveis são artista (contém), gênero e estilo do álbum, tag do
álbum, contém faixa com tag, ano inicial/final, avaliação mínima e presença de
reprodução no histórico. A avaliação é a nota pessoal do lançamento, em meios
pontos de estrela; não é calculada pelas notas das faixas. “Já reproduzido” exige
ao menos um registro no histórico de alguma faixa, sem afirmar escuta completa.

Gêneros e estilos do álbum excluem associações cuja única origem seja
`contains_tracks`. Tags do álbum consultam vínculos do lançamento; tags de faixas
consultam suas faixas visíveis. Não há herança de tags entre essas entidades.
IDs persistidos preservam filtros ao renomear tags. Referências removidas continuam
identificadas ao editar e produzem nenhum resultado, sem ampliar a seleção.

Regras e campos de ordenação são validados no core antes de gravar, com limites
de nome, descrição e até vinte regras. Valores são parâmetros de consultas SQL;
nenhum campo arbitrário de SQL é aceito. Resultados excluem álbuns ocultos ou sem
faixas disponíveis no catálogo e usam uma identidade estável para desempates.

## Reprodução e indisponibilidade

**Reproduzir** percorre a ordem dos álbuns e, dentro de cada um, disco, número da
faixa e identidade. Iniciar por um álbum mantém o conjunto completo na origem,
para o repeat retornar ao primeiro álbum. O contexto `albumCollection:<id>`
identifica a coleção e a faixa ativa identifica o álbum em reprodução.

**Embaralhar álbuns** sorteia blocos inteiros, preservando as faixas internas.
**Embaralhar músicas** delega o embaralhamento de todas as faixas ao player. A
fila recebe uma cópia da seleção avaliada ao iniciar; mudanças posteriores na
coleção, regras ou biblioteca não reescrevem a sessão em andamento.

Álbuns manuais removidos do catálogo mantêm título, artista e arte armazenados,
com indicação de indisponibilidade. Permanecem ordenáveis e removíveis e são
ignorados na reprodução. Não se tenta vincular uma edição substituta por nome.
A disponibilidade segue o catálogo e seus itens ocultos; erros de abertura de
arquivos continuam sendo tratados pelo player, sem varredura do disco nesta tela.

## Persistência

As tabelas aditivas `album_collections`, `album_collection_items` e
`album_collection_rules` não reutilizam `playlist_songs`. Metadados, vínculos e
ordem sobrevivem ao fechamento e à reabertura. Operações do core são
transacionais; uma reordenação precisa conter todos os itens exatamente uma vez,
para rejeitar duplicatas, alterações incompletas e listas de outra coleção.

Este incremento implementa a interface no macOS e a API compartilhada do core;
o GTK não recebe novas telas.
