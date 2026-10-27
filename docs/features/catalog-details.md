# Detalhes progressivos e seleção persistente — etapa 4

Entrega de 27/10/2026 do [roteiro de integrações musicais](../roteiro-integracoes-musicais.md),
construída sobre a [busca de catálogo](catalog-search.md).

## Comportamento

Resultados externos oferecem **Ver detalhes**. A tela mostra imediatamente o
título, crédito e versão já presentes no resultado, sem materializar um registro
local. Os demais blocos carregam separadamente, com erro e tentativa próprios:

- Artista: identidade, retrato, perfil, discografia e similares.
- Grupo de lançamentos: identidade/créditos, capa e edições paginadas.
- Edição escolhida: identidade/créditos, capa e faixas da edição.
- Gravação: identidade e créditos básicos.

Abrir uma edição é uma escolha explícita na lista; não se elege silenciosamente
uma edição nem se transforma uma tracklist em faixas locais reproduzíveis.
Faixas sem identidade de gravação preservam o identificador de faixa da edição
fornecido pelo MusicBrainz, sem fabricar uma gravação.

Imagens e biografias podem faltar ou falhar sem ocultar a identidade. As imagens
usam os limites de download/decodificação existentes; perfis e imagens preservam
fontes, autor e licença quando fornecidos. Dados factuais do Wikidata e texto da
Wikipedia conservam suas atribuições separadas. Se a introdução da Wikipedia
falhar, o perfil factual disponível continua sendo retornado.

## Ações explícitas

**Salvar** guarda uma referência mínima. Para artistas, reutiliza a materialização
externa existente, com identidade por provedor/ID e eventual MBID confirmado.
Para lançamentos, edições, gravações e outras referências, guarda apenas a
seleção; não cria músicas, arquivos, favoritos ou histórico. O botão **Itens
salvos**, em Explorar, permite reabrir as seleções depois de reiniciar o aplicativo.

**Seguir/Deixar de seguir** reutiliza a feature de artistas seguidos. A ação de
seguir também salva/materializa somente o artista necessário. **Ouvir depois**
integra grupos de lançamentos MusicBrainz à Listen List existente, usando o
artista identificado no crédito carregado. Repetir a ação não duplica o item.
Salvar uma seleção e adicioná-la à Listen List são intenções distintas.

**Onde ouvir** e **Onde baixar** estão identificadas e indisponíveis nesta etapa:
o plugin atual fornece catálogo/metadados e ainda não há integração de fontes,
reprodução ou download. Não são disparadas resoluções ou transferências fictícias.
Essas ações serão habilitadas nas etapas dos respectivos adaptadores.

## Identidade e persistência

`CatalogReference` contém provedor, tipo e identificador opaco. `CatalogEntry`
adiciona os dados básicos de apresentação. Provedores sem MBID podem persistir
referências provisórias, incluindo perfis, faixas e vídeos, sem converter seus
IDs para MusicBrainz. A identidade inclui o tipo; caixa e conteúdo de IDs de
outros serviços são preservados. A normalização de UUID aplica-se ao MusicBrainz.

A migração **20** cria `catalog_selections`, com chave única composta por
provedor/tipo/ID, payload mínimo, data e associação opcional ao artista local.
Salvar é transacional e idempotente, inclusive com chamadas concorrentes:
a primeira seleção é preservada. Artistas reutilizam as regras existentes de
identidade dentro da mesma transação. Outros alvos não materializam um artista
ou importam o catálogo relacionado. Desabilitar o plugin não apaga seleções.

Não há associação por igualdade de nome: homônimos continuam separados.
A referência sem MBID é a fundação para serviços futuros; os detalhes remotos e
as ações específicas de cada serviço dependem de seu adaptador. A Listen List
existente continua aceitando seus tipos atuais; ampliar essa intenção para
outros tipos/provedores pertence à etapa correspondente do roteiro.

## Execução e cache

A API pública é aditiva: `CatalogSearchSession.detail_section` solicita um bloco
por referência, idioma, cursor e geração. A sessão mantém gerações de detalhe
separadas da busca. Trocar referência/idioma exige nova geração; fechar/cancelar
invalida as respostas pendentes sem afetar outra sessão.

O runtime despacha metadados com os limites e cancelamento da etapa 2. Cada
transporte aplica o cooldown de seu próprio host; uma falha de Wikimedia ou CAA
não deve estabelecer cooldown de MusicBrainz. Cache de detalhe v1 inclui
referência, bloco, idioma e cursor, com validade de 15 minutos e armazenamento
HTTP separado do catálogo pessoal. Respostas reutilizadas recebem a geração do
consumidor atual. Cursores de edições/discografia são versionados e vinculados à
referência, ao bloco e ao idioma, com lotes de até 20 itens.

Os provedores existentes são reaproveitados para Wikimedia, Cover Art Archive e
Last.fm. Similares são opcionais e dependem da configuração Last.fm existente;
os candidatos não são materializados por uma leitura. Lookups e navegação
MusicBrainz seguem seu [contrato de API](https://musicbrainz.org/doc/MusicBrainz_API).

A apresentação Swift publica os blocos independentemente, descarta gerações
antigas e preserva itens durante falhas de paginação. Uma resposta de salvar
anterior também não substitui o estado de uma nova seleção. Gravações explícitas
já iniciadas podem terminar após fechar a tela; abrir e ler nunca salva.

A fachada expõe leitura/listagem/salvamento de seleções, seguir e inclusão na
Listen List através da aplicação e de operações nomeadas do adaptador SQLite.
Não há acesso direto ao banco na fachada ou aplicação. O port antigo de detalhe
básico permanece disponível. DTOs, bindings Swift e biblioteca embarcada são
regenerados em conjunto; o GTK recebe a API comum sem nova tela nesta entrega.

## Validação

Suíte completa Rust: **453 testes aprovados**, sem falhas/exclusões; três testes
previamente ignorados mantidos. Inclui cinco testes novos de metadados com
transporte simulado e cinco testes de fachada para persistência, concorrência,
reinício, homônimos, referência provisória, cancelamento, seguir e Listen List.
Clippy com todos os alvos/features e avisos como erros aprovado.

macOS: **412 testes unitários e dois testes visuais aprovados**. Novos testes
cobrem publicação básica enquanto a capa aguarda, falha/retry independente,
leitura sem salvar, geração obsoleta e salvamento atrasado durante troca de alvo.
O teste visual abre, salva e reabre os detalhes após uma falha simulada de perfil.
As capturas foram conferidas; chamadas externas reais não são usadas nos testes.
A rodada usa a opção temporária `ENABLE_APP_SANDBOX=NO` para o teste existente de
captura de metadados em `/tmp`, sem mudar a configuração do projeto.
