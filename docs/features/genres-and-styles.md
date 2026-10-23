# Gêneros e estilos — fase 3, item 6

Implementação local no macOS e na API compartilhada do core, em 23/10/2026.
Este incremento entrega exploração offline; o roteiro de integração externa
continua separado.

## Interface

- **Gêneros e estilos** na seção Biblioteca da sidebar esquerda.
- Visão geral com busca, seleção de gêneros/estilos/todos e ordenação por nome
  ou quantidade de álbuns. Apenas termos com conteúdo local aparecem.
- **Sem gênero** consulta conteúdo não classificado; não cria um gênero no banco.
- Detalhes por identidade, com abas Álbuns, Artistas e Músicas, busca e mais páginas.
- **Bem avaliados na sua biblioteca** usa avaliações pessoais dos álbuns a partir
  de 4 estrelas, ordenadas por avaliação e identidade. Exclui álbuns ocultos e
  sinalizados para sugerir menos; não apresenta avaliações externas.
- Reprodução e shuffle usam todas as músicas elegíveis da seleção, inclusive
  as que ainda não apareceram na paginação. Iniciar pela posição de uma faixa
  preserva o conjunto completo da origem para repeat/shuffle.
- As faixas reutilizam a linha de coleção, seus menus e destaque contextual.
- Links e edição de classificação nos álbuns e na aba Gêneros e estilos da Info
  de faixa. Artistas mostram um resumo navegável dos lançamentos da biblioteca.
- Voltar/avançar preserva consulta, filtro, aba, páginas carregadas e posição
  de rolagem por entrada do histórico, enquanto os dados permanecem válidos.

## Classificação local

Gêneros e estilos têm vocabulários e associações separados. A tabela `genres`
existente e seus IDs são preservados. Chaves normalizadas usam Unicode NFC,
minúsculas e espaços condensados; grafia original e pontuação são preservadas.
Não se dividem valores em barras, vírgulas ou hífens. Vários valores explícitos
do campo Genre permanecem separados. Campos textuais desconhecidos chamados
STYLE ou STYLES fornecem estilos quando o leitor de tags os disponibiliza.

Dados já guardados no cache de edição fornecem gêneros imediatamente. A versão
de leitura dos metadados passa de 8 para 9: o próximo scan relê arquivos antigos
uma vez para guardar vários gêneros e estilos. Depois, arquivos inalterados
voltam a ser ignorados pelo scan incremental. Abrir páginas não lê arquivos
de áudio nem consulta a rede.

Os gêneros existentes em `local_release_metadata` permanecem classificados como
metadados do catálogo local. Não recebem procedência Discogs/MusicBrainz inventada,
nem são convertidos automaticamente em estilos.

Política inicial, independente por campo:

1. Uma decisão explícita no item substitui o campo inteiro. Uma lista vazia
   bloqueia a classificação e a herança nesse item. Remover a decisão restaura
   os metadados de origem.
2. Na faixa, o gênero editado no cache de metadados prevalece sobre a evidência
   original do arquivo; um campo explicitamente vazio não herda do álbum.
3. Sem decisão, os valores diretos do arquivo ou catálogo são utilizados.
4. A faixa só herda do álbum quando não há classificação direta nem bloqueio.
   Não há herança do artista ou de “Various Artists”.

Associação própria do álbum, herança da faixa e descoberta por **Contém faixas**
são origens distintas. Um álbum pode aparecer pela classificação de suas faixas
sem ganhar essa classificação como dado direto. Substituir o campo do álbum
não altera a evidência direta das faixas. Artistas são agrupados pelo artista
do lançamento, não apresentados como tendo uma classificação direta comprovada.
Ocultos ficam fora do conteúdo e das contagens; provedores e repetição de fontes
não multiplicam entidades.

O editor aceita um termo por linha e sugere termos já existentes. As alterações
ficam no banco do aplicativo, sem escrever nos arquivos de áudio. Decisões de
lançamentos sobrevivem à limpeza de órfãos. Decisões de faixas ausentes são
arquivadas e restauradas no reparo explícito; uma decisão existente no destino,
inclusive vazia, tem precedência durante a união de registros.

## Relações e persistência

Estilos não ganham gêneros pais por coocorrência. **Relacionar gêneros** no detalhe
do estilo registra uma relação explícita definida pelo usuário, com procedência
manual. Essa relação permite navegar gênero → estilo → conteúdo, sem classificar
automaticamente uma faixa ou álbum no gênero relacionado.

A migração é aditiva, transacional e idempotente. As tabelas de decisões, evidências
de arquivos e projeções têm FKs reais para faixas/lançamentos e índices nos dois
sentidos. Uma projeção suja é reconstruída em uma transação consistente, fora
da interface, após alterações relevantes. Dados de origem não são sobrescritos
pela projeção.

A API oferece termos, links com procedência, páginas de conteúdo com contagens,
conjunto completo de reprodução, decisões de classificação e relações explícitas.
As páginas aceitam de 1 a 200 itens por tipo de conteúdo, com ordenação estável.
O cliente carrega 100 por vez. O GTK pode consumir os contratos, mas não recebeu
uma interface neste incremento.

## Limites deste incremento

Vocabulário Discogs versionado, correspondências verificadas MusicBrainz,
enriquecimento externo de gêneros/estilos, aliases/traduções editoriais, hierarquia
de subgêneros, ranking externo e novas regras de playlists inteligentes ficam
para os estágios seguintes do roteiro específico. Termos legados continuam úteis
sem exigir essas integrações. Não foram criadas relações externas presumidas.

## Validação

- 6 testes específicos do core: IDs legados, normalização, valores compostos,
  múltiplos gêneros/estilos, herança, exclusões, relações, contagens, ocultos,
  avaliação pessoal, paginação e reprodução além da primeira página.
- 32 testes de integração da biblioteca passaram, incluindo rescan, reinício,
  reparo explícito de ausentes e atualização única dos metadados antigos.
- Regressões passaram: 23 testes de operações do banco, 28 relacionados a
  metadados e 2 de reparo. Alguns desses filtros incluem testes em comum.
- 52 testes Swift passaram, incluindo ponte real Swift/Rust, filtros,
  identidade das rotas e regressões de Home, menus, atalhos, tags e Para ouvir.
- 2 testes de interface passaram: navegação gênero → estilo → conteúdo,
  abas, retorno pelo histórico e links dos álbuns; edição de estilo,
  persistência ao reabrir e filtro Sem gênero. Capturas dos detalhes e dos
  álbuns foram inspecionadas.
- Uma biblioteca sintética com 5.003 faixas validou índices, contagens e páginas;
  a projeção/consulta/reprodução completa do cenário levou aproximadamente 50 ms
  nesta máquina. É uma medida pontual de fixture, não uma garantia de latência.
- Biblioteca embarcada e bindings Swift/FFI atualizados juntos; compilação macOS
  e verificação de whitespace aprovadas.

O teste antigo `TrackMetadataLayoutTests.testRenderMetadataWindow` falhou ao
montar uma janela com `InvalidTransition ... removedFromContainer`. A mesma
falha foi reproduzida numa cópia intacta do commit `ebf1b0a`, anterior a esta
implementação. Os dois fluxos visuais novos passaram após desbloquear a sessão
do macOS; não há alteração nesse teste antigo.
