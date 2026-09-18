# F0.05 — Invariantes comportamentais atuais

Este documento identifica as **regras que precisam continuar verdadeiras** durante a migração arquitetural do `durvald-core`.

A F0.03 catalogou o que o sistema faz. A F0.04 classificou a criticidade desses comportamentos. A F0.05 registra as relações e propriedades que os testes devem proteger **independentemente de como classes, módulos, crates, repositories, services ou adapters sejam reorganizados**.

Um teste de caracterização útil não deve provar apenas que uma operação retornou `Ok`. Ele deve provar, por exemplo, que:

```text
scan cancelado
→ não reconcilia arquivos desaparecidos
→ não remove registros já existentes
```

ou:

```text
artwork fora de covers_dir
→ CoreError::InvalidInput
```

## Snapshot analisado

Esta baseline parte do estado de `main` após a F0.04, no commit:

```text
91ebe44b82f37c71935bd3f56899e70228989e98
```

As fontes principais são:

- contratos explícitos em `durvald-core/README.md`;
- catálogo F0.03;
- classificação F0.04;
- implementação atual de `DurvaldCore`;
- scan/database operations;
- audio player/gapless;
- metadata e metadata editing;
- enrichment;
- Last.fm;
- secure storage.

## Como ler este documento

Cada invariante recebe um ID próprio no formato:

```text
INV-<ÁREA>-NNN
```

Esses IDs identificam **regras**, enquanto `PLAY-001`, `LIB-001` etc. identificam **casos de uso**.

A prioridade acompanha a criticidade dos comportamentos protegidos:

- **P0** — regressão pode impedir o funcionamento essencial, causar perda indevida de estado ou quebrar um contrato fundamental;
- **P1** — regressão quebra funcionalidade importante;
- **P2** — regra secundária, política específica ou edge case.

---

# Lifecycle e persistência

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-CORE-001** | **P0** | Após `open` bem-sucedido, app support, banco/schema mínimo, settings e estado de sessão necessários ao funcionamento estão disponíveis. | CORE-001–CORE-007 |
| **INV-CORE-002** | **P0** | Abrir uma instalação já existente deve aplicar as migrations suportadas e deixar os dados anteriores utilizáveis; migration não pode transformar uma base válida em uma base ilegível. | CORE-001, CORE-004, CORE-005 |
| **INV-CORE-003** | **P0** | Estado persistido de playback é restaurado de forma coerente: track atual, posição, volume, queue, shuffle e repeat continuam representando a sessão anterior dentro dos limites de normalização atuais. | CORE-008, PLAY-018–PLAY-021 |
| **INV-CORE-004** | **P0** | Uma alteração arquitetural pode trocar pool, repository ou schema interno, mas não pode fazer o cliente precisar conhecer esses detalhes para abrir e usar o core. | CORE-001, F0.02 public surface |

---

# Scan e biblioteca local

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-SCAN-001** | **P0** | No máximo um scan de biblioteca pode estar ativo. Tentar iniciar outro enquanto há um scan em andamento resulta em `CoreError::InvalidInput`. | LIB-001, LIB-005 |
| **INV-SCAN-002** | **P1** | Cancelar quando nenhum scan está ativo resulta em `CoreError::NotFound`. | LIB-003 |
| **INV-SCAN-003** | **P0** | Cancelamento é cooperativo: depois que a cancellation é observada em uma fronteira segura, novos resultados extraídos não devem ser persistidos. | LIB-003, LIB-022 |
| **INV-SCAN-004** | **P0** | Scan parcial, cancelado ou cuja descoberta não foi completa **não reconcilia** arquivos ausentes e não remove registros existentes por ausência na descoberta parcial. | LIB-003, LIB-022 |
| **INV-SCAN-005** | **P1** | Scan completo reconcilia o root processado: arquivos anteriormente indexados que realmente desapareceram são removidos da biblioteca. | LIB-001, LIB-021 |
| **INV-SCAN-006** | **P0** | O walker não segue symlinks de arquivo nem de diretório; a biblioteca não pode escapar do root selecionado nem entrar em ciclo por links. | LIB-001, LIB-023 |
| **INV-SCAN-007** | **P0** | O conjunto aceito para indexação local corresponde aos formatos para os quais existe decoder de playback no build atual: MP3, WAV, FLAC e Ogg Vorbis (`.ogg`/`.oga`). | LIB-023 |
| **INV-SCAN-008** | **P1** | Scan e metadata edit não podem concorrer de forma que metadata antiga extraída antes de uma edição sobrescreva a edição do usuário. | LIB-024, META-004, META-005 |
| **INV-SCAN-009** | **P1** | Um caminho configurado como library path precisa ser um diretório existente; caso contrário a operação pública o rejeita como `InvalidInput`. | LIB-006 |

---

# Paginação, busca e identificadores

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-LIB-001** | **P0** | IDs negativos recebidos pelas operações públicas que exigem IDs de entidade são input inválido, não IDs “não encontrados”. | LIB-011, LIB-014, LIB-017, PLAY-001 e operações por ID |
| **INV-LIB-002** | **P0/P1** | Paginação exige `page_size > 0`; offset acima do domínio SQLite aceito é `InvalidInput`; páginas são limitadas atualmente a no máximo 200 itens. | LIB-010, LIB-013, HIST-004 |
| **INV-LIB-003** | **P0/P1** | `next_offset` só existe quando há mais resultados e avança a partir do offset da página retornada; a página final não anuncia continuação. | LIB-010, LIB-013, HIST-004 |
| **INV-LIB-004** | **P1** | Busca com query vazia ou apenas whitespace é `InvalidInput`; query válida é normalizada por trim antes da busca. | LIB-020 |
| **INV-LIB-005** | **P2** | Rating público aceita ausência ou valor entre 0 e 5; valores acima de 5 são `InvalidInput`. | LIB-031, LIB-032 |

---

# Playback e queue

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-PLAY-001** | **P0** | `play(track)` inicia a track selecionada sem inserir uma segunda cópia dela na fila de próximos itens. | PLAY-001 |
| **INV-PLAY-002** | **P0** | O snapshot de apresentação coloca a track ativa primeiro quando ela existe; posições de queue expostas ao cliente são contíguas e zero-based. | PLAY-002, PLAY-011 |
| **INV-PLAY-003** | **P0** | A track ativa não pode ser removida nem movida pelas operações destinadas aos próximos itens da queue. | PLAY-014–PLAY-016 |
| **INV-PLAY-004** | **P0** | `clear_queue` remove os próximos itens, mas preserva a track atualmente ativa. | PLAY-017 |
| **INV-PLAY-005** | **P0** | Adicionar uma track a uma queue sem playback ativo pode iniciar essa track; com playback ativo, o item entra como sucessor sem substituir a track atual. | PLAY-010 |
| **INV-PLAY-006** | **P0** | `next` sem sucessor e `previous` sem histórico de navegação retornam `NotFound`, em vez de fabricar uma track ou silently no-op. | PLAY-012, PLAY-013 |
| **INV-PLAY-007** | **P0** | Mutações relevantes de playback/queue persistem a sessão; seek persiste progresso e mudança de volume persiste o volume normalizado. | PLAY-019–PLAY-021 |
| **INV-PLAY-008** | **P0** | Volume público não aceita NaN/infinito; valores finitos são mantidos no intervalo 0.0–1.0. | PLAY-007 |
| **INV-PLAY-009** | **P0** | Avanço automático ao final de uma track não depende de polling da UI. O cliente pode deixar de consultar `playback()` e a transição ainda deve ocorrer. | CORE-013, PLAY-023 |
| **INV-PLAY-010** | **P1** | Alterar manualmente queue/track ou políticas que invalidem o sucessor preparado não pode deixar uma transição gapless obsoleta ser aplicada depois. | PLAY-012–PLAY-016, PLAY-022–PLAY-024 |
| **INV-PLAY-011** | **P1** | Gapless prepara somente a continuidade necessária do playback atual; a implementação atual mantém current + next, não uma fila inteira decodificada em memória. | PLAY-022, PLAY-024 |
| **INV-PLAY-012** | **P2** | Mudanças manuais de track usam a política configurada de crossfade; automatic gapless não introduz o fade/overlap de uma troca manual. | PLAY-024, PLAY-025 |
| **INV-PLAY-013** | **P2** | ReplayGain só altera ganho quando há tag válida e limitada a -24 dB…+24 dB; tag ausente/inválida deixa o volume selecionado pelo usuário sem ajuste de ReplayGain. | PLAY-026 |

---

# Histórico

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-HIST-001** | **P1** | Cada completion de playback gera um evento persistente próprio; a mesma track concluída novamente em Repeat One gera outra entrada. | HIST-001, HIST-002 |
| **INV-HIST-002** | **P1** | Histórico persistente de escuta e histórico interno usado para `Previous` são conceitos distintos. Navegação da queue não deve ser implementada lendo/modificando o histórico persistente como se fossem a mesma coisa. | HIST-001, HIST-007, PLAY-013, PLAY-027 |

---

# Playlists

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-PLST-001** | **P1** | Nome de playlist não pode ser vazio/whitespace em create/update. | PLST-002, PLST-004 |
| **INV-PLST-002** | **P1** | `playlist_tracks` preserva a ordem persistida; add/remove/move operam sobre posições da playlist, não sobre uma ordenação derivada da UI. | PLST-006–PLST-009 |
| **INV-PLST-003** | **P1** | Excluir uma playlist remove suas associações de tracks sem exigir que o cliente delete as entradas individualmente. | PLST-005 |
| **INV-PLST-004** | **P1** | “Play playlist” atual é equivalente a carregar tracks a partir da posição escolhida, limpar próximos itens, tocar a primeira e enfileirar as demais; shuffle pode alterar a ordem escolhida, mas não o conjunto selecionado. | PLST-013, PLST-014, PLAY-001, PLAY-010, PLAY-017 |

---

# Artwork e filesystem gerenciado

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-ART-001** | **P1** | `covers_dir` é a área gerenciada de artwork. O core não deve tratar um path arbitrário fornecido pelo cliente como asset gerenciado. | META-012, META-013 |
| **INV-ART-002** | **P1** | Artwork existente cuja canonical path fica fora de `covers_dir` resulta em `CoreError::InvalidInput`. | META-013, META-014 |
| **INV-ART-003** | **P1** | Symlink localizado dentro de `covers_dir` mas apontando para fora também é rejeitado; a validação usa o destino canonicalizado. | META-013, META-015 |
| **INV-ART-004** | **P2** | Identificador de artwork vazio ou que não resolve para arquivo retorna ausência de asset, não acesso arbitrário a filesystem. | META-013 |
| **INV-ART-005** | **P2** | Artwork embutido é input não confiável: imagem inválida, formato não aceito ou acima dos limites não deve invalidar uma track de áudio que de resto é válida. | META-010, META-011 |
| **INV-ART-006** | **P2** | Artwork local gerenciado aceita JPEG/PNG, limitado atualmente a 10 MiB, dimensões máximas de 4096×4096 e allocation decode limitada. | META-010–META-012 |
| **INV-ART-007** | **P2** | Artwork remoto pode chegar como JPEG/PNG/WebP/GIF, mas entra no cache local somente depois de validação/normalização; formatos não suportados são rejeitados. | ENR-031, META-011 |
| **INV-ART-008** | **P2** | Thumbnail é best-effort: falha na miniatura não deve tornar indisponível o artwork completo válido. | META-016 |

---

# Metadata editing

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-META-001** | **P1** | Título, artista e álbum editados são obrigatórios; track/disc não podem exceder 255 e ano, quando presente, fica entre 1 e 9999. Input inválido retorna `InvalidInput`. | META-004–META-006 |
| **INV-META-002** | **P1** | Edição database-only não altera bytes do arquivo e continua prevalecendo após rescan, até ser desfeita/substituída. | META-004, LIB-024 |
| **INV-META-003** | **P1** | Edição com `write_to_file=true` altera somente os campos gerenciados e preserva artwork e demais tags que não fazem parte da edição. | META-005, META-007 |
| **INV-META-004** | **P1** | Uma edição inválida falha antes de criar journal ou alterar arquivo/índice. | META-006, META-008 |
| **INV-META-005** | **P1** | Se a escrita de arquivo falha, o índice não pode aparentar que a edição foi aplicada; a tentativa fica registrada como falha no journal. | META-005, META-008 |
| **INV-META-006** | **P1** | Uma edição file-backed bem-sucedida mantém arquivo, índice e busca coerentes e produz estado passível de undo. | META-005, META-008, META-009 |
| **INV-META-007** | **P1** | Se o arquivo foi alterado externamente depois da edição, undo file-backed é bloqueado em vez de sobrescrever silenciosamente a alteração externa. | META-009 |
| **INV-META-008** | **P1** | Undo file-backed válido restaura o conteúdo anterior do arquivo e o estado correspondente do índice. | META-009 |
| **INV-META-009** | **P1** | Scan e edição compartilham uma fronteira de serialização: resultado de extração stale não deve desfazer uma metadata edit concluída. | LIB-024, META-004, META-005 |

---

# Erros públicos

A hierarquia de erro é um contrato arquitetural mais importante do que as mensagens atuais.

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-ERR-001** | **P0** | A fronteira pública/FFI expõe as categorias `InvalidInput`, `NotFound`, `Storage`, `Playback`, `Authentication` e `Network`. | superfície F0.02 |
| **INV-ERR-002** | **P0** | Clientes podem ramificar pela **variante**, mas não pelo texto. Mensagens são diagnósticas e podem mudar sem representar quebra de contrato. | todos os casos públicos com erro |
| **INV-ERR-003** | **P0/P1** | Input/estado inválido é `InvalidInput`; recurso/operação ausente é `NotFound`; falhas DB/filesystem/secure-store são `Storage`; falhas do engine/load de áudio são `Playback`. | LIB, PLAY, META, SEC |
| **INV-ERR-004** | **P1** | Last.fm que exige ação de credencial/autorização mapeia para `Authentication`; falha remota/rate-limit mapeia para `Network`. | LFM-001–LFM-015 |
| **INV-ERR-005** | **P1** | Diagnósticos nunca incluem valores de credenciais/segredos. | LFM-002–LFM-005, SEC-002–SEC-003 |

### Consequência para testes

Evitar:

```rust
assert_eq!(error.to_string(), "Track 42 not found");
```

Preferir:

```rust
assert!(matches!(error, CoreError::NotFound { .. }));
```

O texto só deve ser testado quando o próprio texto for explicitamente um contrato de produto, o que não é o caso dos `CoreError` atuais.

---

# Enrichment

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-ENR-001** | **P1** | Abrir o core e fazer scan de arquivos locais não iniciam requests de enrichment remoto. | CORE-001, LIB-001, ENR-001 |
| **INV-ENR-002** | **P1** | Reads locais de details/discography/popular tracks leem snapshots SQLite e não iniciam rede implicitamente. | ENR-007–ENR-009 |
| **INV-ENR-003** | **P1** | Enrichment desabilitado ou em offline mode impede novo trabalho de rede; refresh explícito retorna estado coerente de `Disabled`/`Offline` em vez de ignorar a política. | ENR-001, ENR-002, ENR-011, ENR-024, ENR-025 |
| **INV-ENR-004** | **P1** | Refresh requer ao menos uma seção e language tag válida/normalizada; input inválido é `InvalidInput`. | ENR-002, ENR-011 |
| **INV-ENR-005** | **P1** | Refresh que depende de identidade não prossegue como se houvesse identidade válida quando a identidade está unresolved/ambiguous/conflicting; o resultado indica necessidade de identidade. | ENR-003–ENR-006, ENR-011 |
| **INV-ENR-006** | **P2** | Snapshot fresco pode satisfazer leitura/refresh sem novo request; snapshot expirado continua legível nos fluxos offline/fallback que explicitamente permitem stale data. | ENR-022, ENR-023, ENR-026–ENR-028 |
| **INV-ENR-007** | **P2** | Refreshes concorrentes equivalentes para artista/language/seções/force compartilham o mesmo flight, evitando requests remotos duplicados desnecessários. | ENR-011, ENR-029 |
| **INV-ENR-008** | **P1** | Limpar dados de um provider não remove snapshots de outros providers nem metadata local. | ENR-021, LFM-014 |
| **INV-ENR-009** | **P1/P2** | Payload/JSON específico de provider não atravessa a API pública; a fronteira usa DTOs normalizados e attribution/proveniência próprias. | ENR-007–ENR-032, F0.02 |

---

# Last.fm

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-LFM-001** | **P1** | API key e API secret vazios são rejeitados; secret e session key são armazenados como secrets, não como valores públicos comuns. | LFM-002, LFM-003 |
| **INV-LFM-002** | **P1** | Trocar credenciais invalida session key/username anteriores; uma sessão de outro conjunto de credenciais não pode continuar sendo usada. | LFM-002–LFM-005 |
| **INV-LFM-003** | **P1** | Now Playing/scrobble exigem artist e track não vazios depois de trim. | LFM-006, LFM-010 |
| **INV-LFM-004** | **P1** | Tempo pausado não conta como tempo efetivamente tocado para elegibilidade de scrobble; pause acumula o período ativo e resume inicia novo período ativo. | LFM-007–LFM-009 |
| **INV-LFM-005** | **P1** | Uma track só é elegível a scrobble quando dura pelo menos 30 s e foi efetivamente tocada por pelo menos `min(50% da duração, 240 s)`. | LFM-009–LFM-011 |
| **INV-LFM-006** | **P1** | Disconnect remove session/API secrets e username/API key persistidos e limpa apenas os dados de enrichment do provider Last.fm, preservando os outros providers. | LFM-012–LFM-014 |

---

# Settings

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-SET-001** | **P1** | `cross_fade_duration <= 60`; `preferred_audio_quality` fica em 1…1411; source/path respeitam limites e não aceitam caracteres de controle. Violação é `InvalidInput`. | SET-002, SET-003, SET-009 |
| **INV-SET-002** | **P1/P2** | Leitura de valores legados normaliza em vez de propagar estado inválido: crossfade é limitado, qualidade inválida cai para 320 e volume legado 0–100 é convertido para 0–1. | SET-001, SET-007, SET-008 |
| **INV-SET-003** | **P1** | Alterar settings persiste o novo estado e configurações de áudio aplicáveis em runtime são refletidas pelo player sem exigir reconstrução do core. | SET-002, SET-004–SET-006 |
| **INV-SET-004** | **P1** | Settings persistidos sobrevivem a restart e são reaplicados durante `open`. | CORE-009, SET-006, SET-007 |

---

# Secure storage

| Invariante | Prioridade | Regra que deve continuar verdadeira | Casos relacionados |
| --- | --- | --- | --- |
| **INV-SEC-001** | **P1** | Em macOS/Windows/Linux, secrets usam o credential service da plataforma; dados não sensíveis permanecem separados do armazenamento de secrets. | SEC-001–SEC-004, SEC-008–SEC-009 |
| **INV-SEC-002** | **P2** | Leitura de secret inexistente sinaliza ausência; exclusão de secret inexistente é idempotente no credential service suportado. | SEC-004, SEC-005 |
| **INV-SEC-003** | **P2** | Quando um secret legado criptografado é encontrado, leitura pode migrá-lo para o credential service e remover o artefato legado depois de persistência bem-sucedida. | SEC-006, SEC-007 |
| **INV-SEC-004** | **P2** | Arquivos/diretórios gerenciados pelo fallback seguro em Unix usam permissões restritivas (diretório 0700, arquivos 0600). | SEC-010 |
| **INV-SEC-005** | **P2** | Falha de mutex/credential service/filesystem é retornada como erro; não deve ser convertida em sucesso silencioso nem exigir panic para sinalização. | SEC-011, SEC-012 |

---

# O que NÃO deve ser congelado como invariante

A F0.05 é também um filtro contra testes frágeis. Os seguintes detalhes pertencem à implementação atual e **não devem ser tratados como invariantes arquiteturais**, salvo quando um teste unitário interno precisar deles temporariamente:

| Detalhe atual | Por que não congelar |
| --- | --- |
| `r2d2`, `r2d2_sqlite` ou o tipo concreto do pool | Pode ser substituído por repository/adapter sem mudar comportamento. |
| nomes de tabelas/queries SQL internas | O schema pode evoluir preservando contrato. |
| `AudioPlayer`, Kira ou tipos concretos do backend | PlaybackApplication/ports podem trocar a implementação. |
| intervalo de 50 ms do worker de transição | O contrato é “avanço não depende da UI”, não a frequência do worker. |
| número/tipo de Tokio tasks criadas por `open` | Detalhe de orquestração. |
| ordem exata de chamadas internas em `open` | Importa o estado final válido, salvo dependência funcional comprovada. |
| texto exato de `CoreError.message` | Mensagem é diagnóstica; a variante é o contrato. |
| paths de módulos como `database::operations` | São superfície legada já identificada para possível redução. |
| existência futura de um método único `play_playlist` | Hoje é fluxo composto; a arquitetura futura pode internalizá-lo. |
| representação concreta do cache remoto | O contrato é cache/offline/failure behavior, não suas tabelas. |
| content hash MD5 usado no nome do artwork | Deduplicação pode ser reimplementada sem preservar algoritmo/nome. |
| estruturas privadas de history/queue | O que importa é a semântica observável de Previous e histórico persistente. |

---

# Como transformar invariantes em testes

Um teste de baseline deve preferir a forma:

```text
Arrange:
    estado observável relevante

Act:
    caso de uso público ou fronteira mínima necessária

Assert:
    resultado
    + estado persistido
    + efeitos proibidos
    + variante de erro quando aplicável
```

Exemplo para cancelamento:

```text
Arrange:
    biblioteca contém track A
    arquivo A é removido do filesystem
    scan é iniciado e cancelado antes de completar descoberta

Act:
    aguardar conclusão cooperativa do scan

Assert:
    resultado registra cancelamento
    track A continua no banco
    reconciliation não remove A
```

Exemplo para artwork:

```text
Arrange:
    covers_dir contém symlink para arquivo fora do diretório

Act:
    artwork_bytes(path_do_symlink)

Assert:
    CoreError::InvalidInput
    conteúdo externo não é retornado
```

Exemplo para erros:

```text
Act:
    track(-1)

Assert:
    CoreError::InvalidInput { .. }

Não assert:
    texto exato da mensagem
```

---

# Invariantes que devem entrar primeiro na baseline

Seguindo a F0.04, a primeira onda de testes deve concentrar-se nestes contratos:

1. **Lifecycle:** INV-CORE-001–004.
2. **Scan:** INV-SCAN-001, 003, 004, 006, 007.
3. **Library:** INV-LIB-001–003.
4. **Playback/queue:** INV-PLAY-001–009.
5. **Errors:** INV-ERR-001–003.
6. **Session/history separation:** INV-HIST-002.
7. **Artwork boundary:** INV-ART-001–003.

Depois entram metadata editing, playlists, enrichment, Last.fm, settings e secure storage conforme a ordem P1/P2 da F0.04.

---

# Critério de conclusão da F0.05

A F0.05 é considerada concluída quando:

- [x] regras explícitas do README foram transformadas em invariantes testáveis;
- [x] scan completo e scan cancelado possuem invariantes diferentes;
- [x] symlink e boundary de `covers_dir` estão protegidos conceitualmente;
- [x] queue navigation history foi separada do playback history persistente;
- [x] avanço gapless/automático não depende de polling da UI;
- [x] categorias públicas de erro foram separadas do texto diagnóstico;
- [x] metadata edit possui invariantes de atomicidade, preservação e undo;
- [x] enrichment possui invariantes de offline/no-network/cache;
- [x] Last.fm possui invariantes de timing e elegibilidade de scrobble;
- [x] settings e secure storage possuem regras persistentes relevantes registradas;
- [x] detalhes puramente implementacionais foram explicitamente excluídos da baseline arquitetural;
- [x] invariantes estão ligados aos IDs de casos de uso existentes;
- [x] nenhuma alteração de código de produção é necessária para concluir esta etapa.

A etapa seguinte pode usar estes IDs diretamente na matriz caso de uso → criticidade → invariantes → testes.
