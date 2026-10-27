# Investigação: geração de identidade de artistas descobertos

Data: 27/10/2026. Escopo: determinar a causa da falha de
`similar_artist_snapshot_materializes_targets_and_their_identities_atomically`.

## Conclusão

A falha original exige ajuste no teste: ele fornece geração `0` ao salvar a
imagem de um artista cuja identidade já foi resolvida na geração `1`.
A criação não deve ser alterada para manter artificialmente a geração em zero,
e a proteção de `store_asset` contra resultados obsoletos deve ser preservada.

A investigação também confirmou um defeito independente no recálculo de identidade:
`database::identity::read_inner` ignora a identidade registrada pela descoberta
remota quando não há tags locais nem confirmação manual. Com isso, uma leitura
que recalcula o estado perde o MBID materializado e incrementa a geração novamente.

## Caminho da falha original

1. O schema inicializa `artist_enrichment_state` com geração `0` e status `unresolved`.
2. `store_similar_artists` chama `upsert_discovered_artist_inner` na mesma transação
   da publicação de similaridades.
3. Ao receber MBID, o upsert registra as chaves externas e altera o estado para
   `resolved`. O SQL incrementa a geração quando o status ou MBID muda: `0 → 1`.
4. Repetir o mesmo upsert mantém o ID e a geração; não cria outra entidade.
5. O teste monta `AssetSnapshot` com `identity_generation: 0`, sem consultar o
   estado do artista-alvo. A geração do artista de origem (`3`) também não é a do alvo.
6. `store_asset` encontra geração `1` e retorna `false` para o snapshot de geração
   `0`, conforme seu contrato de rejeitar resultados de identidades antigas.

Referências no código:

- `durvald-core/src/database/enrichment.rs`: `upsert_discovered_artist_inner`,
  `store_similar_artists`, `store_asset` e o teste citado.
- `durvald-core/src/database/migrations.rs`: schema `FOUNDATION`.

## Experimentos executados

Usada uma extração isolada de `HEAD` em diretório temporário, com testes de
diagnóstico; nenhum código de produção ou teste da árvore de trabalho foi alterado.
As execuções usaram dependências locais e não consultaram serviços externos.

| Experimento | Resultado observado |
| --- | --- |
| Criar artista provisório sem MBID | `unresolved`, geração `0`. |
| Associar MBID ao mesmo artista | Mesmo ID, `resolved`, geração `1`. |
| Repetir o upsert com o mesmo MBID | Mesmo ID e geração `1`. |
| Salvar imagem com geração `0` | Rejeitada (`false`). |
| Salvar imagem com geração persistida `1` | Aceita (`true`). |
| Teste original usando a geração persistida do alvo | Passou, inclusive as verificações posteriores de retrato e similaridades. |
| Executar `identity::read` após materialização | `unresolved`, MBID removido do estado, geração `2`. |
| Tentar publicar novamente imagem da geração `1` após esse recálculo | Rejeitada (`false`); as duas chaves externas continuam registradas. |

Dois testes direcionados passaram na cópia: o diagnóstico do ciclo de identidade
e o teste original com a alteração experimental da geração. O primeiro confirma
o comportamento defeituoso atual do recálculo; não é um teste de correção desse defeito.

## Defeito adicional no recálculo

`database::identity::read_inner` escolhe identidade a partir de conflitos,
confirmação manual e tags locais. Sem essas evidências, o fallback transforma o
status anterior `resolved` em `unresolved` e descarta o MBID. A identidade externa
já registrada por `upsert_discovered_artist_inner` não participa dessa decisão.

Esse caminho é utilizado por `EnrichmentService::artist_identity`, portanto não
é apenas uma hipótese restrita ao teste. Já `read_persisted_inner` lê o estado
sem recalculá-lo e preserva a geração materializada.

O efeito confirmado é perder o estado resolvido e rejeitar novas publicações
da geração anterior, apesar de as chaves externas continuarem existentes. Isso
pode interromper o enriquecimento e tornar caches anteriores inelegíveis.

## Ajustes recomendados

1. No teste original, obter a geração do artista-alvo por leitura do estado
   persistido (`read_persisted_inner` ou consulta SQL) antes de montar o snapshot.
   Não trocar simplesmente `0` por outro número fixo nem usar a leitura reparadora.
2. Acrescentar cobertura de criação/promoção, idempotência e rejeição de geração
   obsoleta para preservar a intenção do versionamento.
3. Corrigir separadamente a resolução para considerar a evidência persistida da
   descoberta remota, respeitando conflitos, decisões manuais e invalidação.
   Não rotular uma descoberta como confirmação manual para contornar o problema.
4. Validar que releituras e refresh não removem MBID nem incrementam geração sem
   mudança real, além de testar conflitos e promoção de artista provisório.

## Correção aplicada em 27/10/2026

O teste de publicação de similaridades agora consulta a geração persistida do
artista-alvo e verifica que recalcular a identidade não altera esse estado antes
de registrar a imagem.

`identity::read_inner` passou a considerar os MBIDs válidos registrados em
`artist_identity_keys` com origem de descoberta (`similar_artist`, `remote_search`
ou `manual`). Chaves históricas de tags locais não reativam identidade removida.
As leituras persistidas e reparadoras compartilham o cálculo de conflito de tags.

- Uma descoberta inequívoca mantém MBID e geração nas releituras.
- Um registro afetado pelo defeito anterior é recuperado a partir das chaves
  persistidas; a recuperação muda a geração uma vez e as releituras ficam estáveis.
- Conflito entre descoberta e tags, ou múltiplos MBIDs descobertos sem escolha
  manual, resulta em ambiguidade em vez de seleção arbitrária.
- Confirmação manual mantém prioridade sobre descoberta. Limpar a identidade
  continua bloqueando associação automática; conflitos com tags mantêm a regra existente.
- Descoberta não é rotulada como confirmação manual nem como tag local.
- A proteção de publicação por geração permanece em `store_asset`.

Foram acrescentados seis testes de regressão para esses comportamentos. Quatro
deles reproduziram o defeito antes da correção; depois, os dez testes de identidade
(seis novos e quatro existentes) passaram. A correção não altera schema, DTOs
públicos ou bindings.

Validação final da correção:

- `cargo test --locked --offline --features test-support --no-fail-fast -- --skip application_layer_does_not_reference_database_internals`:
  296 testes unitários e 112 de integração passaram; três testes existentes
  permaneceram ignorados. Inclui o teste original de similaridades e os 48 de reprodução.
- `cargo check --locked --offline --features uniffi`: passou.
- Formatação de `identity.rs`/`enrichment.rs` e `git diff --check`: passaram.
- Clippy global continua com os diagnósticos preexistentes documentados na
  [entrega de contratos](music-integration-contracts.md), sem apontamentos nos dois
  arquivos desta correção.

O único teste excluído foi a verificação antiga de fronteiras da aplicação,
cuja falha já foi reproduzida antes destas alterações. As falhas de contagem de
migrações e publicação da imagem de artista similar estão corrigidas.
