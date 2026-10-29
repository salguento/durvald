# Roteiro: gêneros e estilos com Discogs e MusicBrainz

Status: proposta; nenhuma implementação neste documento.
Data: 17/10/2026.

## Direção recomendada

Usar Discogs como referência principal de classificação, distinguindo gêneros
amplos de estilos. Usar MusicBrainz para identidade e classificação complementar,
com correspondências explícitas para o vocabulário do app. IDs internos permanecem
estáveis e podem ter múltiplos identificadores externos. Arquivos e edição manual
preservam a classificação da biblioteca. A página deve funcionar offline.
Catálogo de gêneros e classificação de uma entidade são problemas separados:
conhecer o termo "art pop" não informa quais álbuns ou faixas pertencem a ele.

Uma entidade pode ter vários gêneros e vários estilos. Uma faixa com múltiplas origens de reprodução
continua tendo uma única identidade de catálogo; as origens fornecem evidências,
não criam múltiplas contagens da mesma faixa.

## Fontes e papel de cada uma

| Fonte | Uso recomendado | Limitação a modelar |
| --- | --- | --- |
| Discogs | Referência principal de gêneros e estilos, sobretudo em lançamentos. | Classificação do lançamento não é evidência direta para cada faixa nem perfil de gênero do artista. |
| MusicBrainz | Identidade de artistas, release groups, releases e recordings; classificação complementar. | Um termo chamado gênero no MusicBrainz pode corresponder a um estilo no modelo do app. |
| Tags dos arquivos | Primeiro funcionamento offline e preservação da classificação da biblioteca. | Variações de escrita, valores compostos e divergência entre arquivos. |
| Edição do usuário | Correção, exclusão de associações erradas e gêneros próprios. | Precisa sobreviver a scans e atualizações externas. |

Fontes externas deste planejamento: somente Discogs e MusicBrainz. Last.fm,
Wikidata e análise de áudio ficam fora do escopo. Ausência de credenciais ou de
rede não impede consultar o catálogo persistido e os metadados locais.

MusicBrainz oferece `/genre/all` e lookup de entidades com `inc=genres`. A lista
JSON permite trabalhar com identidades; `fmt=txt` é conveniente para nomes, mas
não substitui um catálogo com IDs. Artista, release-group, release e recording
devem ser consultados segundo sua identidade, e não só por texto.
[Documentação](https://musicbrainz.org/doc/MusicBrainz_API).

Discogs distingue gêneros amplos, como Electronic, e estilos, como Drum And Bass.
Preservar os campos separados na ingestão e na apresentação.
[Diretrizes](https://support.discogs.com/hc/en-us/articles/360005055213-Database-Guidelines-9-Genres-Styles).

## Distinção entre gênero e estilo

- Gêneros são agrupamentos amplos. Estilos são classificações mais específicas,
  mantidas separadamente mesmo quando outro provedor usa o termo "gênero".
- Exemplo: gênero Electronic; estilo Drum And Bass. Uma entidade pode ter mais
  de um gênero e estilo, sem exigir que cada estilo tenha um único pai.
- Não transformar automaticamente todos os gêneros MusicBrainz em gêneros amplos
  nem todos os termos desconhecidos em estilos. Manter pendências de mapeamento.
- Correspondência externa registra `exact`, `broader`, `narrower` ou `unmapped`.
  Só equivalência exata validada unifica conceitos; as demais relações não são aliases.
- Discogs retorna listas de gêneros e estilos para um lançamento; a coocorrência
  não estabelece qual estilo pertence a qual gênero. Não criar produto cartesiano
  de relações. A relação estilo–gênero exige vocabulário verificado e versionado.
- Não pressupor IDs estáveis de conceito no Discogs: usar ID interno e chave de
  vocabulário própria para termos quando a fonte oferecer apenas nomes.
- Popular a base com um snapshot versionado dos gêneros/estilos Discogs após validar
  a fonte de obtenção; manter isso separado da coleta de classificações por entidade.

Prioridade para cada campo de classificação: decisão manual explícita; evidência
Discogs identificada no mesmo escopo; arquivos preservados e evidências MusicBrainz
conforme política configurada. Preservar divergências e procedência. Uma evidência
direta da faixa não é descartada por preferência a um dado Discogs herdado do álbum.
Resultado vazio do Discogs não apaga dados válidos; campo sem evidência pode usar
complemento MusicBrainz. Não unir indiscriminadamente todos os resultados.

## Estado atual e reaproveitamento

- `database/operations.rs` já cria `genres`, com ID, nome e descrição. Não criar um
  catálogo concorrente: migrar a tabela, preservando seus IDs existentes.
- `local_release_metadata` e o catálogo de releases já expõem listas de gêneros.
- `enrichment/providers/musicbrainz.rs` recebe gêneros de releases/release groups,
  ordena por votos e os transforma em nomes. A nova ingestão precisa preservar
  identificadores, entidade de origem e votos quando fornecidos.
- O enriquecimento já possui identidades, gerações, cache e atribuição: estender
  essas fronteiras em vez de criar um segundo agendador de rede.
- Auditar todos os escritores das listas atuais antes de migrar: valores antigos
  não ganham uma procedência específica que não esteja comprovada.

## Identidade, normalização e relações

- `genre_id` e `style_id` internos são as chaves de navegação, nunca os nomes exibidos.
- MBIDs e chaves de termos por provedor ficam em tabelas de mapeamento tipadas;
  IDs de entidades Discogs (artist/master/release) não são IDs de gênero ou estilo.
- Nome canônico, traduções e aliases são campos distintos.
- Normalizar Unicode, caixa e espaços para busca e comparação; manter grafia
  original para apresentação e auditoria.
- Não transformar aproximação textual em equivalência automática: gêneros
  relacionados e subgêneros não são necessariamente sinônimos.
- Termos fora dos vocabulários externos continuam válidos como conceitos locais/customizados.
  Uma correspondência posterior mantém o ID interno e adiciona o vínculo externo.
- Termos ambíguos geram candidato para revisão. Tags não reconhecidas ficam
  pendentes ou como tags gerais, sem poluir automaticamente o catálogo de gêneros.
- Não dividir indiscriminadamente valores em `/`, vírgula ou hífen: pontuação
  pode fazer parte do próprio gênero. Preservar valor bruto e contexto do formato.
- Relações `subgenre_of`, `related_to` e `alias_of` não são intercambiáveis.
  Subgêneros podem ter múltiplos pais; impedir ciclos na hierarquia aceita.
- Não assumir que a lista do MusicBrainz entrega uma hierarquia completa. Começar
  com lista plana; adicionar somente relações verificadas e com procedência.

## Mapeamento para artistas, álbuns e faixas

### Identificar antes de classificar

1. Artista: MBID e/ou Discogs artist ID confirmado, não o primeiro homônimo de busca.
2. Álbum: Discogs master como agrupamento e release como edição; no MusicBrainz,
   release-group e release. Preservar cada namespace e não assumir equivalência
   automática entre agrupamentos dos dois serviços. Confirmar edição usando
   tracklist, formato, catálogo, código de barras, ano e país quando disponíveis.
3. Faixa: recording MBID como identidade da gravação; a faixa/posição da edição
   local não deve ser confundida com o recording ou com a composição/work.
4. IDs em tags ajudam a resolver; título, artista, duração e posição são evidências
   auxiliares. Resultado ambíguo não recebe classificação externa definitiva.
5. A mesma gravação em vários álbuns pode compartilhar evidência direta do recording,
   mas cada faixa local mantém seu contexto de álbum e suas escolhas do usuário.

### Associações diretas e herdadas

Guardar evidência direta separada da projeção usada pela interface. Política
inicial proposta, versionada e testável:

| Alvo | Associação direta | Fallback quando não há classificação direta aceita |
| --- | --- | --- |
| Artista | Edição manual e evidência específica MusicBrainz. | Resumo derivado dos lançamentos Discogs identificados, marcado como agregado; sem inventar classificação direta Discogs. |
| Álbum | Edição manual, Discogs release/master, tags locais e MusicBrainz release/release-group. | Classificação do artista somente como herança explícita, em álbum não compilação. |
| Faixa | Edição manual, tag do arquivo, evidência externa da gravação/faixa. | Primeiro o álbum; artista somente se não houver classificação efetiva do álbum e a identidade for segura. |

As linhas são uma proposta de produto, não uma propriedade das fontes externas.

Aplicar as regras separadamente a gêneros e estilos. No álbum, release Discogs
identificada tem prioridade sobre master; master serve como fallback identificado.
Não assumir gêneros/estilos diretos no tracklist Discogs: a classificação da faixa
por esse caminho é herdada do lançamento e precisa ser identificada assim.
Resumo do artista conta cada álbum conceitual uma vez, sem dar peso extra a
reedições; distingue discografia conhecida de conteúdo disponível na biblioteca.

- Gêneros diretos aceitos impedem adicionar indiscriminadamente todos os gêneros
  do artista como fallback. A interface pode mostrar evidências complementares.
- Remoção manual deve gerar exclusão persistente; refresh não pode reinseri-la por
  outra rota de herança. Permitir bloquear também todo enriquecimento de uma entidade.
- Edição manual pode acrescentar gêneros ou substituir a classificação efetiva;
  o modo escolhido precisa ser explícito e persistido.
- Em compilações, não propagar o gênero de "Various Artists"; priorizar gravações
  e evidências do álbum. Colaboração não recebe a união de todos os gêneros dos convidados.
- Uma exclusão de gênero descendente não exclui automaticamente seu pai e vice-versa.
- Preservar contagem bruta/votos e calcular relevância por provedor. Não apresentar
  scores internos como probabilidade objetiva. Calibrar limiares com fixtures reais.
- Não manter herança materializada como se fosse evidência direta; recalcular ao
  mudar identidade, fonte, regra ou decisão do usuário.

## Banco proposto

| Estrutura | Responsabilidade |
| --- | --- |
| `genres` existente, ampliada | Identidade canônica estável e estado local/externo. |
| `styles` | Identidade estável do estilo, separada do gênero. |
| `style_genres` | Relações verificadas muitos-para-muitos, com procedência e versão. |
| `genre_external_ids` / `style_external_ids` | IDs/chaves por provedor, tipo de correspondência e revisão; não presumir que nomes sejam IDs externos. |
| `genre_names` / `style_names` | Nome por idioma, aliases, origem e chave normalizada de busca. |
| `genre_relations` | Relações verificadas e respectivas fontes. |
| `artist_genre_evidence` | FK real para artista; gênero, fonte, valor bruto, entidade externa, votos, geração, datas e atribuição. |
| `release_genre_evidence` | Mesmo contrato com FK real para álbum, distinguindo release e release-group. |
| `track_genre_evidence` | Mesmo contrato com FK real para faixa, podendo registrar a origem local/remota que forneceu a evidência. |
| `artist_style_evidence`, `release_style_evidence`, `track_style_evidence` | Associações de estilos com as mesmas garantias de integridade e procedência. |
| Decisões por artista/álbum/faixa | Inclusões, exclusões e modo manual com FKs reais. |
| Projeções efetivas por tipo | Gêneros e estilos consultáveis separadamente, com origem direta/herdada/agregada e versão da política. |

Evitar uma coluna polimórfica sem integridade referencial para ligar entidades.
JSON de payload pode ser cache bruto, mas navegação e filtros usam relações indexadas.
Índices nos dois sentidos: entidade → gêneros e gênero → entidades.

Migração aditiva, transacional e idempotente; preservar nomes legados e IDs. Aliases
ambíguos não são fundidos silenciosamente. Listas legadas continuam compatíveis
até todos os leitores passarem para a projeção; depois têm uma única origem de
escrita ou viram saída derivada, evitando duas verdades concorrentes.
Metadados legados chamados "gênero" podem corresponder a estilos: preservar seu
valor bruto e migrar somente correspondências verificadas, sem reclassificação cega.

## Página Gêneros

Adicionar entrada na biblioteca e rota por `genre_id` no histórico de navegação.
O detalhe de estilo tem rota própria por `style_id`.

**Visão geral:** busca por nome/alias, ordem alfabética ou quantidade na biblioteca,
cartões com nome, contagens e arte derivada das capas. Por padrão, mostrar gêneros
com conteúdo na biblioteca, e não milhares de cartões vazios do vocabulário.
Gêneros sem classificação ficam em um filtro "Sem gênero", não em uma entidade falsa.

**Detalhe de gênero:** nome, descrição quando houver, estilos associados com conteúdo e abas
Álbuns, Artistas e Músicas usando os componentes existentes. Incluir reprodução
e shuffle de faixas disponíveis, filtros e criação de playlist inteligente por ID.
Descrições e nomes traduzidos devem ter origem própria, sem traduções inventadas.

**Detalhe de estilo:** mesma estrutura de conteúdo, com links para gêneros
relacionados. Exemplo de percurso: Gêneros → Electronic → Drum And Bass → Álbuns.
Permitir filtro por estilo e busca simultânea de gêneros e estilos, identificando
o tipo de cada resultado. A classificação do álbum exibe campos separados
"Gêneros" e "Estilos", ambos navegáveis.

**Links:** gêneros e estilos nas páginas de artista e álbum e nas informações da faixa abrem
o mesmo detalhe. Voltar/avançar restaura filtros, aba e posição de rolagem.

**Semântica de contagens:**

- Deduplicar por entidade local, sem multiplicar por provedor ou origem de playback.
- Um álbum pode aparecer porque tem associação própria/herdada ou porque contém
  faixas do gênero. Identificar "contém faixas" sem reclassificar o álbum inteiro.
- Um artista pode aparecer por associação própria ou por conteúdo relacionado na
  biblioteca; diferenciar "artista deste gênero" de "tem faixas neste gênero".
- O resultado exibido e sua contagem devem usar o mesmo modo e predicado.
- No MVP, gênero exato. "Incluir subgêneros" vem depois e é opção explícita;
  computar união de IDs, nunca soma ingênua das contagens dos filhos.
- Filtrar por estilo usa associações efetivas do estilo. Sua relação com um gênero
  não cria automaticamente uma classificação direta de gênero na entidade. Se o
  produto habilitar inclusão derivada, marcá-la e deduplicar suas contagens.
- Mesma faixa em vários álbuns locais continua seguindo a identidade do catálogo
  existente; não fazer merge de faixas como efeito colateral desta função.

## Implementação em estágios separados

| Etapa | Entrega | Critério de conclusão |
| --- | --- | --- |
| 1 | Contratos e migração de gêneros, estilos e evidências locais. | IDs existentes preservados; tipos separados; migração repetida não duplica. |
| 2 | Vocabulário Discogs versionado, relações verificadas e mapeamento MusicBrainz. | Estilos não viram gêneros amplos; termos ambíguos ficam pendentes; catálogo offline funciona. |
| 3 | Identificação Discogs de artista/master/release e ingestão de gêneros/estilos de lançamentos. | Reedições e compilações identificadas; prioridade release/master testada; cache persistente. |
| 4 | Identidade e evidências complementares MusicBrainz de artista, release-group/release e recording. | MBIDs preservados; correspondências explícitas e nenhum overwrite cego dos dados Discogs. |
| 5 | Projeções efetivas e resumo agregado de artistas; consultas paginadas no core. | Direto/herdado/agregado distinguíveis, contagens deduplicadas e exclusões persistentes. |
| 6 | Página Gêneros, detalhe de gênero/estilo e links no macOS; contratos consumíveis pelo GTK. | Percurso gênero → estilo → conteúdo, navegação e reprodução acessíveis e offline. |
| 7 | Edição, revisão de correspondências, filtros e playlists inteligentes. | Regras independentes por gênero e estilo; correções sobrevivem ao enriquecimento. |
| 8 | Estabilização, desempenho e migração final de leitores legados. | Sem duas fontes de escrita; fixtures dos dois provedores e grandes bibliotecas aprovadas. |

A etapa 1 contém um caminho mínimo de edição/exclusão no core; a etapa 7 é sua
interface completa. Discogs é parte central da primeira entrega completa, e não
um complemento tardio. Last.fm, Wikidata e análise de áudio não são dependências.

## Cache, desempenho e testes

- Reutilizar limites, retries, modo offline e cache negativo do enriquecimento.
  Carregar páginas não dispara varredura integral da biblioteca na rede.
- Preservar dados bons após erro temporário; distinguir resposta vazia válida de
  transporte indisponível. Mudança de identidade invalida evidências antigas.
- Computar projeções em background e publicar uma geração consistente. Sem rede
  em transação SQLite e sem atualização parcial de contagens na mesma página.
- Testar aliases com acentos, sinônimos, nomes compostos, gêneros locais, múltiplas
  fontes, exclusão manual, recording repetido em edições e identidades ambíguas.
- Testar faixas sem gênero, herança sem ciclos, compilação e origem remota sem arquivo.
- Testar gênero sem estilo e estilo sem gênero mapeado; o estilo não pode ser
  descartado nem associado arbitrariamente a um pai só para completar a interface.
- Testar divergências Discogs/MusicBrainz, ausência de campo versus falha de rede,
  múltiplas edições do mesmo master e exclusões manuais independentes por tipo.
- Medir query plan e tempo de páginas/contagens em biblioteca grande; paginação,
  ordenação e reprodução do conjunto completo não podem depender da página carregada.
- Não gravar tags nos arquivos automaticamente; persistência no app e exportação
  de metadados para arquivos são operações distintas.
