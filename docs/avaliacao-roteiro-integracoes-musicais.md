# Avaliação do roteiro unificado de integrações musicais

Data: 28/10/2026. Base versionada: `0201f1c`, considerando também a coleta externa
posterior presente na árvore de trabalho. Referência: [roteiro canônico](roteiro-integracoes-musicais.md).

## Parecer

O MVP definido pelo roteiro tem implementação documentada no core e na interface
macOS: catálogo, detalhes, múltiplas origens, adaptadores opcionais, primeiro
provedor de reprodução e busca Soulseek. Transferências, coleções e consolidação
de sessão também têm entregas. A arquitetura está coerente com a prioridade de
funcionamento local e preservação da identidade e dos dados pessoais.

O encerramento integral do roteiro ainda depende de validação operacional de
alguns caminhos. Código implementado, contrato aprovado em simulador e fluxo
comprovado contra um serviço real são estados diferentes. As principais lacunas
estão nos casos Soulseek de cancelamento/lote parcial reais, nas APIs de coleções
com credenciais e na estabilização prolongada/distribuição. O escopo individual
de término SoundCloud foi atendido posteriormente, com limites de sessão gráfica
registrados.

A etapa 9A é condicional e foi dispensada corretamente para o piloto incorporado.
Sua ausência não constitui uma falha do MVP. A avaliação não usa percentual de
conclusão, pois as etapas têm pesos e critérios distintos.

## Método e limites da avaliação

Revisão do roteiro, documentos de entrega, JSONs de evidência e histórico de
commits; conferência pontual do registro de plugins, flags de serviço, tratamento
de eventos/fim/timeout, testes de sessão e cliente GTK. Os sete hashes de fontes
do recibo da etapa 15 e os quatro da coleta externa conferem com os arquivos
atuais; o hash da coleta externa confere com seu recibo de validação.

Não foi executada nova suíte funcional nesta avaliação nem uma auditoria exaustiva
de todo o código. Contagens de testes abaixo são as últimas execuções registradas.
Relatórios antigos são históricos e não foram reinterpretados como prova de
capacidades posteriores. Alterações pendentes de outras tarefas foram preservadas.

## Avaliação por etapa

| Etapa | Implementação avaliada | Situação de validação/fechamento |
| --- | --- | --- |
| 1 — Identidade e fronteiras | Entregue: identidade por provedor/entidade, separação catálogo/origem/mídia e associação revisada. | Contratos e testes de domínio/arquitetura documentados. |
| 2 — Registro de plugins | Entregue: adaptadores internos, manifesto/API, configuração, credenciais, flags, cancelamento e isolamento. | Ciclo de vida e falhas cobertos. Não é marketplace; isso corresponde ao recorte planejado. |
| 3 — Busca local/MusicBrainz | Entregue: escopos, filtros, paginação, cache, cancelamento e resultados independentes. | Cobertura funcional documentada. Meta de p95 da primeira página remota ainda não foi demonstrada. |
| 4 — Detalhes e seleção | Entregue: blocos progressivos, ações explícitas e seleção persistente idempotente. | Falhas parciais e ausência de importação implícita cobertas. |
| 5 — Provas de provedores | Entregue como investigação e escolha do piloto. | Evidência por capacidade, com limites explícitos; não significa aprovação integral de todos os serviços. |
| 6 — Origens locais | Entregue: migração aditiva, espelhamento transitório, unicidade, backup e recuperação. | Preservação de IDs, valores pessoais, playlists e rollback documentada. |
| 7 — Catálogo/fila sem arquivo obrigatório | Entregue: arquivo opcional, faixas remotas, ocorrências/contextos e leitores adaptados. | Core/macOS cobertos; interface GTK permanece inicial, sem paridade funcional. |
| 8 — Busca e gestão de fontes | Entregue: relações conhecidas, links, revisão, associação, preferência e gestão. | Não oferece busca textual universal nos serviços; esse limite está documentado. |
| 9A — Transporte nativo remoto | Não implementado, condicionalmente dispensado. | Só deve ser aberto quando houver um provedor/modo nativo validado que o exija. Não falta ao piloto atual. |
| 9B — Player incorporado | Entregue: WebKit visível, comandos/eventos, exclusão de áudio simultâneo e coordenação pelo core. | Término natural e seek comprovados em casos reais, com recuperação reforçada e limites de sessão gráfica registrados; sem garantia universal do SDK. |
| 10 — Primeiro provedor completo | Entregue: SoundCloud, ouvir sem salvar, associar, escolher origem e fallback antes do áudio. | Há prova real do fluxo e de término/fila/histórico; disponibilidade e eventos continuam dependentes do item/serviço/sessão. |
| 11 — Busca Soulseek | Entregue: slskd configurável, busca independente, resultados parciais, filtros, inspeção e cancelamento. | Backend real e busca pela fachada do core comprovados; apresentação da interface mantém cobertura automatizada. |
| 12 — Transferências/importação | Entregue: seleção explícita, diário, cancelamento, retomada, validação do arquivo e recibo de importação. | Arquivo real transferido/importado/reimportado pela fachada do core após dois reinícios; cancelamento/lote parcial reais e montagem remota ainda pendentes. |
| 13 — Serviços/coleções | Entregue no recorte público: leitores independentes, revisão, paginação, ocorrências e retomada. | Bandcamp individual e player YouTube têm prova real; SoundCloud OAuth/YouTube Data API ainda sem prova com credenciais. Coleções autenticadas Bandcamp permanecem condicionais. |
| 14 — Histórico/sessão | Entregue: migração 26, duração observada, tentativa idempotente, sessão v4 pausada/offline e fila mista. | Cobertura de reinício, duplicatas, navegação, histórico legado e preservação documentada. Histórico/conclusão remotos continuam dependentes dos eventos reais. |
| 15 — Estabilização | Entregue como infraestrutura e baseline: diagnóstico, isolamento, verificação do helper, budgets locais e medições externas. | Há números reais para core e dois players; falta estabilização prolongada do app completo e extensão das provas aos demais modos. Encerramento global permanece condicionado. |

Fontes principais: [contratos](features/music-integration-contracts.md),
[plugins](features/music-plugin-runtime.md), [catálogo](features/catalog-search.md),
[detalhes](features/catalog-details.md), [origens](features/source-management.md),
[catálogo independente de arquivo](features/source-independent-catalog.md),
[reprodução](features/provider-playback.md), [transferências](features/soulseek-transfers.md),
[coleções](features/service-collections.md), [sessão](features/consolidated-playback.md)
e [estabilização](features/integration-stabilization.md).

## Pontos fortes comprovados documentalmente

- A faixa canônica conserva identidade e valores pessoais ao trocar/adicionar origens.
- Banco, fila, mídia temporária e contexto da coleção têm responsabilidades distintas.
- Associação e importação são explícitas, com transações e recibos para evitar duplicação.
- Sessão restaurada não inicia rede/áudio; falhas de plugins não bloqueiam áudio local.
- Credenciais e URLs temporárias não são tratadas como metadados persistentes da biblioteca.
- Falhas parciais, resultados antigos, cancelamento e retry têm cobertura dedicada.
- Funcionalidades externas podem ser desativadas de forma independente.
- A documentação preserva limites das provas e não promove fixtures a validação real.

## Lacunas prioritárias e critérios para encerrá-las

### 1. Transferência Soulseek real até importação — arquivo individual comprovado

A avaliação inicial apontou ausência de prova real. Uma execução posterior,
solicitada pelo usuário com uma faixa para o teste, confirmou **8.378.198 bytes**
transferidos por slskd real, revisão/decodificação, importação e reimportação
idempotente após dois reinícios do processo. Identidade de faixa/origem e favorito
foram preservados; nenhuma música entrou na biblioteca antes da confirmação.
Veja [prova individual e limites](features/soulseek-live-acquisition.md).

O recibo original da etapa 12 continua histórico. Para encerrar toda a pendência,
faltam casos reais de cancelamento em andamento, retomada/lote parcial e, quando
aplicável, montagem remota. O teste não adicionou nova prova visual da interface.
Rede que acessa SDKs por HTTP não garante conectividade entre peers Soulseek.

### 2. Término SoundCloud e efeitos na fila/histórico — escopo individual atendido

Em 29/10/2026, a [entrega de término e recuperação](features/soundcloud-completion-recovery.md)
validou escuta natural até FINISH, um único histórico e avanço para a ocorrência
local correta, conservando a duplicata seguinte. Seek próximo ao fim passou
sem play fabricado. A evidência identifica as execuções aprovadas separadamente.

Foram corrigidos deadline renovado por PLAY repetido sem progresso, PLAY extra
após seek, entrega duplicada de FINISH no host e retry dependente de snapshot
desatualizado. A interface oferece retomada explícita e próxima faixa na falha.
O core preserva fila/histórico e não infere Ended pelo relógio.

Tentativas com a sessão gráfica bloqueada ficaram limitadas, inclusive no
executor isolado. O reteste desbloqueado aprovou o término natural final; o caso
de seek da última suíte foi omitido pelo bloqueio posterior e não foi promovido
a sucesso. O seek aprovado usa o mesmo código de produção em rodada anterior.
Os relatos históricos de intermitência do SDK permanecem válidos para seus
casos; não há garantia geral de FINISH nem causa única atribuída.

### 3. APIs autenticadas de coleções — prioridade alta para divulgar esse suporte

**Mudança de direção em 29/10/2026:** o usuário decidiu não fornecer chaves de API.
A prova abaixo permanece pendência apenas para divulgar os leitores autenticados,
que passam a ser opcionais. O próximo trabalho segue o
[roteiro de adaptadores sem chaves e mídia visual](roteiro-adaptadores-sem-chaves-e-midia-visual.md).
Isso replaneja a prioridade, sem comprovar busca, coleções ou áudio pelos extratores.

A [evidência da etapa 13](evidence/provider-probes/service-collections-2026-10-28.json)
registra ausência de token OAuth SoundCloud e chave YouTube Data API nas provas
reais. Player YouTube funcionando não comprova importação por `playlistItems`/
`videos`; widget SoundCloud funcionando não comprova leitura de playlists OAuth.

Encerrar com credenciais autorizadas, consulta de faixa e coleção real, paginação,
item indisponível, falha de credencial, cancelamento e retomada idempotente.
Manter flags opt-in até que as capacidades correspondentes estejam comprovadas.
Renovação OAuth automática não foi prometida no incremento atual.

Em 29/10/2026, a [preparação da prova](features/service-collection-api-proofs.md)
ganhou executor com biblioteca isolada, alvos fornecidos pelo usuário e fases
separadas de captura, retomada, importação e reimportação. O tratamento YouTube
distingue chave inválida e cota de restrições do conteúdo. O usuário confirmou
não possuir as credenciais: a prioridade permanece aberta, sem prova real das APIs.

### 4. Desempenho do aplicativo completo e estabilidade prolongada — prioridade média

O baseline nativo mede core/SQLite/renderer; não inclui tempo de envio até lista
renderizada ou detalhe SwiftUI. A coleta externa usa um aplicativo WebKit isolado,
três repetições por item e 20 segundos de reprodução por rodada.

Os seis casos externos medidos passaram sem timeout: início até avanço de
894–1.002 ms no SoundCloud e 1.022–1.053 ms no YouTube. O custo observado em
reprodução foi 21,55–31,03% de um core/348,00–384,92 MiB para SoundCloud e
11,32–13,54%/398,72–424,80 MiB para YouTube. Há custo do executor e polling;
comparações com o core isolado não substituem baseline do app integrado.

Encerrar com medições de Release do app completo, tempo até apresentação da
lista/detalhe, p95 de catálogo remoto, fila mista prolongada, interrupções de rede,
reinício e evolução de memória/disco. Separar budgets por modo. Três amostras de
player não demonstram um p95 geral de provedor nem todas as redes/formatos.

### 5. Distribuição e compatibilidade de clientes — condição de lançamento amplo

Assinatura/notarização, execução distribuída com as permissões efetivas e acesso
persistente a pastas ainda não têm aprovação documentada. O helper slskd de provas
tem verificação de instalação fixada; isso não comprova atualização assinada
completa de um helper distribuído, que não foi adotado no runtime.

GTK consome a API Rust, mas sua interface implementa abertura e contagem da
biblioteca. Se paridade Linux for critério de produto, ela exige uma trilha própria;
interface comum de core não equivale a experiência nativa pronta em ambos.

## O que permanece fora do escopo atual por decisão

Não classificar como defeito ou pendência obrigatória do MVP: marketplace de
plugins, extração de áudio YouTube, yt-dlp/FFmpeg, streaming HTTP/HLS/DASH nativo
sem provedor validado, fallback durante áudio, sincronização automática de
coleções, Bandcamp autenticado/arquivos comprados e Discogs sem lacuna observada.
Esses itens exigem decisão/prova própria se forem incorporados ao produto.

O roteiro R1–R12 de 29/10/2026 planeja incorporar extratores, transporte remoto
nativo e mídia visual ao próximo incremento. Eles continuam fora da entrega
anterior e ainda não estão implementados por essa decisão de planejamento.

## Consistência da documentação e versionamento

O cabeçalho do roteiro foi alinhado em 29/10/2026 às entregas registradas de 1–15,
preservando a distinção entre implementação e validação externa. A seção
de contratos também conserva descrições históricas de persistência/download
como futuros e não públicos. Algumas páginas originais mantêm limitações do
momento da entrega e dependem dos links de evolução para representar o estado atual.

Recomenda-se separar, por etapa/provedor: implementação, validação offline,
validação real e distribuição. Atualizar o resumo canônico com essa distinção,
sem alterar os JSONs históricos. Na avaliação original, as novas medições e
ferramentas externas estavam apenas na árvore de trabalho, após `0201f1c`.
A publicação deste conjunto versiona ferramentas, relatórios e documentação em
commits por assunto; os JSONs históricos permanecem inalterados.

## Evidências e conclusão de fechamento

Último recibo amplo: **540 testes Rust e 437 macOS**, Clippy e smoke UniFFI
aprovados; quatro/cinco smokes externos, respectivamente, permaneceram opt-in.
A ferramenta de medição posterior registra **34 testes Python** e **seis rodadas
reais** SoundCloud/YouTube. São contagens de execuções diferentes, não uma única
suíte executada nesta avaliação.

A classificação recomendada é **MVP implementado no macOS, com validação
operacional e estabilização ainda abertas por capacidade**. Priorizar fechamento
dessas evidências antes de expandir serviços. Uma declaração de conclusão total
deve identificar quais capacidades receberam prova real e quais permanecem
experimentais/condicionais.
