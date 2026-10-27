# Roteiro unificado: catálogo, múltiplas origens e plugins

Data: 26/10/2026. Revisão: 27/10/2026.
Status: implementação incremental; etapas 1–5 concluídas, demais etapas planejadas.

Este é o plano canônico para busca de catálogo, fontes de reprodução, múltiplas
origens e integrações de streaming e download. Consolida os roteiros de busca e
origens e a trilha de plugins do roadmap. Features locais, gêneros e manutenção
do enriquecimento continuam em seus documentos próprios.

## Objetivo e decisões

Permitir pesquisar música, escolher onde ouvir e obter arquivos sem duplicar a
biblioteca nem fazer o funcionamento local depender de serviços externos.

- Uma faixa mantém sua identidade e seus favoritos, avaliações, tags, histórico,
  posições de playlist e Replay. Arquivos e referências externas são origens da
  faixa; disponibilidade, formato e qualidade pertencem a cada origem.
- Separar buscar catálogo, procurar fontes, resolver mídia e buscar downloads.
  A pesquisa de catálogo não espera streaming ou resultados Soulseek.
- Resultados externos ficam em DTOs/cache até uma ação explícita de salvar,
  seguir, adicionar à Listen List ou associar origem. Abrir um detalhe não importa
  toda a discografia nem enriquece todos os resultados.
- Rust coordena domínio, persistência, tarefas, seleção de origem, reprodução,
  fila e histórico. Swift apresenta estados e intenções; segredos ficam no
  armazenamento da plataforma. Contratos compartilhados atendem também ao GTK.
- Plugins começam como adaptadores opcionais mantidos pelo projeto. Contratos
  vêm cedo; marketplace e execução arbitrária de código de terceiros ficam fora
  do MVP. Usar processos auxiliares onde houver necessidade de isolamento.
- Validar acesso, autenticação, modo de reprodução, distribuição e dependências
  por provedor antes de prometer suas capacidades. yt-dlp é um helper candidato,
  não um resolvedor universal obrigatório.
- Cada etapa gera uma entrega revisável. Migração do banco, transporte remoto e
  primeiro serviço entram em mudanças separadas, com flags por integração.

## Base existente a conferir na implementação

Os roteiros anteriores registraram os pontos abaixo; confirmar o estado do código
antes de cada entrega, pois esta consolidação não faz uma nova auditoria técnica.

| Área | Base a reaproveitar ou evoluir |
| --- | --- |
| Catálogo | `durvald-core/src/domain/catalog.rs`: `CatalogTrack.file_path`; identidade externa e seleção explícita de artista já têm fronteiras próprias. |
| Persistência | `durvald-core/src/database/operations.rs`: `songs.file_path` obrigatório; preservar faixas ausentes, playlists, avaliações e histórico. |
| Busca | `infrastructure/sqlite/catalog_search.rs` e `searchLibrary`; reaproveitar debounce, cancelamento e descarte de respostas antigas de `Features/Search/SearchPresentation.swift`. |
| Enriquecimento | Reusar scheduler, cache, cooldown, perfis, discografias e capas; o resolvedor de artistas MusicBrainz não deve virar autocomplete pesado. |
| Reprodução | `application/playback.rs`, `audio/player.rs` e `audio/decoder.rs`: preparação e decoder baseados em arquivos locais. |
| Sessão e API | `domain/playback_session.rs` e `api.rs`: preservar IDs, contextos e ocorrências; evoluir DTOs e bindings com os consumidores. |

Origem de navegação/reprodução de uma coleção, como álbum ou playlist, é diferente
da origem de mídia, como arquivo local ou SoundCloud. Manter ambos os conceitos.

## Modelo e contratos compartilhados

### Identidade e dados

Manter `songs.song_id`; não criar biblioteca paralela de streaming nem guardar
URLs em `file_path`. Distinguir artista, agrupamento de lançamento, edição,
gravação e ocorrência da faixa na edição. Um recording externo não substitui o
contexto da faixa no catálogo. Referências externas são tipadas por entidade e
provedor; perfil, uploader ou usuário de download não equivale ao artista musical.

| Entidade proposta | Responsabilidade |
| --- | --- |
| `songs` | Metadados canônicos e valores pessoais; passa a aceitar ausência de arquivo local após a migração de leitores. |
| `track_sources` | `source_id`, `song_id`, provedor, ID externo, URL canônica ou caminho local, habilitação, prioridade, procedência da associação e timestamps. |
| `track_source_state` | Disponibilidade observada, verificações, último sucesso, falha tipada e próxima tentativa; desconhecido não significa disponível. |
| `track_source_metadata` | Metadados e qualidade observados por origem, sem sobrescrever automaticamente os dados canônicos. |
| `playback_source_preferences` | Preferência da faixa, ordem dos provedores, prioridade local e política de fallback. |
| `stream_cache_entries` | Cache temporário com limites e estado de conclusão; não equivale a arquivo permanente da biblioteca. |

Regras de integridade e associação:

- FKs e índices por faixa/provedor; preferência aponta para origem da própria
  faixa e é invalidada quando ela é excluída.
- Identidade remota única por `(provider, external_id)` no escopo inicial. Uma
  associação já existente exige resolução do vínculo; IDs diferentes do mesmo
  serviço podem ser origens da mesma faixa.
- Caminhos locais normalizados têm unicidade própria, respeitando diferenças
  entre sistemas de arquivos. Resolver colisões antes de criar a restrição.
- Origem local exige caminho; remota exige referência persistente e URL canônica.
  URLs assinadas, headers e tokens resolvidos são temporários e ficam em memória.
- Priorizar IDs e links conhecidos. Título, artista, duração e tracklist sugerem
  candidatos; associação ambígua exige revisão. Não mesclar gravações, edições,
  covers, remixes ou versões ao vivo automaticamente.
- Álbum em vídeo único não vira faixa comum nem recebe divisões inventadas.
- Histórico agrega por faixa; duração e qualidade efetivas vêm da mídia tocada.
  Ações locais de favorito/avaliação não escrevem nos serviços externos.

### Contrato de plugins

Definir manifesto com ID estável, versão do plugin e da API, capacidades,
permissões, configuração, requisitos de autenticação e dependências. Capacidades
independentes: `catalog_search`, `metadata`, `source_search`, `playback`,
`download_search`, `download_transfer`, novidades e comandos extras quando necessários.

Contratos candidatos no core:

- Catálogo: `CatalogSearchRequest`, `CatalogSearchPage`, `ExternalEntityRef`,
  `CatalogEntityDetails`.
- Origens: `TrackSource`, `SourceAvailability`, `SourceCapabilities`,
  `SourceSearchRequest`, `SourceCandidate`, `ResolvedMedia`.
- Reprodução: `PlaybackCapability`, distinguindo `native_audio`,
  `embedded_player` e `external_open`; seek, duração, preload e autenticação
  declarados por origem/modo, não presumidos para todo o serviço.
- Download: `DownloadSearchSession`, `DownloadCandidate` e contrato posterior
  de transferência, separado da resolução de streaming.

Os contratos de identidade, catálogo, capacidades, referências de origem e mídia
resolvida da etapa 1 já existem como tipos internos do core. Persistência de
`TrackSource`, contratos de download e adaptadores continuam nas etapas seguintes;
não são APIs públicas disponíveis. O core controla fila, persistência e políticas;
adaptadores traduzem APIs externas e retornam dados e eventos normalizados.
Metadados e novidades não dependem de múltiplas origens.

O ciclo de vida inclui instalação/registro, habilitação, configuração,
desabilitação e remoção. No MVP, instalação pode ser o registro de adaptadores
distribuídos com o app. Desabilitar cancela tarefas e impede novas ações; remover
preserva catálogo e valores pessoais, deixando origens sem adaptador explicitamente
indisponíveis. Não apagar arquivos permanentes como efeito da remoção do plugin.

Aplicar timeout, cancelamento, limite de concorrência, erros tipados e isolamento
de falhas. Credenciais ficam no armazenamento do sistema e não em logs, cache de
resultados ou metadados. Cada integração valida permissões e distribuição próprias.

## Etapas incrementais

A numeração sugere ordem de execução individual. As dependências indicam o que
realmente bloqueia cada entrega; a trilha de download pode avançar sem streaming.
Cada etapa deve entregar uma fatia verificável, sem exigir todas as seguintes.

### 1. Fechar identidade e fronteiras

**Dependências:** nenhuma.

**Status:** concluída em 27/10/2026. Contratos e decisões detalhados em
[identidade e fronteiras das integrações](features/music-integration-contracts.md).
Tipos em `durvald-core/src/domain/music` e ports em
`durvald-core/src/application/music_catalog.rs`; sem mudança do banco, player ou API pública.

- Registrar as regras de identidade, associação e separação entre resultado
  externo, adesão à biblioteca, origem persistente e mídia temporária.
- Definir contratos mínimos de busca, detalhes, capacidades e erros.
- Definir referência de fila para ouvir sem salvar: identidade de sessão própria;
  se o histórico exigir persistência, registro mínimo separado da adesão à biblioteca.
- Documentar compatibilidade e versionamento de DTOs/UniFFI.

**Conclusão:** contratos e invariantes revisados, com validação das regras de
identidade; nenhuma alteração de reprodução local ou dependência de rede.

**Validação executada:** 288 testes unitários e 112 testes de integração passaram,
incluindo dez testes novos de domínio, uma nova verificação de fronteiras e os 48
testes de reprodução. Compilação com UniFFI passou. Três testes ignorados existentes
foram mantidos. Duas falhas unitárias e uma de arquitetura foram reproduzidas
também numa cópia de `HEAD` sem esta etapa e excluídas da rodada de regressão;
identificação e limitações dos checks estão no documento da entrega.

**Atualização de 27/10/2026:** contagem de migrações e identidade de artistas
descobertos corrigidas após investigação. A regressão posterior passou em 408
testes e na compilação UniFFI; resta a falha conhecida de fronteiras da aplicação,
excluída da rodada. Ver [investigação e correção](features/artist-identity-investigation.md).

**Correção posterior no mesmo dia:** a [fronteira de aplicação](features/application-boundary-investigation.md)
também foi corrigida. A suíte completa passou em 414 testes, sem exclusões; três
testes previamente ignorados foram mantidos. Core com UniFFI verificado novamente.

### 2. Registro mínimo de plugins e infraestrutura comum

**Dependências:** 1.

**Status:** concluída em 27/10/2026. Contratos, ciclo de vida e limites em
[registro mínimo de plugins](features/music-plugin-runtime.md).

- Implementar registro de adaptadores internos, manifesto, capacidades, versão
  de API, flags, configuração e estados de habilitação.
- Compartilhar scheduler, cache e cooldown existentes; aplicar limites,
  cancelamento e descarte de respostas de gerações antigas.
- Permitir configuração de credenciais via camada de plataforma quando exigidas.
- Validar o ciclo de vida com adaptador falso; não construir um marketplace.

**Conclusão:** adaptador pode ser habilitado, desabilitado e removido sem afetar
outros; tarefas são canceladas e dados pessoais preservados. Biblioteca funciona offline.

**Entrega:** registro interno com manifesto/API v1, capacidades e permissões
verificadas, configuração/flags persistidas, credenciais pela plataforma e
tombstones de remoção. Gerações de plugin/consulta, concorrência limitada,
timeout incluindo fila e cancelamento descartam trabalho obsoleto. Runtime e
enriquecimento compartilham o request scope, locks, cache HTTP e cooldown; os
clientes mantêm os gates de provedor existentes. Nenhum adapter real foi ativado.

**Validação executada:** 434 testes passaram com todas as features, sem falhas
ou exclusões; três testes previamente ignorados foram mantidos. Inclui 17 testes
novos com adapters falsos, dois de ciclo de vida pela fachada e uma nova proteção
arquitetural. Clippy com todos os alvos/features e avisos como erros passou.
Não houve mudança dos DTOs nativos, bindings ou schema da biblioteca.

### 3. Busca de catálogo local e MusicBrainz

**Dependências:** 1–2.

**Status:** concluída em 27/10/2026. Contratos, interface e limites em
[busca de catálogo](features/catalog-search.md). Busca local e MusicBrainz
com páginas independentes, cache, cancelamento e resultados externos somente
para consulta; detalhes/adesão seguem na etapa 4.

- Oferecer escopos Biblioteca/Explorar e filtros Tudo/Artistas/Lançamentos/Faixas.
- Consulta externa por envio; sugestões durante digitação usam local/cache.
  URLs reconhecidas seguem resolução direta pelo adaptador disponível.
- Mostrar resultados progressivos por provedor com paginação, erro e retry
  independentes. Local aparece sem esperar rede.
- Reusar a integração MusicBrainz para busca leve; não fazer lookup detalhado
  de cada resultado. Last.fm continua opcional para artistas similares.
- Cache de consulta inclui provedor, entidade, texto normalizado, filtros,
  idioma e cursor; cache de detalhe inclui identidade e versão do contrato.

**Conclusão:** pesquisar artistas, lançamentos e faixas funciona com cancelamento,
homônimos e cache; resultado antigo não substitui pesquisa nova. Buscar não salva
itens na biblioteca nem exige reprodução remota.

### 4. Detalhes progressivos e seleção persistente

**Dependências:** 3.

**Status:** concluída em 27/10/2026. Detalhes, ações e limites em
[detalhes progressivos e seleção persistente](features/catalog-details.md).
Blocos independentes, seleção idempotente e reabertura de itens salvos;
Seguir e Listen List conectados às features existentes. Migração 20 e API
aditiva com bindings Swift atualizados. Ouvir/baixar aguardam seus adaptadores.

- Mostrar identidade e dados básicos primeiro; carregar capa, perfil, edição,
  tracklist, discografia e similares independentemente.
- Reaproveitar seleção externa e materialização existentes. Salvar apenas os
  alvos necessários, de forma idempotente.
- Expor ações distintas para salvar, seguir, Listen List e procurar onde ouvir
  ou baixar. Integrar cada ação à feature correspondente quando disponível.
- Aceitar referência provisória de serviço para conteúdo sem MBID, sem inventar ID.

**Conclusão:** abrir não importa a biblioteca; salvar duas vezes não duplica;
falha em capa/biografia não bloqueia detalhes úteis. Fundação pronta para Listen
List externa e descoberta, sem esperar streaming.

### 5. Provas técnicas dos provedores

**Dependências:** 2 e contratos de 1; pode começar antes de concluir 3–4.

**Status:** concluída em 27/10/2026. [Provas, evidências e decisão do piloto](features/provider-proofs.md).
Piloto técnico: faixa individual SoundCloud pelo widget oficial visível em
WebKit. Execução real de controles/eventos e indisponibilidade; YouTube como
alternativa de vídeo e Bandcamp limitado à descoberta de embed. O slskd real
foi configurado e autenticado; a busca ficou limitada por ausência de respostas
e timeouts. Investigação cancelada pelo usuário, backend encerrado e configuração
preservada. Contratos adicionais foram testados em fixture. Nenhum
provedor foi habilitado em produção; distribuição e demais limites estão
explicitados na matriz.

- Executar provas separadas para candidatos Bandcamp, SoundCloud, YouTube e
  Soulseek via slskd. Não exigir sucesso de todos para escolher o piloto.
- Registrar data/versão, acesso, credenciais, limites, atribuição, formatos,
  modo de player, eventos disponíveis e condições de distribuição.
- Para streaming, testar URL individual, completo/prévia, indisponibilidade,
  expiração, seek e transporte necessário. Distinguir descoberta de mídia acessível.
- Para slskd, validar API e configuração do backend, respostas incrementais,
  cancelamento e relação entre destino remoto e arquivo acessível no computador.
- Avaliar yt-dlp somente quando pertinente; definir assinatura, atualização
  verificada, runtime/FFmpeg e compatibilidade com sandbox/notarização se adotado.

**Conclusão:** matriz de capacidades com evidências e escolha de um piloto.
Serviços sem caminho validado ficam desabilitados ou oferecem abrir no serviço;
a ordem dos provedores é decidida pelas provas, não pela numeração dos planos antigos.

### 6. Migração aditiva das origens locais

**Dependências:** 1; independente das provas externas.

- Criar tabelas de origens e migrar caminhos atuais para origens locais em
  transação versionada, idempotente e sem rede.
- Preservar `song_id` e todos os relacionamentos; manter `songs.file_path`
  temporariamente para compatibilidade, ainda sem faixas exclusivamente remotas.
- Atualizar scanner, importação, relink e reparo para escrita consistente na
  origem e coluna legada durante a transição.
- Incluir origens em exportação, restauração e exclusão da biblioteca.
- Criar backup pré-migração e verificar colisões antes das restrições de unicidade.

**Conclusão:** contagens, IDs, avaliações, favoritos, histórico, ordem e duplicatas
de playlists preservados. Reabrir não duplica origens; falha reverte a transação.

### 7. Catálogo e fila independentes de arquivo obrigatório

**Dependências:** 6.

- Tornar origem a referência canônica de operações de arquivo; atualizar consultas,
  filtros, busca, estatísticas, reparo e scanner para ausência de origem local.
- Remover obrigatoriedade de `songs.file_path` após migrar todos os leitores;
  não usar string vazia como substituto. Preservar FKs, índices e triggers se
  houver reconstrução SQLite, incluindo playlists inteligentes e Replay.
- Remover arquivo afeta sua origem; não apaga automaticamente faixa com outras
  origens nem valores pessoais. Falha de rede não significa arquivo ausente.
- Enfileirar identidades e ocorrências, resolvendo mídia perto da reprodução,
  sem resolver a fila inteira. Preservar contexto de álbum/playlist e duplicatas.
- Evoluir API e bindings com macOS e GTK. Documentar que banco migrado não deve
  ser reaberto por builds antigos; recuperação usa backup pré-migração.

**Conclusão:** faixa somente remota pode ser salva, listada e colocada em playlist;
scan/reparo/reinício não a removem. Reprodução local e fila continuam funcionando.

### 8. Busca e gestão mínima de fontes

**Dependências:** 4–5 e 7 para associação persistente.

- Consultar fontes somente para item escolhido e provedores habilitados.
- Mostrar provedor, uploader, versão, duração e capacidade observada: completo,
  prévia, player integrado, abrir no serviço, desconhecido ou indisponível.
- Oferecer adicionar faixa ou anexar origem a faixa existente, com revisão de
  candidatos ambíguos. Resultados continuam externos até a ação de associação.
- Listar, testar, habilitar, desabilitar, remover e preferir origens.
- Distinguir escolher origem nesta reprodução de salvá-la como preferência.
  Não anunciar Play nativo onde só existe link ou capacidade ainda não verificada.

**Conclusão:** faixa pode ter várias origens sem duplicar dados pessoais;
falha de um provedor não bloqueia demais resultados. Abrir no serviço funciona
quando suportado; reprodução interna depende da etapa seguinte correspondente.

### 9A. Transporte para áudio nativo

**Dependências:** 7; necessário apenas se o piloto de 5 usar `native_audio`.

- Validar primeiro com servidor HTTP local: leitura progressiva, buffering,
  Range quando disponível, cancelamento e cache limitado em disco/memória.
- Separar download, preparação e decoder; nunca fazer rede no callback de áudio.
  Bytes ainda não recebidos não podem ser tratados como fim real de mídia.
- Expor `resolving`, `buffering`, `playing`, `paused`, `ended` e `failed`.
- Declarar seek conforme servidor/formato; proteger cache em uso contra remoção.
  HLS/DASH exigem adaptadores separados, somente se o piloto precisar.
- Limitar preload e concorrência. Crossfade/gapless somente quando a próxima
  mídia estiver preparada; caso contrário, transição normal.

**Conclusão:** tocar, pausar, retomar, buscar posição e cancelar passam em cenários
de rede lenta, desconexão, sem Range e truncamento; sem memória ilimitada ou
download integral obrigatório para todo formato suportado.

### 9B. Coordenação de player integrado

**Dependências:** 2, 7 e modo validado em 5; necessário apenas para `embedded_player`.

- Integrar player visível conforme o contrato do provedor e coordená-lo com o
  player local, impedindo reprodução simultânea.
- Traduzir comandos, posição, pausa, fim e falha pelos eventos disponíveis;
  explicitar operações não suportadas.
- Definir fila e histórico para esse modo; não prometer equalizador,
  normalização, gapless ou segundo plano sem capacidade comprovada.

**Conclusão:** uma faixa pode tocar pelo player integrado com estado coerente,
sem exigir transporte de áudio nativo ou extrator. `external_open` continua um
modo distinto e não simula eventos de escuta que o app não consegue observar.

### 10. Primeiro provedor de reprodução de ponta a ponta

**Dependências:** 8 e 9A ou 9B, conforme o piloto; abertura externa pode sair em 8.

- Entregar buscar → escolher versão/origem → ouvir → salvar/associar, começando
  por URL individual. Listas e álbuns do serviço são incrementos posteriores.
- Resolver endereço e headers perto da execução; renovar expiração com tentativas
  limitadas. Persistir referência estável, nunca URL temporária de mídia.
- Se usar helper, executar por argumentos estruturados, sem shell; normalizar
  JSON no adaptador, limitar saída/tempo e cancelar subprocessos.
- Seleção padrão: escolha explícita, preferida da faixa, local disponível e
  demais origens na ordem configurada. Definir se escolha explícita admite fallback.
- MVP usa fallback somente antes de iniciar áudio, informando mudança de origem.
  Falha durante reprodução não reinicia silenciosamente nem troca de versão.

**Conclusão:** primeiro serviço funciona sem os demais; origem indisponível tem
erro compreensível e fallback permitido. Resolução/buffering/retry não criam plays.

### 11. Pesquisa Soulseek independente

**Dependências:** 2, 4 e prova slskd de 5; não depende de 6–10.

- Adaptador para instância slskd configurada pelo usuário; não implementar o
  protocolo no core nem distribuir/gerir o daemon neste primeiro incremento.
- Ação explícita “Buscar opções de download”, com consulta editável a partir de
  artista/título/edição. Não pesquisar discografias automaticamente.
- Resultados incrementais agrupados por peer/pasta; mostrar formato, tamanho,
  qualidade observada e fila/slots quando fornecidos, ou estado desconhecido.
- Comparar tracklist, discos e duração para sugerir conjuntos de álbum; nome ou
  extensão não garantem edição nem qualidade lossless.
- Ofertas são temporárias, não origens HTTP. Selecionar não inicia transferência.
  Configuração explicita credenciais e compartilhamentos; não compartilhar a
  biblioteca inteira por habilitar a pesquisa.

**Conclusão:** pesquisar, filtrar, inspecionar e cancelar funcionam com resultados
progressivos e falha isolada, sem esperar reprodução ou alterar arquivos locais.

### 12. Transferências e importação de arquivos

**Dependências:** 11 e 6; usar 7 se houver associação a faixas exclusivamente remotas.

- Download por ação explícita e destino definido, com progresso por arquivo/lote,
  cancelamento, falha e retomada quando suportada pelo backend.
- Download em slskd remoto exige pasta compartilhada/mapeamento validado ou
  transporte explícito antes de importar; caminho remoto não é caminho local.
- Importar apenas arquivos concluídos, acessíveis e de formatos aceitos. Associar
  ao catálogo após validação, preservando tags, avaliações, favoritos e histórico.
- Evitar duplicação em retry/reimportação; lote parcial não significa álbum completo.
  Arquivo permanente importado vira origem local; cache de streaming não vira.

**Conclusão:** pesquisar → escolher → baixar → importar funciona para arquivo e
lote parcial; cancelamento e reinício não importam arquivos incompletos nem duplicam faixas.

### 13. Demais serviços e importação de coleções

**Dependências:** 10 e prova de cada provedor; listas dependem do adaptador individual.

Entregar cada linha separadamente, com flag, cache, erros e testes próprios:

| Integração | Primeiro incremento | Incremento seguinte e limites |
| --- | --- | --- |
| Bandcamp | URL pública de faixa; distinguir stream observado de arquivo de compra. | Álbum por faixas, progresso e retomada idempotente. Coleção autenticada exige prova própria; não rotular stream como lossless sem evidência. |
| SoundCloud | URL de faixa e redirects compartilhados; distinguir completo/prévia/restrito. | Playlist com ordem e ocorrências repetidas; item indisponível não aborta o lote. |
| YouTube | URL de vídeo, identidade estável e modo de player validado. | Playlist finita com paginação e retomada. Lives/eventos futuros fora do MVP; associação distingue música, cover, remix e vídeo com introdução. |

Não pressupor que YouTube oficial forneça áudio separado; player visível e helper
são caminhos distintos. Outros provedores de download devem implementar os
contratos já validados, sem acoplar sua transferência ao player.

**Conclusão:** cada serviço pode ser lançado/desativado independentemente;
reimportação não duplica origens e falhas parciais preservam itens concluídos.

### 14. Histórico, sessão e experiência consolidados

**Dependências:** 10; ampliar validação conforme 12–13 forem entregues.

- Acrescentar `source_id` opcional ao histórico, preservando eventos legados.
  Usar duração efetiva para tempo ouvido e conclusão; prévia não conta como faixa integral.
- Persistir IDs, ocorrências, contextos e posição; ao restaurar, revalidar origem
  e resolver mídia novamente, preservando fila recuperável se a coleção mudar.
- Manter uma sessão lógica por tentativa de reprodução; retry não duplica plays.
  Fallback durante áudio fica para incremento próprio com política de união de segmentos.
- Consolidar preferências, origem ativa e diagnósticos na interface; atualizar
  Replay, playlists inteligentes e estatísticas para faixas sem arquivo local.

**Conclusão:** faixa com arquivo e várias origens aparece uma vez e mantém dados
pessoais após troca/reinício. Repeat, shuffle, reorder, duplicatas e destaque
contextual funcionam na fila mista. Invariantes de histórico já valem no piloto.

### 15. Estabilização e expansão orientada por evidências

**Dependências:** validar cada integração antes de habilitá-la por padrão;
não esperar todos os serviços para estabilizar o primeiro.

- Medir latência, buffering, CPU, RAM, disco, custo de rede, idle e subprocessos
  órfãos. Estabelecer budgets em hardware/rede documentados.
- Validar ausência, incompatibilidade e atualização verificada de helpers.
- Documentar suporte e limitações por provedor/modo. Ampliar catálogo, como
  Discogs para edições/classificação, somente conforme lacunas observadas.
- Conectar novidades e recomendações externas ao fluxo de detalhe e ação útil;
  não tornar Last.fm, recomendações ou todas as features locais pré-requisitos.

**Conclusão:** rede ausente ou plugin quebrado não impede uso local; cada
integração tem limites medidos, diagnóstico e recuperação documentados.

## Regras de desempenho e validação por entrega

- Priorizar Play e detalhe aberto sobre enriquecimento de fundo. Carregar imagens
  dos itens visíveis, com tamanho/cache limitados, sem lookup de todos os candidatos.
- Deduplicar requisições, aplicar TTL por dado, separar ausência confirmada de
  falha transitória e respeitar limites e `Retry-After` vigentes por provedor.
- Cancelar tarefas obsoletas; consultar somente serviços habilitados e pertinentes.
  Não registrar consultas, tokens ou cookies em telemetria por padrão.
- Usar fixtures, provedores falsos, extrator falso e servidores locais na suíte
  offline. Smokes externos são opt-in e registram data/versão.
- Cada migração verifica preservação dos dados e recuperação por backup; cada
  mudança de API atualiza bindings/consumidores e valida reprodução local.
- Validar erros de autenticação, restrição regional, remoção, prévia, expiração,
  timeout, cancelamento, reinício e falhas parciais. Fluxos principais acessíveis
  por teclado. Não deixar esses testes apenas para a última etapa.

Metas iniciais de medição, não promessas sobre serviços externos:

| Medida | Meta proposta |
| --- | --- |
| Primeira lista local/cache quente | p95 até 200 ms após envio, fora debounce. |
| Estrutura de detalhe em cache | p95 até 300 ms. |
| Primeira página externa | p95 até 2 s em rede de referência, com resultados parciais e respeito aos limites. |
| Clique até áudio nativo direto compatível | p95 até 3 s, medindo resolução e buffering separadamente. |

Separar medições por cache frio/quente, provedor, formato e modo de reprodução.

## Ordem prática e recorte do MVP

1. **Catálogo útil:** 1–4; iniciar provas de 5 assim que 2 estiver pronta.
2. **Fundação de mídia:** 6–8; migração pode avançar sem rede.
3. **Primeiro fluxo de escuta:** somente o ramo necessário de 9 → 10, incluindo
   histórico e sessão mínimos; não esperar todos os provedores.
4. **Download:** 11 pode sair após 4–5, antes de streaming; 12 exige persistência
   de origens e acesso real aos arquivos, mas não os demais serviços.
5. **Expansão:** 13 em entregas por serviço; consolidar 14 e aplicar 15 por integração.

O MVP inclui catálogo, detalhes, registro mínimo de plugins, múltiplas origens,
um caminho validado de reprodução e pesquisa Soulseek. Transferências,
importações de coleções e demais serviços são incrementos independentes seguintes.
Não estimar calendário antes de fechar escopo e provas técnicas.

## Relação com os demais documentos

- O [roadmap geral](roadmap-prioridades-features.md) mantém a ordem das features
  locais; esta trilha concentra o planejamento de integrações musicais.
- A [reprodução a partir de coleções](features/source-collection-playback.md) e o
  [destaque contextual](features/contextual-track-highlighting.md) documentam
  comportamentos que precisam ser preservados na evolução da fila.
- O [roteiro de enriquecimento](roteiro-melhorias-enriquecimento.md) continua
  responsável por manutenção e políticas compartilhadas já existentes.

## Referências para as provas técnicas

Referências herdadas dos planos de 17–19/10/2026, sem nova verificação externa
nesta consolidação. Conferir documentação e executar provas na etapa 5.

- [MusicBrainz: busca](https://musicbrainz.org/doc/MusicBrainz_API/Search) e
  [limites](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting).
- [YouTube: busca](https://developers.google.com/youtube/data/guides/implementation/search)
  e [políticas de integração](https://developers.google.com/youtube/terms/developer-policies).
- [SoundCloud: guia](https://developers.soundcloud.com/docs/api/guide) e
  [endpoints](https://developers.soundcloud.com/docs/api/explorer/).
- [Bandcamp: desenvolvedores](https://bandcamp.com/developer).
- [slskd](https://github.com/slskd/slskd) e
  [configuração](https://github.com/slskd/slskd/blob/master/docs/config.md).
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) e
  [extratores](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).
