# Investigação: fronteira entre aplicação e persistência

Data: 27/10/2026. Escopo: falha de
`application_layer_does_not_reference_database_internals`.
Status: investigação concluída e correção aplicada em 27/10/2026.
O diagnóstico abaixo descreve o estado anterior; a implementação e a validação
estão registradas no final.

## Conclusão

A falha é procedente: funcionalidades posteriores à refatoração voltaram a expor
detalhes de persistência na aplicação. Há também sinais de dependência em fixtures
de teste e regras puras colocadas no namespace de banco. Portanto, os sete itens
do diagnóstico não representam sete pontos de SQL direto em produção.

O teste foi executado isoladamente e reproduziu os mesmos sete apontamentos:
um em biblioteca, um em enriquecimento e cinco em playlists. Os apontamentos
são por arquivo/padrão encontrado, não por chamada ou função.

## Regra aplicável

O [roteiro de arquitetura](../../durvald-core/docs/arquitetura/roteiro-implementacao-direto.md)
permite dependências concretas nas primeiras extrações, mas o Marco 6 exige
retirar detalhes de row/SQL da aplicação nas áreas migradas. O Marco 7 prevê
fachada fina, composição centralizada e adapters com fronteiras pequenas.

O [checkpoint de setembro](../../durvald-core/docs/estado-refatoracao-arquitetura-core.md)
registra essa separação como concluída, incluindo a remoção de um executor
genérico de banco da biblioteca. Esse é um registro histórico: funcionalidades
posteriores reintroduziram o acoplamento. Não há necessidade de transformar todo
adapter em trait ou dividir a crate para cumprir a regra.

## Achados

| Local | Evidência | Classificação |
| --- | --- | --- |
| `application/library.rs:515` | `personal_library_operation` recebe closure tipada com `&rusqlite::Connection` e encaminha ao repositório. | Vazamento real da tecnologia de persistência pela fronteira da aplicação. O método não contém SQL próprio. |
| `application/enrichment.rs:142`, `:158`, `:197`, `:212` | Chama `database::artist_news::{clear_provider, followed, current, finish}` por meio desse executor genérico. | Acoplamento real a operações do banco; deveria chamar capacidades nomeadas de um adapter. |
| `application/playlist.rs:29`, `:43`, `:75`, `:102`, `:325` | Usa montagem/validação de definições e política de Replay no namespace `database`. | Dependência de módulo indevida, mas as funções chamadas são puras: não recebem conexão nem executam SQL. |
| `application/playlist.rs:347` em diante | Módulo `#[cfg(test)] replay_tests` cria banco em memória, pool e fixtures SQL. | Preparação de teste, não acesso de produção. A verificação textual não faz essa distinção. |
| `core.rs`, 35 chamadas | A fachada monta closures que chamam módulos de banco e as envia ao executor da biblioteca. | Extensão do mesmo problema, fora do diretório analisado pelo teste atual. |

### Executor genérico

O caminho real é:

```text
core / EnrichmentApplication
  → LibraryApplication::personal_library_operation(closure)
    → SqliteCatalogPreferencesRepository::personal_library_operation(closure)
      → spawn_blocking → pool.get() → closure(&Connection)
```

O acesso efetivo usa `spawn_blocking` dentro da infraestrutura. Esta investigação
não encontrou evidência de que essas chamadas executem SQL diretamente na thread
da interface. O problema confirmado é que chamadores acima do adapter precisam
conhecer conexão e funções do banco, contornando operações de aplicação nomeadas.

Distribuição das 35 chamadas da fachada:

| Capacidade | Chamadas |
| --- | --- |
| Recomendações | 5 |
| Novidades/seguir artistas | 5 |
| Coleções de álbuns | 8 |
| Classificação musical | 6 |
| Listen List | 5 |
| Tags pessoais | 6 |

Esse inventário é estático; não é medição de frequência de execução. Mover o
executor da biblioteca para a fachada apenas esconderia parte da violação do teste.

### Regras puras nas playlists

`retrospective_playlists::{definition, policy, config}` trabalha com configuração,
datas e definições, sem conexão. A validação de smart playlists em
`database::operations::validate_smart_playlist_definition` também não executa SQL.
Essas regras devem ser compartilhadas por aplicação e persistência a partir do
domínio, preservando o formato JSON, limites, mensagens e política existentes.
Consultas de Replay já passam por `SqlitePlaylistRepository` e devem continuar ali.

## Limitações da verificação atual

`tests/architecture_boundaries.rs` lê somente os arquivos `.rs` diretamente em
`src/application` e procura substrings. Não interpreta AST ou `cfg`, considera
comentários/strings e não cobre subdiretórios, dependências transitivas ou `core.rs`.

Assim, acusa a infraestrutura de fixtures sob `#[cfg(test)]` e não identifica os
35 consumidores da fachada. Mesmo retirando as fixtures do diagnóstico, permanecem
violações reais nos três módulos de produção. Não basta ignorar o teste ou liberar
`rusqlite` globalmente.

## Origem identificada no histórico

`git blame` aponta que os trechos precedem o trabalho desta conversa:

- `abd23085`, 29/09/2026: validação de smart playlists chamando `database::operations`.
- `1db36b82`, 16/10/2026: regras de Replay e fixtures de banco no módulo de aplicação.
- `ebf1b0a3`, 22/10/2026: executor genérico reintroduzido para funcionalidades pessoais.
- `76798087`, 26/10/2026: novidades de artistas usando o executor em enriquecimento.

## Correção recomendada em incrementos

1. Extrair regras puras de Replay e smart playlists para o domínio, mantendo
   adapters SQLite consumidores das mesmas regras. Preservar testes e comportamento.
2. Mover a preparação SQLite do teste de Replay para a infraestrutura de testes
   (`tests/common`/`test_support`) ou promover o cenário para integração pela API
   pública. Não remover sua cobertura para satisfazer o guard.
3. Criar operações nomeadas de persistência de novidades: artistas seguidos,
   validade da atualização, publicação do resultado e limpeza por provedor.
   Injetar o adapter pela composição e retirar as quatro closures do enriquecimento.
4. Migrar os consumidores da fachada por capacidade para serviços de aplicação
   e adapters nomeados. Depois retirar `LibraryApplication::personal_library_operation`.
   Não deixar um novo executor equivalente na fachada como solução final.
5. Melhorar o guard para distinguir fixtures de produção e cobrir submódulos e
   a delegação da fachada, mantendo a proibição de detalhes de conexão na aplicação.

Cada fatia deve manter assinaturas públicas, schema, ordenação, filtros e regras
de negócio. Validar Replay, smart playlists, seguir/deixar de seguir, resultados
obsoletos, limpeza de provedor e as demais capacidades à medida que forem migradas;
executar o teste de arquitetura sem exclusão ao concluir a retirada do executor.

A investigação inicial reproduziu a falha e inspecionou código, contratos e
histórico sem alterar a implementação. A correção foi executada posteriormente,
conforme o pedido do usuário.

## Correção aplicada

- As 35 operações da fachada passaram a delegar a métodos nomeados em
  `LibraryApplication`, sem closures com conexões ou chamadas ao módulo de banco.
- `SqlitePersonalLibraryRepository`, construído na composição, encapsula as
  capacidades de recomendações, novidades, coleções, classificação, Listen List
  e tags. Seus métodos são nomeados; o executor de conexão é privado ao adapter.
- `personal_library_operation` foi removido da aplicação e do antigo repositório
  de preferências. O nome e a capacidade genérica não permanecem na fachada.
- Enriquecimento usa métodos nomeados para listar artistas seguidos, verificar
  validade de refresh, finalizar sua publicação e limpar dados do provedor.
  Os tokens de follow/identidade, cooldown e rejeição de resultados obsoletos
  foram preservados.
- Configuração e política de Replay foram movidas para `domain/replay.rs`;
  validação de playlists inteligentes foi movida para `domain/smart_playlist.rs`.
  Aplicação e persistência consomem a mesma implementação. Os módulos antigos
  reexportam as funções onde necessário para preservar consumidores internos.
- A fixture SQLite do teste de Replay foi movida para `test_fixtures.rs`, que
  entrega adapters prontos, sem expor conexão ou pool à aplicação. O cenário de
  preview, save, reabertura, atualização e deduplicação foi mantido.
- O guard passou a verificar subdiretórios da aplicação e ganhou proteção
  específica da fachada e das regras puras de playlists. O guard original não
  foi relaxado para permitir dependências de banco na aplicação.

Não houve mudança de schema, contrato público, serialização ou regras de negócio.
As assinaturas públicas da fachada foram comparadas com `HEAD` e permaneceram
iguais. O trabalho manteve os adapters concretos usados pelo projeto.

## Validação da correção

- `cargo test --locked --offline --features test-support --no-fail-fast`:
  **414 testes passaram, sem exclusões e sem falhas**; os três testes já ignorados
  permaneceram assim. Inclui os cinco guards arquiteturais e os 48 de reprodução.
- Novos testes pela API pública verificam persistência de dispensas/métricas de
  recomendações e preferências de follow após limpeza de provedor e reinício.
- Novo teste do adapter verifica publicação de cooldown e rejeição de um refresh
  antigo após deixar de seguir/seguir novamente.
- `cargo check --locked --offline --features uniffi`: passou.
- Formatação dos arquivos alterados e `git diff --check`: passaram.
- Clippy global ainda aponta os problemas existentes em `audio/player.rs`,
  `database/recommendations.rs`, `library_repair.rs` e
  `database/classification.rs`; sem novos diagnósticos nos métodos desta extração.
  O apontamento anterior de closure redundante no enriquecimento deixou de ocorrer.

Esses comandos foram executados em `durvald-core`. Não foram executados builds
completos dos clientes Swift/GTK nesta correção; a API pública permaneceu inalterada
e o core foi verificado com UniFFI.

## Pendências de Clippy corrigidas em 27/10/2026

Os apontamentos restantes registrados acima foram corrigidos posteriormente:

- `set_mock_output_devices` é compilado apenas com `cfg(test)`, pois seus únicos
  consumidores são testes unitários, sem suprimir o aviso de código não utilizado.
- Os limites dos pesos de recomendação usam `clamp(0.0, 4.0)`.
- O reparo de faixas ausentes usa `MissingTrackPreferences`, com campos nomeados,
  no lugar da tupla de seis campos, preservando o mapeamento dos valores no SQL.
- As funções de classificação foram colocadas antes do módulo de testes,
  mantendo implementação e cobertura existentes.

`cargo clippy --locked --offline --all-targets --all-features -- -D warnings`
passou sem diagnósticos. A formatação dos quatro arquivos alterados e
`git diff --check` também passaram. Não foram acrescentados atributos para
silenciar os lints.

`cargo test --locked --offline --all-features --no-fail-fast` também passou:
414 testes aprovados, nenhuma falha e os três testes previamente ignorados
mantidos. A rodada inclui UniFFI, guards de arquitetura, recomendações, reparo
da biblioteca e troca de dispositivos de áudio.
