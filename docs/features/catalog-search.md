# Busca de catálogo local e MusicBrainz — etapa 3

Entrega de 27/10/2026 do [roteiro de integrações musicais](../roteiro-integracoes-musicais.md).

## Uso

A página de resultados oferece Biblioteca/Explorar e Tudo/Artistas/Lançamentos/Faixas.
Biblioteca preserva as prateleiras, menus e ações locais existentes. Explorar
mostra duas seções independentes, Sua biblioteca e MusicBrainz, com resultados
leves, identidade, crédito e informação de desambiguação quando disponível.
Digitar continua consultando somente a biblioteca para as sugestões; o texto
executado muda no envio. Entrar em Explorar, mudar o filtro, carregar outra página
ou tentar novamente são ações explícitas sobre a pesquisa enviada.

A seção local aparece sem esperar a rede. Cada seção em Explorar tem carregamento,
continuação e erro próprios. Uma falha ao carregar outra página preserva os itens
anteriores. A ação de um resultado local navega para o item ou toca uma faixa;
a ação externa abre seu endereço canônico no MusicBrainz. Não há adesão automática,
importação, enriquecimento de candidatos ou reprodução remota.

O MusicBrainz interno começa habilitado em instalações sem preferência anterior,
sem credenciais e sem tráfego na abertura do core. Desativar/ativar na própria
seção persiste a escolha; reiniciar respeita desativação e remoção anteriores.
Preferências corrompidas não impedem abertura ou consulta da biblioteca.

## Contratos e execução

- `DurvaldCore::catalog_search_session` cria uma sessão independente por consumidor.
  `CatalogSearchSession::search_page` recebe provedor, consulta, escopo, filtro,
  idioma, tamanho, cursor, geração e indicação de leitura exclusiva de cache.
- Cada página retorna provedor e geração, itens com identidade explícita,
  continuação, origem em cache e falha estruturada com espera quando disponível.
- Gerações positivas crescentes cancelam a pesquisa anterior da sessão. Reutilizar
  uma geração com outro texto/filtro/idioma é inválido; os provedores e cursores
  podem variar nessa mesma geração. Cancelar ou fechar não afeta outras sessões.
- O runtime mantém limites de concorrência, fila, timeout, cancelamento e ciclo
  de vida do plugin da etapa 2. Os clientes existentes mantêm o gate MusicBrainz.
- A fachada não usa operações do banco. A aplicação coordena o adaptador local e
  o runtime. A composição fornece o plugin real; o adaptador MusicBrainz não tem
  referência ao catálogo pessoal, histórico, preferências pessoais ou player.

## Busca leve e paginação

O adaptador usa os índices `artist`, `release-group` e `recording`. Tudo consulta
os três; os demais filtros consultam um. Não há lookup de detalhe por resultado.
URLs MusicBrainz de artista, grupo de lançamentos, edição e gravação usam uma
consulta direta. O adaptador constrói o endpoint oficial a partir de tipo/MBID;
URLs de outros hosts, credenciais na URL e identificadores inválidos são rejeitados.

O tamanho aceito pela fachada é 1–50 **por tipo**. Uma página Tudo contém até
quatro lotes locais (incluindo playlists) ou três externos. Cursores versionados
vinculam provedor, texto normalizado, escopo, filtro, idioma e tamanho. A
continuação externa mantém o deslocamento de cada índice e não repete índices
esgotados. A consulta SQLite usa ordenação estável também em empates.

Homônimos permanecem separados por ID; título e crédito nunca estabelecem uma
associação entre registros locais e externos. Resultados externos não recebem um
selo de pertencimento apenas por igualdade de texto. Associações persistentes e
detalhes progressivos pertencem à etapa 4.

## Cache e falhas

O cache de busca leve usa o armazenamento HTTP compartilhado, fora do banco da
biblioteca, com contrato v1 e validade de 15 minutos. Sua chave inclui provedor,
tipos/filtro, consulta normalizada, escopo, idioma, tamanho e cursor. Espaços
redundantes e diferenças de caixa não criam consultas distintas.

A interface consulta o cache antes da rede; uma resposta válida em cache encerra
aquela consulta. Uma falta de cache nunca dispara HTTP no modo `cache_only`.
A leitura permanece disponível durante cooldown do host. Na ausência de uma
resposta reutilizável, chamadas normais respeitam o cooldown e expõem o tempo
informado pelo serviço. Conteúdo ou contrato de cache inválido vira falta de cache.

Erros externos não bloqueiam páginas locais nem apagam resultados já exibidos.
Respostas canceladas ou de gerações anteriores são descartadas também na
apresentação Swift. Fechar a página fecha sua sessão e cancela seus consumidores.

## Compatibilidade e validação

A API é aditiva; `search` e as ações locais existentes continuam disponíveis.
Os DTOs e o objeto de sessão foram exportados por UniFFI, com bindings Swift e
biblioteca macOS regenerados juntos. Não há nova migração do catálogo. O GTK
continua no escopo de conexão descrito pelo projeto; recebe a API Rust comum,
sem nova tela nativa de busca nesta entrega.

Os testes usam transporte simulado e arquivos temporários: não dependem da
rede ou de uma conta MusicBrainz. Cobrem índices leves, homônimos, URLs,
paginação e vínculo dos cursores, normalização/isolamento de cache, cooldown,
cancelamento e escolha persistente do provedor. A fachada é exercitada com
varredura local e sessões independentes. Os testes Swift cobrem publicação
progressiva, resultado obsoleto, cache e retry/paginação sem apagar a seção local.
O teste de interface usa dados isolados, sem consulta a serviços externos.

Validação executada: suíte completa Rust com todas as features e sem exclusões,
443 testes aprovados e três testes previamente ignorados; Clippy com todos os
alvos/features e avisos como erros aprovado; compilação macOS e geração UniFFI
aprovadas. Os oito testes direcionados de apresentação/envio da busca e o teste visual de
troca de escopo/filtro com seções local e MusicBrainz passaram (nove no total).

Atualização após a entrega: a falha encontrada no antigo teste de tooltip da
retrospectiva correspondia a um gráfico já removido da interface. Seus cinco
testes de tooltip e o teste da tendência do antigo gráfico foram removidos;
asserções de barras e rótulos de eixos também foram retiradas dos testes de
agregação. A cobertura de períodos, contagens, rankings e tempo ouvido foi mantida.

Após essa limpeza, a suíte completa `DurvaldTests` passou em 409 testes, sem
falhas ou exclusões. A rodada usou `ENABLE_APP_SANDBOX=NO` apenas como opção de
execução para permitir a captura em `/tmp` do teste existente de metadados;
a configuração de isolamento do projeto foi preservada.
