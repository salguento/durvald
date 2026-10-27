# Integrações musicais: identidade e fronteiras

Data: 27/10/2026. Etapa 1 do [roteiro unificado](../roteiro-integracoes-musicais.md).

## Decisão e escopo

Os contratos novos ficam internos ao Rust em `domain/music` e os ports de leitura
em `application/music_catalog.rs`. Nesta etapa não há migração SQLite, registro
de plugins, consulta externa, novo comando público ou alteração do player.

`CatalogTrack`, `Track`, `songs.song_id`, `file_path`, fila local e sessões atuais
continuam com seu comportamento existente. Os contratos novos serão conectados
progressivamente nas etapas seguintes. O `allow(dead_code)` está limitado aos
dois módulos de contratos ainda sem consumidores; retirar conforme forem usados.

## Identidade

| Referência | Regra |
| --- | --- |
| Local | Reutiliza `ArtistId`, `ReleaseId` e `TrackId`; não converter IDs de provedores em IDs locais. |
| Externa | `ExternalEntityRef` identifica `(ProviderId, ExternalEntityKind, external_id)`. Igualdade inclui os três valores. |
| Provedor | Namespace estável em minúsculas, de até 128 bytes, começando por letra ou dígito; demais caracteres podem incluir `.`, `_` e `-`. |
| ID externo | Opaco, não vazio, sem espaços nas extremidades nem caracteres de controle; preserva caixa. Normalização específica é responsabilidade do adaptador. |
| Origem remota | `RemoteMediaRef` exige item individual de áudio ou vídeo e URL de página canônica. Catálogo e disponibilidade continuam conceitos distintos. |
| Chave de propriedade da origem | `RemoteSourceKey` usa `(provider, external_id)`, independentemente da página ou classificação; será a chave da consulta de vínculo existente e da restrição de unicidade. |
| Caminho local | `LocalMediaPath` exige caminho absoluto, sem NUL; não consulta disco, não normaliza caixa nem resolve symlinks. Scanner/repositório aplicarão as regras do filesystem. |

Artista, agrupamento de lançamento, edição, gravação, ocorrência na edição e
perfil de serviço são entidades distintas. O ID de um recording não basta para
identificar a ocorrência de uma faixa no álbum local. O tipo local `ReleaseId`
mantém sua semântica existente; não ganha equivalência automática a release group
ou edição externa. Perfis, playlists, ofertas de download e vídeos de álbum
inteiro não são aceitos como origem de uma faixa individual.

A URL canônica aceita HTTP(S), com host e sem credenciais de usuário embutidas.
O adaptador deve validar o domínio e retirar tokens/assinaturas antes de fornecê-la;
o parser genérico não sabe reconhecer todos os parâmetros de autenticação.
URL é endereço de página, não chave de identidade. Redirecionamentos e autorização
de requisições serão tratados na infraestrutura da integração.

## Resultados, biblioteca e associação

- `CatalogEntitySummary`, `CatalogSearchPage`, `CatalogEntityDetails` e
  `SourceCandidate` são resultados de leitura/cache. Não têm efeito de importação.
- `CatalogEntityRef` distingue entidade local e externa. Uma relação entre elas
  só é persistida por uma ação de materialização/associação, fora dos ports de leitura.
- `LibraryMembership` distingue registro durável de adesão à biblioteca.
  `CatalogTrackIdentity` permite manter o mesmo `TrackId` ao adotar um registro
  mínimo antes usado somente para histórico. Não cria essa persistência nesta etapa.
- `assess_association` recebe alvo, proprietário atual da origem e evidência.
  O chamador consulta o proprietário pela chave estável, nunca por título ou URL.
- Mesma faixa proprietária retorna `AlreadyAttached`; outra faixa retorna
  `Conflict`, inclusive quando o usuário confirmou. Não há transferência nem merge
  implícito. A futura escrita deverá verificar unicidade em transação para evitar corrida.
- Sem proprietário, similaridade de metadados retorna `NeedsReview`.
  Somente confirmação explícita ou identidade e contexto de gravação/edição já
  verificados permitem `Attach`. Uma coincidência textual não é evidência verificada.
- Anexar várias origens preserva favoritos, avaliações, tags, histórico, Replay
  e vínculos da faixa. Alterar origem não cria novo álbum nem sobrescreve metadados.

## Ports e capacidades

| Port | Entrada e resultado | Fronteira |
| --- | --- | --- |
| `CatalogReader::search` | `CatalogSearchRequest` → `CatalogSearchPage` | Busca por escopo/filtro; uma página de um adaptador. |
| `CatalogReader::details` | `CatalogEntityRef` → `CatalogEntityDetails` | Detalhes básicos/completos e entidades relacionadas, sem adoção. |
| `SourceFinder::find_sources` | `SourceSearchRequest` → candidatos | Procura opções para um alvo escolhido, sem resolver ou baixar mídia. |
| `MediaResolver::resolve` | `SourceReference` → `ResolvedMedia` | Resolve perto da reprodução, sem persistir a URL resultante. |

Os ports são object-safe, `Send + Sync`, com futures `Send`; um futuro registro
pode manter implementações heterogêneas. Não existe dependência de SQLite, cliente
HTTP, DTO público ou Swift no domínio novo. Parse de URL usa a biblioteca `url`,
já presente transitivamente no projeto e agora declarada como dependência direta.

A busca valida texto não vazio, sem controles, limite de 1–200 itens e cursor
opaco não vazio/sem controles. O adaptador pode impor limite menor. O runtime
deverá vincular cursor a provedor/consulta, cuidar de geração, cancelamento,
rate limit e publicação parcial; esses mecanismos pertencem à etapa 2.

`SourceAvailability` explicita desconhecido, disponível, prévia, autenticação,
restrição regional, indisponível e falha temporária. O endereço de uma página
não implica capacidade de reprodução.

`PlaybackCapability` declara modo (`NativeAudio`, `EmbeddedPlayer`, `ExternalOpen`),
seek, duração conhecida, preload e eventos observáveis de progresso/fim. Capacidades
são por item/modo; não presumir suporte global a partir do nome do serviço.
Abrir externamente não autoriza inventar eventos de progresso ou conclusão.

`IntegrationError` separa entrada inválida, capacidade não suportada, desativação,
autenticação, acesso negado, região, ausência, rate limit com `retry_after`,
indisponibilidade temporária, mídia expirada, timeout, cancelamento e resposta
inválida. A política de retry fica na aplicação/runtime; mensagens externas não
decidem repetição automática nem são expostas como diagnósticos contendo segredos.

Download não usa `MediaResolver`: pesquisa de ofertas e transferências terão ports
próprios nas etapas correspondentes. Cache temporário e arquivo permanente da
biblioteca continuam separados.

## Origem persistente e mídia resolvida

`SourceReference` guarda caminho local ou referência remota estável.
`ResolvedMedia` guarda localização executável, headers e expiração em memória.
Ambos são tipos distintos. Os tipos novos não implementam serialização; o `Debug`
de mídia resolvida oculta localização, headers e referência de origem.

Na restauração futura, sessão guarda referências estáveis e resolve novamente.
Não persistir headers, URLs assinadas ou cookies em sessão, banco de catálogo,
cache de consulta ou logs. A validade real e a renovação limitada serão tratadas
ao conectar os adaptadores; esta etapa não faz transporte nem buffering.

## Ouvir sem salvar e identidade da fila

`MusicQueueEntry` contém três conceitos separados:

1. `QueueOccurrenceRef`: ID de sessão e sequência atribuída na inserção. O dono da
   sessão gera ID próprio e não reutiliza sequências; reordenar não muda a identidade.
2. `QueueTarget`: registro local durável, com adesão explícita, ou referência remota
   estável. Uma referência externa não exige arquivo ou linha em `songs`.
3. `source_context`: contexto de navegação/coleção, separado do provedor de mídia.

Uma faixa repetida tem alvos iguais e ocorrências diferentes. Outra sessão tem
identidade diferente mesmo ao ouvir o mesmo alvo. Resolver/bufferizar/repetir uma
tentativa não aloca outra ocorrência nem registra um play adicional.

O histórico atual usa `TrackId`. Antes de habilitar escuta externa com histórico,
a etapa de persistência deve criar/reusar registro mínimo durável e sua relação
externa, mantendo `NotInLibrary` e filtrando consultas da biblioteca por adesão.
Somente salvar/adotar altera esse estado para `InLibrary`; o histórico não faz
essa alteração. Não reutilizar o caminho obrigatório atual com URL ou string vazia.
Até essa migração, o novo contrato de fila não é conectado ao player público.

## Compatibilidade e evolução de DTOs/UniFFI

- Esta entrega não altera `api.rs`, `durvald.udl`, exports, schema SQLite,
  `PlaybackSessionState` ou representação persistida de contextos v1/v2.
  Swift e GTK continuam consumindo os contratos existentes; não regenerar bindings
  sem mudança efetiva da API.
- Os contratos desta etapa são internos, sem formato de serialização publicado.
  São a primeira revisão de projeto, não uma promessa de ABI de plugin v1.
- A etapa 2 deve versionar o manifesto/handshake do registro. Futuro cache ou
  envelope persistido terá versão própria; não serializar diretamente esses tipos
  e presumir compatibilidade eterna.
- Ao publicar comandos/DTOs de catálogo, adicionar novos tipos em vez de mudar
  silenciosamente o significado de `Track.file_path`, `SearchResults` ou IDs atuais.
  Adaptar explicitamente do domínio, atualizar UDL quando aplicável, gerar bindings
  e compilar consumidores macOS/GTK na mesma entrega.
- Campo/variante ou assinatura incompatível exige versão negociada ou erro
  explícito de incompatibilidade. Versão futura desconhecida não deve ser
  interpretada como local, disponível ou vazia.
- A futura migração que remover arquivo obrigatório terá versão e backup próprios;
  não declarar builds antigos compatíveis com o banco migrado.

## Validação

Testes unitários do domínio cobrem identidade por provedor/tipo, caixa de IDs,
entrada inválida, distinção entre catálogo e mídia, chave estável de origem,
conflitos/idempotência de associação, limites de busca, ocorrências repetidas,
sessões distintas, adesão independente de ID durável e ocultação de URLs/headers.
O teste de arquitetura impede dependências de armazenamento, transporte e DTOs
públicos nos contratos novos. Resultados executados são registrados no roteiro.

Validação executada em 27/10/2026:

- Dez testes novos de domínio passaram; a rodada unitária total teve 288 sucessos,
  duas falhas existentes e três ignorados. Com as duas falhas excluídas, todos os
  demais unitários passaram.
- As oito suítes de integração somaram 112 sucessos, incluindo 48 testes de
  reprodução, 32 de biblioteca, contratos públicos e a nova verificação de domínio.
  A verificação antiga de fronteiras da aplicação foi excluída dessa rodada.
- As três falhas foram reproduzidas numa extração isolada de `HEAD`, sem os arquivos
  desta implementação: `database::migrations::tests::legacy_rows_survive_migration_and_reopening`,
  `database::enrichment::tests::similar_artist_snapshot_materializes_targets_and_their_identities_atomically`
  e `application_layer_does_not_reference_database_internals`.
- `cargo check --locked --offline --features uniffi` passou após disponibilizar as
  dependências necessárias. Não houve alteração de bindings ou contrato público.
- Formatação dos arquivos novos/alterados de Rust e `git diff --check` passaram.
  A checagem global de formatação aponta diferenças existentes em `library_repair.rs`,
  `metadata_edit.rs` e `tests/library.rs`.
- Clippy com `--all-targets --features test-support -- -D warnings` permanece
  bloqueado por diagnósticos em arquivos existentes: método de teste não utilizado
  em `audio/player.rs`, closure redundante em `application/enrichment.rs`, clamps
  em `database/recommendations.rs`, complexidade de tipo em `library_repair.rs` e
  itens após módulo de teste em `database/classification.rs`. Não houve diagnóstico
  nos contratos novos. Essas correções ficam fora desta etapa.

Comandos principais, executados em `durvald-core`:

```sh
cargo test --locked --offline --lib domain::music
cargo test --locked --offline --features test-support
cargo test --locked --offline --features test-support --test architecture_boundaries --test core_lifecycle --test fixture_infrastructure --test library --test playback --test public_api --test ratings --test settings --no-fail-fast -- --skip application_layer_does_not_reference_database_internals
cargo check --locked --offline --features uniffi
cargo clippy --locked --offline --all-targets --features test-support -- -D warnings
```

A rodada completa expõe as falhas existentes acima; o roteiro não afirma que a
suíte global ou Clippy estejam sem pendências. Nenhuma consulta de provedor foi
necessária para validar esta etapa.

Atualização de 27/10/2026: a expectativa de contagem de migrações foi corrigida
de 18 para 19; `legacy_rows_survive_migration_and_reopening` passou em execução
isolada. As outras duas falhas registradas acima continuam pendentes.

A [investigação da identidade de artistas](artist-identity-investigation.md)
identificou a causa da falha de imagem: geração fixa desatualizada no teste.
Também confirmou um defeito separado no recálculo da identidade descoberta;
os dois ajustes foram aplicados em 27/10/2026, com seis testes novos de regressão.
O registro de validação da etapa 1 acima permanece como histórico da rodada original.
Após essas correções, a regressão passou em 408 testes, com apenas a verificação
antiga de fronteiras da aplicação excluída e três testes existentes ignorados.
A compilação com UniFFI também passou; as pendências globais de Clippy permanecem.

A [correção da fronteira de aplicação](application-boundary-investigation.md)
foi concluída posteriormente em 27/10/2026. A rodada completa passou em 414 testes,
sem excluir o teste de arquitetura; os três testes previamente ignorados foram
mantidos. Os registros de exclusões acima descrevem apenas as rodadas anteriores.

As pendências de Clippy também foram corrigidas em 27/10/2026. A verificação do
core com `--all-targets --all-features -- -D warnings` passou sem diagnósticos.
