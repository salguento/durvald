# Novidades dos artistas seguidos — fase 4, item 10

A página **Novidades** fica abaixo de **Início** na sidebar e reúne lançamentos
dos artistas que o usuário segue. Seguir é independente de favoritar. A
preferência migra da lista local anterior uma vez por biblioteca; deixar de
seguir não pode ser desfeito por uma nova importação dessa lista antiga.

## Escopo e fonte

O primeiro provedor é MusicBrainz. A integração reutiliza o catálogo paginado,
a identificação explícita de artistas, os validadores HTTP, os controles de
limites, as tentativas e os ajustes de enriquecimento existentes. Não tenta
adivinhar identidades pelo nome. Quando faltam identificação ou há tags
conflitantes, a página orienta abrir o artista e revisar sua identificação.

A unidade é o **release group**. Edições do mesmo grupo e créditos de mais de
um artista seguido produzem uma única novidade. Este incremento não anuncia
reedições de grupos antigos. Ele inclui:

- Primeiros lançamentos nos últimos 90 dias.
- Datas futuras informadas pela fonte nos próximos 365 dias.
- Datas parciais cujo intervalo inteiro está nessa janela. Um mês que contém
  a data atual aparece como **Data parcial**, sem inventar o dia de lançamento.

Datas desconhecidas, inválidas ou vagas demais ficam fora. A data de inclusão
no banco nunca substitui a data de lançamento. MusicBrainz é colaborativo e não
constitui um feed completo de anúncios: lançamentos futuros podem faltar ou
ter suas datas alteradas. Marcar um anúncio como visto continua valendo quando
o lançamento passa de futuro para recente.

A fonte e a data da consulta aparecem junto dos itens; os artistas seguidos
mostram a última consulta bem-sucedida, problemas e se o catálogo está completo.
A arte reaproveita as capas já disponíveis no cache, com placeholder quando não
há imagem. Abrir o item usa a página local, quando identificada, ou a página do
lançamento externo. É possível salvar em **Ouvir depois**, marcar como visto,
pesquisar por título/artista, filtrar e ordenar pela topbar.

## Atualização e armazenamento

`artist_follows` persiste preferências, geração do acompanhamento, identidade
da consulta, resultado, próxima tentativa e datas de atualização. As tabelas
`artist_news_items` e `artist_news_links` mantêm o conteúdo, vínculos com os
catálogos publicados e marcações de visto. O estado permanece na biblioteca,
inclusive após reiniciar o aplicativo.

A leitura da página é local. Ela projeta somente gerações publicadas do
catálogo e da identidade atual, exclui artistas não seguidos e preserva o
último conteúdo enquanto uma nova geração está sendo construída. Uma geração
parcial não substitui a anterior. A paginação retorna até 100 itens por chamada;
a interface solicita 40 e oferece **Carregar mais**.

Ao visitar a página com dados on-line ativos, são atualizados sequencialmente
até oito artistas pendentes, priorizando os menos recentemente consultados.
Consultas concluídas têm intervalo de um dia; atualizações parciais podem ser
retomadas depois de 30 segundos; falhas temporárias aguardam 15 minutos. O
limite informado pela fonte prevalece. O botão **Atualizar** permite iniciar
outro lote ou revalidar o cache, preservando os limites globais do transporte.
Não há daemon ou polling contínuo enquanto a página não está aberta.

Sair da página ou clicar em **Cancelar** cancela o lote. Deixar de seguir muda
a geração do acompanhamento; a atualização verifica essa geração a cada
250 ms e descarta resultados obsoletos. Identidades alteradas invalidam os
vínculos anteriores. Uma atualização compartilhada com outra tela pode continuar
para esse outro consumidor, sem reinserir novidades do artista não seguido.

Modo offline e dados on-line desativados mantêm o cache navegável. Erros não
bloqueiam biblioteca ou reprodução. Limpar dados do MusicBrainz também remove
o cache de novidades e suas marcações de visto, invalidando os catálogos publicados
que alimentam a página para impedir sua recriação a partir do cache antigo. Os
artistas seguidos e os dados locais são preservados.

## Condições do provedor consultadas

- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API): leituras públicas
  não exigem chave; deve ser enviado User-Agent identificável. Uso comercial
  requer avaliar as condições/plano de serviço do provedor antes da distribuição.
- [Limites de acesso](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting):
  a integração existente compartilha o intervalo de uma requisição por segundo
  em todo o processo, com cooldown em respostas de limite.
- [Licenças dos dados](https://musicbrainz.org/doc/About/Data_License): dados
  centrais e suplementares têm licenças distintas. Este recurso usa somente os
  campos centrais de catálogo para a projeção; preserva a atribuição fornecida
  pelo adaptador e apresenta um link direto para o registro de origem.

Nenhum novo provedor, credencial ou autorização de rede é ativado implicitamente.
Os controles atuais de dados on-line e modo offline continuam obrigatórios.

## Validação

Testes do core cobrem datas completas/parciais, ausência de data, grupos antigos
adicionados agora, deduplicação entre artistas, marcação de visto, paginação,
filtros, importação única, descarte de respostas de uma geração antiga e remoção
de cache preservando acompanhamentos. Testes Swift cobrem troca de pesquisa,
erros com cache, cancelamento e tamanho dos lotes. Um teste com core real reabre
a biblioteca para verificar persistência sem rede; o teste de interface usa
catálogos locais isolados para navegação, pesquisa e envio a Ouvir depois.

A regressão do core foi executada com duas falhas preexistentes excluídas:
`similar_artist_snapshot_materializes_targets_and_their_identities_atomically`
e `legacy_rows_survive_migration_and_reopening`. Os testes específicos deste
recurso não têm exclusões. O teste visual depende do Mac desbloqueado; quando
o runner não consegue iniciar por autenticação do macOS, isso não constitui
uma aprovação da interface.

Validação visual concluída em 26/10/2026 com o Mac desbloqueado. O teste de
interface passou: posição abaixo de Início, lançamentos recentes/futuros,
salvamento em Ouvir depois, marcação de visto, pesquisa sem resultados, retorno
da lista e persistência após reiniciar. A captura da página também foi revisada.
As verificações usam os identificadores dos botões acessíveis de lançamento e
o campo `.field` da pesquisa compartilhada, incluindo sua expansão compacta.
