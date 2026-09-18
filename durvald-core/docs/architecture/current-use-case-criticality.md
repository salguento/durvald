# F0.04 — Classificação dos casos de uso por criticidade

Este documento classifica por criticidade os **180 casos de uso/comportamentos** catalogados na F0.03 em `current-use-cases.md`.

A classificação define **a ordem de criação e endurecimento dos testes de caracterização durante a Fase 0**. Ela não muda o contrato atual, não remove comportamentos e não representa prioridade de roadmap de produto.

## Snapshot analisado

A classificação parte do catálogo F0.03 presente em `main` após o commit:

```text
a4b76fbb3de862198eaaa79822638bf8105c0f02
```

Os IDs da F0.03 são preservados sem renumeração ou reutilização.

## Níveis

| Prioridade | Definição | Regra prática para testes |
| --- | --- | --- |
| **P0 — crítico** | Se quebrar, o core deixa de abrir, a biblioteca deixa de ser utilizável, playback/queue deixam de funcionar, estado essencial pode ser perdido ou o contrato de entrada dos clientes deixa de funcionar. | Proteger primeiro. Deve bloquear migração arquitetural quando houver regressão. |
| **P1 — funcional importante** | Quebra uma capacidade relevante e já utilizada do produto, mas o Durvald ainda consegue abrir e cumprir seu fluxo essencial de biblioteca/reprodução. | Proteger depois da baseline P0 e antes de mover a área correspondente. |
| **P2 — secundário / edge case** | Diagnóstico, política auxiliar, compatibilidade específica, recurso opcional ou caso de borda cuja quebra não impede o fluxo principal. | Proteger após P0/P1, preferencialmente antes de refatorar diretamente o componente responsável. |

### O que a prioridade não significa

- **P2 não significa descartável.** O comportamento continua fazendo parte da baseline atual.
- A prioridade é do **caso de uso**, não do arquivo ou módulo.
- Um componente funcionalmente opcional pode participar de um caso P0 se sua inicialização hoje for obrigatória para `DurvaldCore::open`.
- Severidade de segurança, impacto de dados e criticidade de migração não são exatamente a mesma dimensão. Alguns edge cases de segurança ficam em P1 mesmo sem pertencer ao fluxo mais frequente.
- A classificação pode ser revista somente por uma decisão explícita de arquitetura/produto; não deve mudar apenas para facilitar uma refatoração.

---

# Gates transversais P0

A F0.03 cataloga comportamento do domínio/core e, portanto, não criou IDs separados para mecanismo de transporte/compilação. Ainda assim, a F0.02 demonstrou que os clientes dependem da fronteira Rust e UniFFI.

Os seguintes gates são **P0 transversais** e devem acompanhar todos os testes P0:

- build de `durvald-core`;
- build de `durvald-core --features uniffi`;
- geração dos bindings Swift;
- compilação do cliente macOS contra os bindings;
- compilação do cliente GTK contra a API Rust;
- factory UniFFI `open(config)` continuar produzindo um `DurvaldCore` utilizável.

Esses gates não recebem novos IDs nesta etapa porque não são novos casos de uso da F0.03.

---

# Lifecycle

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| CORE-001 | **P0** | Sem abrir o core nenhum fluxo é utilizável. |
| CORE-002 | **P0** | Diretórios obrigatórios ausentes impedem inicialização/persistência. |
| CORE-003 | **P0** | O pool SQLite e seus pragmas sustentam toda persistência. |
| CORE-004 | **P0** | Sem schema base biblioteca, settings e sessão não funcionam. |
| CORE-005 | **P0** | Migration com falha bloqueia `open` no desenho atual. |
| CORE-006 | **P0** | Settings iniciais são necessários durante abertura. |
| CORE-007 | **P0** | Sessão inicial é lida obrigatoriamente durante abertura. |
| CORE-008 | **P0** | Restauração de sessão/queue é contrato essencial explicitamente protegido. |
| CORE-009 | **P1** | Crossfade/normalização restaurados são importantes, mas playback básico continua conceitualmente possível sem eles. |
| CORE-010 | **P0** | `SecureStore::new` faz parte de `open`; sua falha hoje impede abrir o core. |
| CORE-011 | **P0** | `LastFmClient::new` é inicializado obrigatoriamente em `open`; falha impede abertura mesmo sendo Last.fm uma feature P1. |
| CORE-012 | **P0** | O serviço de enrichment é construído como dependência obrigatória do core atual. |
| CORE-013 | **P0** | Coordenação automática sustenta avanço/completion da reprodução. |
| CORE-014 | **P0** | Persistência após transição protege continuidade da sessão. |

**Resumo:** 13 P0, 1 P1, 0 P2.

---

# Library

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| LIB-001 | **P0** | Scan é o mecanismo principal de entrada/indexação da biblioteca. |
| LIB-002 | **P0** | É o fluxo normal de rescan das pastas configuradas. |
| LIB-003 | **P1** | Cancelamento é funcionalidade importante e de segurança operacional, mas não é requisito para uso básico. |
| LIB-004 | **P1** | Progresso é importante para operação/UI, sem ser necessário para indexar. |
| LIB-005 | **P1** | Evita concorrência inválida de scans; importante para consistência. |
| LIB-006 | **P0** | Sem configurar uma pasta uma instalação vazia não forma biblioteca. |
| LIB-007 | **P0** | Os caminhos configurados dirigem o scan principal. |
| LIB-008 | **P1** | Gerenciamento de paths é importante, mas remover path não é fluxo essencial diário. |
| LIB-009 | **P0** | Listagem de tracks é o núcleo da biblioteca local. |
| LIB-010 | **P0** | O cliente macOS usa paginação para carregar biblioteca em escala. |
| LIB-011 | **P0** | Lookup de track sustenta playback e diversas operações. |
| LIB-012 | **P1** | Navegação por releases é importante, mas não impede playback básico de tracks. |
| LIB-013 | **P1** | Paginação de releases é importante para a UI de biblioteca. |
| LIB-014 | **P1** | Detalhe de release é funcionalidade importante. |
| LIB-015 | **P1** | Sustenta álbum/release playback e composição de filas. |
| LIB-016 | **P1** | Navegação por artistas é importante, mas não requisito mínimo de playback. |
| LIB-017 | **P1** | Lookup de artista é importante para detalhes/enrichment. |
| LIB-018 | **P1** | Relação artista → releases é funcionalidade de biblioteca. |
| LIB-019 | **P1** | Relação artista → tracks é funcionalidade de biblioteca. |
| LIB-020 | **P1** | Busca é central à usabilidade, mas não à inicialização/reprodução mínima. |
| LIB-021 | **P1** | Reconciliation mantém biblioteca coerente após remoções de arquivos. |
| LIB-022 | **P0** | Quebra pode transformar cancelamento/parcial em perda destrutiva de registros. |
| LIB-023 | **P0** | O conjunto de formatos aceitos define o que entra na biblioteca e evita indexação incompatível. |
| LIB-024 | **P1** | Rescan correto de tracks existentes é importante para manutenção da biblioteca. |
| LIB-025 | **P1** | Favoritos de track são funcionalidade persistente relevante. |
| LIB-026 | **P1** | Favoritos de release são funcionalidade persistente relevante. |
| LIB-027 | **P2** | Hidden é estado secundário de apresentação. |
| LIB-028 | **P2** | Hidden de release é estado secundário de apresentação. |
| LIB-029 | **P2** | Suggest-less ainda é sinal secundário no produto atual. |
| LIB-030 | **P2** | Suggest-less de release é sinal secundário. |
| LIB-031 | **P2** | Rating é funcionalidade disponível, mas não necessária ao fluxo principal atual. |
| LIB-032 | **P2** | Rating de release é funcionalidade secundária. |

**Resumo:** 9 P0, 17 P1, 6 P2.

---

# Playback

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| PLAY-001 | **P0** | Reproduzir áudio é função central do Durvald. |
| PLAY-002 | **P0** | Snapshot é a fonte de estado dos clientes. |
| PLAY-003 | **P0** | Controle básico de playback. |
| PLAY-004 | **P0** | Controle básico e restauração de sessão. |
| PLAY-005 | **P0** | Controle básico de playback. |
| PLAY-006 | **P0** | Seek é controle fundamental já consumido pelo cliente. |
| PLAY-007 | **P0** | Volume faz parte do estado essencial e é persistido. |
| PLAY-008 | **P0** | Shuffle altera semântica da fila e é persistido na sessão. |
| PLAY-009 | **P0** | Repeat altera semântica de avanço/completion e é persistido. |
| PLAY-010 | **P0** | Queue foi explicitamente definida como área crítica. |
| PLAY-011 | **P0** | Clientes dependem da representação corrente da queue. |
| PLAY-012 | **P0** | Navegação principal da fila. |
| PLAY-013 | **P0** | Navegação principal da fila. |
| PLAY-014 | **P0** | Seleção explícita de item da queue é comportamento atual do player. |
| PLAY-015 | **P0** | Mutação fundamental da queue. |
| PLAY-016 | **P0** | Ordem da queue é parte do contrato atual. |
| PLAY-017 | **P0** | Reset da queue é usado por fluxos de álbum/playlist. |
| PLAY-018 | **P0** | Session restoration foi definida como crítica. |
| PLAY-019 | **P0** | Sem persistência, comandos de playback perdem continuidade entre execuções. |
| PLAY-020 | **P0** | Posição restaurada depende da persistência de seek/progresso. |
| PLAY-021 | **P0** | Volume restaurado depende da persistência correta. |
| PLAY-022 | **P1** | Preload sustenta gapless, mas não é requisito para playback simples. |
| PLAY-023 | **P0** | Sem avanço automático a queue deixa de cumprir seu comportamento central. |
| PLAY-024 | **P1** | Gapless é comportamento de qualidade de playback, não requisito mínimo para tocar áudio. |
| PLAY-025 | **P2** | Crossfade é configuração opcional. |
| PLAY-026 | **P2** | ReplayGain/normalização é configuração opcional. |
| PLAY-027 | **P1** | Histórico interno de navegação dá semântica correta a Previous, mas não impede play/pause básico. |

**Resumo:** 22 P0, 3 P1, 2 P2.

---

# History

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| HIST-001 | **P1** | Histórico/play count depende do registro de completions. |
| HIST-002 | **P2** | Repeat One gerar entradas adicionais é uma interação específica entre dois comportamentos. |
| HIST-003 | **P1** | Listagem de histórico é feature explícita do produto. |
| HIST-004 | **P1** | O cliente pagina histórico real. |
| HIST-005 | **P1** | Remoção individual faz parte do gerenciamento do histórico. |
| HIST-006 | **P1** | Limpeza total faz parte do gerenciamento do histórico. |
| HIST-007 | **P2** | Separação entre histórico persistente e navegação Previous é uma nuance interna importante, mas edge case de regressão. |

**Resumo:** 0 P0, 5 P1, 2 P2.

---

# Playlists

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| PLST-001 | **P1** | Playlists são feature funcional importante. |
| PLST-002 | **P1** | Criação é operação central da feature. |
| PLST-003 | **P1** | Lookup sustenta edição e exibição. |
| PLST-004 | **P1** | Edição/rename é operação central da feature. |
| PLST-005 | **P1** | Exclusão é operação central da feature. |
| PLST-006 | **P1** | Ordem de tracks define conteúdo e playback da playlist. |
| PLST-007 | **P1** | Adição de track é operação central da feature. |
| PLST-008 | **P1** | Remoção de track é operação central da feature. |
| PLST-009 | **P1** | Ordem persistente é parte do contrato da playlist. |
| PLST-010 | **P2** | Favorito de playlist é atributo secundário. |
| PLST-011 | **P2** | Suggest-less é atributo secundário. |
| PLST-012 | **P2** | Artwork de playlist é apresentação, não conteúdo funcional essencial. |
| PLST-013 | **P1** | Play playlist é fluxo de produto já observado no cliente. |
| PLST-014 | **P1** | Shuffle de playlist é variação funcional relevante do fluxo. |
| PLST-015 | **P1** | Enfileirar playlist é fluxo relevante de playback. |
| PLST-016 | **P1** | “Play next” preserva uma semântica de queue usada pelo cliente. |

**Resumo:** 0 P0, 13 P1, 3 P2.

---

# Metadata e artwork

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| META-001 | **P1** | Extração pública/preview é importante e representa a semântica do parser atual. |
| META-002 | **P1** | Leitura é base do editor de metadata. |
| META-003 | **P2** | Backfill de bibliotecas anteriores é caminho de compatibilidade específico. |
| META-004 | **P1** | Edição database-only é comportamento funcional importante. |
| META-005 | **P1** | Gravação no arquivo é comportamento funcional e potencialmente destrutivo se regredir. |
| META-006 | **P1** | Validação protege integridade da edição. |
| META-007 | **P1** | Preservar tags/artwork evita perda de dados do arquivo. |
| META-008 | **P1** | Journal é requisito para undo e recuperação segura. |
| META-009 | **P1** | Undo é parte explícita do editor atual. |
| META-010 | **P2** | Extração de artwork é subcomportamento secundário ao scan de áudio. |
| META-011 | **P2** | Limites de imagem são edge cases específicos do pipeline. |
| META-012 | **P2** | Persistência física do asset é detalhe de infraestrutura desde que o contrato final permaneça. |
| META-013 | **P1** | Leitura de artwork é usada diretamente pelo cliente. |
| META-014 | **P1** | Restringir leitura a `covers_dir` protege fronteira de filesystem. |
| META-015 | **P1** | Canonicalização/symlink evita escape da fronteira de filesystem. |
| META-016 | **P2** | Thumbnail é derivado de apresentação e pode ser protegido depois. |

**Resumo:** 0 P0, 11 P1, 5 P2.

---

# Enrichment

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| ENR-001 | **P1** | Configuração controla toda a feature de enrichment. |
| ENR-002 | **P1** | Escrita de configuração e offline mode são contratos funcionais. |
| ENR-003 | **P1** | Identidade persistida é a base do enrichment por artista. |
| ENR-004 | **P1** | Resolução de candidatos é fluxo principal de identidade. |
| ENR-005 | **P1** | Confirmação de identidade é fluxo principal. |
| ENR-006 | **P1** | Limpeza/reversão da identidade é operação funcional. |
| ENR-007 | **P1** | Leitura local de detalhes é contrato de frontend. |
| ENR-008 | **P1** | Discografia persistida é feature exposta. |
| ENR-009 | **P1** | Popular tracks persistidas são feature exposta. |
| ENR-010 | **P1** | Detalhe de release externo é feature exposta. |
| ENR-011 | **P1** | Refresh explícito é operação central da feature. |
| ENR-012 | **P1** | Profile é seção funcional de refresh. |
| ENR-013 | **P1** | Portrait é seção funcional de refresh. |
| ENR-014 | **P1** | Discography é seção funcional de refresh. |
| ENR-015 | **P1** | Covers são seção funcional de refresh. |
| ENR-016 | **P1** | Popular tracks são seção funcional de refresh. |
| ENR-017 | **P1** | Similar artists é seção funcional de refresh. |
| ENR-018 | **P1** | Sincronização cache → catálogo local altera metadata percebida. |
| ENR-019 | **P1** | Override editorial é comportamento funcional persistente. |
| ENR-020 | **P1** | Limpeza de override é contraparte necessária da edição. |
| ENR-021 | **P1** | Limpeza seletiva por provider é operação funcional de manutenção. |
| ENR-022 | **P2** | TTL de snapshot fresco é detalhe específico de cache. |
| ENR-023 | **P2** | Fallback stale é política de cache específica. |
| ENR-024 | **P1** | “Disabled não faz rede” é contrato explícito e importante. |
| ENR-025 | **P1** | “Offline não faz rede” é contrato explícito e importante. |
| ENR-026 | **P2** | Negative cache de Not Found é política auxiliar. |
| ENR-027 | **P2** | Retenção/classificação de falha transitória é política auxiliar. |
| ENR-028 | **P2** | Retry-after/rate limit é comportamento importante de provider, mas secundário ao fluxo funcional base. |
| ENR-029 | **P2** | Single-flight é otimização/coordenação interna; contrato funcional não exige a implementação específica. |
| ENR-030 | **P2** | Diagnostics por seção são explicitamente secundários para esta ordem de proteção. |
| ENR-031 | **P1** | Artwork remoto faz parte do resultado funcional do enrichment. |
| ENR-032 | **P2** | Attribution/proveniência é metadata auxiliar do resultado. |

**Resumo:** 0 P0, 24 P1, 8 P2.

---

# Last.fm

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| LFM-001 | **P1** | Status é entrada principal da UI da integração. |
| LFM-002 | **P1** | Configuração de credenciais inicia a feature. |
| LFM-003 | **P1** | Segurança/persistência de credenciais é requisito do fluxo. |
| LFM-004 | **P1** | Token/URL é etapa necessária de autenticação. |
| LFM-005 | **P1** | Completar auth é etapa necessária de autenticação. |
| LFM-006 | **P1** | Now Playing é comportamento principal da integração. |
| LFM-007 | **P1** | Pausa deve parar a contagem real de scrobble. |
| LFM-008 | **P1** | Resume deve retomar a contagem sem duplicar tempo. |
| LFM-009 | **P1** | Elegibilidade define correção do scrobble. |
| LFM-010 | **P1** | Scrobble é a finalidade principal da integração. |
| LFM-011 | **P1** | Não scrobblar playback insuficiente é parte da correção funcional. |
| LFM-012 | **P1** | Logout/disconnect é operação principal de lifecycle da integração. |
| LFM-013 | **P1** | Remover credenciais é requisito do logout. |
| LFM-014 | **P2** | Limpeza seletiva do cache Last.fm é efeito auxiliar do logout. |
| LFM-015 | **P2** | Mapeamento fino de categorias de erro é detalhe de fronteira. |

**Resumo:** 0 P0, 13 P1, 2 P2.

---

# Settings

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| SET-001 | **P1** | Settings são estado persistente importante do app. |
| SET-002 | **P1** | Escrita de settings é contrato funcional. |
| SET-003 | **P1** | Validação evita persistência de configuração inválida. |
| SET-004 | **P2** | Aplicação imediata de crossfade é detalhe de setting opcional. |
| SET-005 | **P2** | Aplicação imediata de normalização é detalhe de setting opcional. |
| SET-006 | **P1** | Persistência é necessária para settings sobreviverem ao restart. |
| SET-007 | **P1** | Restauração faz parte do contrato persistente. |
| SET-008 | **P2** | Normalização de valores legados é compatibilidade/edge case. |
| SET-009 | **P1** | `InvalidInput` em configuração inválida é contrato observável. |

**Resumo:** 0 P0, 6 P1, 3 P2.

---

# Secure storage

| ID | Prioridade | Justificativa |
| --- | --- | --- |
| SEC-001 | **P1** | É o lifecycle próprio do store; a dependência de `open` está protegida separadamente em CORE-010. |
| SEC-002 | **P1** | Store de secret sustenta credenciais Last.fm. |
| SEC-003 | **P1** | Retrieval de secret sustenta autenticação persistente. |
| SEC-004 | **P1** | Delete é necessário para logout seguro. |
| SEC-005 | **P2** | Missing value é caso de borda do storage. |
| SEC-006 | **P2** | Migração do formato legado é compatibilidade específica. |
| SEC-007 | **P2** | Cleanup de artefato legado é consequência da migração. |
| SEC-008 | **P2** | KV não sensível é detalhe interno do storage atual. |
| SEC-009 | **P2** | Persistência física do KV é detalhe interno. |
| SEC-010 | **P2** | Permissões Unix são proteção específica de plataforma; continuam obrigatórias, mas entram depois no plano de caracterização. |
| SEC-011 | **P2** | Erros de plataforma específicos são edge cases de adapter. |
| SEC-012 | **P2** | Mapping específico SecureStore → CoreError é detalhe de fronteira da integração. |

**Resumo:** 0 P0, 4 P1, 8 P2.

---

# Distribuição final

| Área | P0 | P1 | P2 | Total |
| --- | ---: | ---: | ---: | ---: |
| Lifecycle | 13 | 1 | 0 | 14 |
| Library | 9 | 17 | 6 | 32 |
| Playback | 22 | 3 | 2 | 27 |
| History | 0 | 5 | 2 | 7 |
| Playlists | 0 | 13 | 3 | 16 |
| Metadata/artwork | 0 | 11 | 5 | 16 |
| Enrichment | 0 | 24 | 8 | 32 |
| Last.fm | 0 | 13 | 2 | 15 |
| Settings | 0 | 6 | 3 | 9 |
| Secure storage | 0 | 4 | 8 | 12 |
| **Total** | **44** | **97** | **39** | **180** |

Todos os 180 IDs definidos na F0.03 aparecem exatamente uma vez nesta classificação.

---

# Ordem recomendada para criação dos testes

A prioridade não deve ser interpretada apenas como três grandes lotes. Dentro de P0 há uma dependência natural entre os testes.

## Onda 1 — P0: abrir e atravessar a fronteira

Criar primeiro uma smoke baseline cobrindo:

- gates Rust/UniFFI/Swift/GTK;
- CORE-001–CORE-007;
- CORE-010–CORE-012;
- configuração mínima temporária;
- abertura de banco novo;
- abertura de banco já existente/migrável.

**Objetivo:** antes de testar qualquer regra interna, provar que os clientes ainda conseguem obter um core utilizável.

## Onda 2 — P0: biblioteca mínima

Cobrir:

- LIB-001, LIB-002;
- LIB-006, LIB-007;
- LIB-009–LIB-011;
- LIB-022, LIB-023;
- scan de fixture pequena;
- rescan sem corrupção;
- cancelamento parcial não destrutivo como proteção para LIB-022.

**Objetivo:** garantir que uma biblioteca pode ser criada, indexada e lida.

## Onda 3 — P0: playback e queue

Cobrir:

- PLAY-001–PLAY-021;
- PLAY-023;
- CORE-008, CORE-013, CORE-014;
- fila vazia;
- track ativa + próximos itens;
- next/previous;
- persistência após comandos;
- restart/restauração de sessão.

**Objetivo:** congelar o contrato de player antes de qualquer extração para `PlaybackApplication`.

## Onda 4 — P1: biblioteca rica e features persistentes

Cobrir em paralelo por domínio:

1. Library P1;
2. playlists;
3. history;
4. metadata editing;
5. settings;
6. secure storage funcional.

**Objetivo:** proteger funcionalidades persistentes locais antes da migração de repositories/adapters.

## Onda 5 — P1: integrações remotas

Cobrir:

- enrichment P1;
- Last.fm P1;
- políticas explícitas “disabled/offline não fazem rede”;
- providers usando doubles/fixtures, sem depender de serviços reais na suíte determinística.

**Objetivo:** congelar os contratos de integração antes da especialização em providers/adapters.

## Onda 6 — P2: políticas e edge cases

Completar:

- diagnostics;
- TTL/cache negativo/stale;
- crossfade/ReplayGain;
- ratings/hidden/suggest-less;
- compatibilidade de metadata;
- migração/permissões/erros específicos do secure storage;
- demais casos P2.

**Objetivo:** fechar a baseline sem atrasar a proteção inicial das áreas que podem tornar o Durvald inutilizável.

---

# Regra para PRs da migração

A partir desta classificação, uma PR que altera uma área deve declarar os IDs afetados e manter verdes:

1. todos os **P0 globais** já cobertos;
2. todos os **P0 da área**;
3. todos os **P1 da área** já cobertos;
4. P2 relacionados diretamente ao trecho alterado.

Exemplo:

```text
Fase 3 — introduz PlaybackApplication

Contrato afetado:
PLAY-001–PLAY-027

Gates obrigatórios:
- todos os P0 globais
- PLAY-001–PLAY-021
- PLAY-023
- P1/P2 de playback já cobertos pela baseline
```

A existência de um teste P2 falhando não autoriza aceitar regressão; a prioridade determina **quando criar a proteção**, não quais regressões podem ser ignoradas depois que a baseline existe.

# Critério de conclusão da F0.04

- [x] todos os 180 IDs da F0.03 classificados;
- [x] cada ID aparece exatamente uma vez;
- [x] P0 concentra abertura, database/schema/migrations, scan essencial, playback, queue e session restoration;
- [x] gates Rust/UniFFI/Swift/GTK tratados como proteção transversal P0;
- [x] playlists, history, metadata editing, Last.fm e enrichment classificados majoritariamente como P1;
- [x] diagnostics, políticas específicas de cache e edge cases concentrados em P2;
- [x] comportamentos com risco de perda de dados receberam prioridade superior quando necessário;
- [x] ordem de implementação dos testes definida a partir das prioridades;
- [x] nenhuma alteração de código de produção foi necessária para concluir esta etapa.
