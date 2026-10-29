# Provas das APIs de coleções — prioridade 3

> Direção atualizada em 29/10/2026: o usuário decidiu não fornecer chaves. Este
> protocolo permanece opcional para os leitores autenticados existentes. O próximo
> incremento está no [roteiro de adaptadores sem chaves e mídia visual](../roteiro-adaptadores-sem-chaves-e-midia-visual.md).

Preparação implementada em 29/10/2026. A prova real continua **pendente**: o
usuário confirmou que ainda não possui token OAuth SoundCloud nem chave YouTube
Data API. Nenhuma consulta autenticada foi executada ou substituída pelo sucesso
dos players. As flags dos leitores continuam opt-in.

## Entrega

O exemplo `service_collection_probe` utiliza a fachada pública e os adaptadores
de produção, com uma biblioteca criada exclusivamente para a prova. Cada fase
é um processo distinto. O executor recusa uma pasta existente na captura inicial
e exige o marcador da mesma seleção para reabrir. Não abre a biblioteca pessoal,
reproduz áudio, baixa mídia ou modifica contas remotas.

Os quatro alvos fornecidos pelo usuário estão em
[`service-collection-targets.json`](../../tools/provider-probes/fixtures/service-collection-targets.json).
Os parâmetros de compartilhamento foram removidos. O link YouTube com `list`
é tratado como playlist; o vídeo individual usa o outro link informado. Não há
afirmação de disponibilidade, quantidade ou conteúdo desses alvos antes da consulta.

- `capture`: consulta o item individual e a primeira página da coleção. Cancela
  a captura entre páginas, preserva os metadados e verifica a biblioteca vazia.
- `resume`: reabre a captura, compara as ocorrências com o checkpoint e retoma
  até três páginas. Confere ordem e ausência de importação implícita. Informa
  separadamente se houve paginação, item indisponível e coleção incompleta.
- `import`: exige uma retomada aprovada e posições explicitamente revisadas.
  Confirma apenas essas ocorrências na biblioteca isolada e marca favoritos.
- `verify`: reabre os recibos e repete a confirmação. Confere faixas, fontes,
  ordem/conteúdo da playlist e favoritos sem duplicação ou alteração.
- `cleanup`: remove a credencial apenas do serviço protegido exclusivo da prova,
  sem efetuar consultas remotas. Útil após interrupção do processo.

O processamento normal tenta remover a credencial isolada mesmo após falhas de
configuração, consulta ou verificação. Uma interrupção forçada pode impedir essa
limpeza; por isso o marcador e a fase explícita são preservados. Os resultados
informam se a remoção foi confirmada. Não há credenciais nos argumentos, alvos,
relatórios ou mensagens de erro. A pasta privada mantém somente metadados,
checkpoints, configuração e resultados locais; não deve ser compartilhada inteira.

## Execução autorizada quando houver credenciais

Disponibilize `SOUNDCLOUD_ACCESS_TOKEN` ou `YOUTUBE_API_KEY` no ambiente do processo
por um mecanismo seguro. Não inclua os valores no JSON, no histórico de comandos
ou no chat. O executor não cria contas, aplicativos ou credenciais. O token
SoundCloud deve estar autorizado; sua obtenção/renovação não faz parte do executor.

```sh
cargo build --locked --manifest-path durvald-core/Cargo.toml --example service_collection_probe
mkdir -p tools/provider-probes/.state/collections
```

Para SoundCloud, substitua `youtube` por `soundcloud` e escolha outra pasta nova.
Execute cada comando separadamente, interrompendo a sequência se o resultado
não for `passed`:

```sh
durvald-core/target/debug/examples/service_collection_probe \
  tools/provider-probes/fixtures/service-collection-targets.json youtube capture \
  "$PWD/tools/provider-probes/.state/collections/youtube-proof-01"

durvald-core/target/debug/examples/service_collection_probe \
  tools/provider-probes/fixtures/service-collection-targets.json youtube resume \
  "$PWD/tools/provider-probes/.state/collections/youtube-proof-01"
```

Revise `review.json`: `position` começa em zero. Escolha uma posição importável,
confira título/versão/crédito e passe-a como último argumento de `import`.
A posição `0` abaixo é apenas exemplo, não seleção automática:

```sh
durvald-core/target/debug/examples/service_collection_probe \
  tools/provider-probes/fixtures/service-collection-targets.json youtube import \
  "$PWD/tools/provider-probes/.state/collections/youtube-proof-01" 0

durvald-core/target/debug/examples/service_collection_probe \
  tools/provider-probes/fixtures/service-collection-targets.json youtube verify \
  "$PWD/tools/provider-probes/.state/collections/youtube-proof-01"
```

Para limpeza, use os mesmos argumentos com a fase `cleanup`; ela dispensa a
variável de credencial. Guarde os resultados de cada fase e registre separadamente
as limitações observadas. `passed` em uma fase não encerra toda a prioridade 3.
Sem credencial, a saída é `blocked`, sem abrir a biblioteca nem tentar a rede.

## Diagnóstico e validação offline

O leitor YouTube agora reconhece motivos estruturados de chave inválida/expirada
e cota esgotada, inclusive `google.rpc.ErrorInfo` do domínio `googleapis.com`.
HTTP 403 por cota vira `RateLimited`; chave inválida pode virar `Authentication`
mesmo em HTTP 400. Mensagens livres não determinam a classificação e não são
persistidas. Restrições de conteúdo mantêm `Restricted`; motivos desconhecidos
preservam o tratamento HTTP anterior. Não há repetição automática consumindo cota.

Os testes controlados percorrem falha após a primeira página, preservação dos
itens/cursores e nova tentativa bem-sucedida. Cobrem também mensagem enganosa e
detalhe sem tipo/domínio confiável. A suíte existente cobre indisponibilidade,
cancelamento, repetição de ocorrências e preservação de edições pessoais. O
executor tem verificações próprias de isolamento e pré-condições da CLI.

```sh
cargo test --locked --manifest-path durvald-core/Cargo.toml --example service_collection_probe
python3 -m unittest discover -s tools/provider-probes/tests -p test_service_collection_probe.py -v
```

Verificação em 29/10/2026: 544 testes Rust com todos os recursos passaram,
quatro provas externas foram ignoradas; dois testes da CLI e quatro testes de
apresentação macOS passaram. Clippy com avisos recusados e smoke UniFFI passaram.
A biblioteca release, a cópia incorporada e a cópia do app testado têm o mesmo
SHA-256. Os pré-testes dos dois serviços retornaram `blocked` sem credenciais,
sem abrir biblioteca ou tentar a rede.

Recibo com hashes e limites:
[`service-collection-api-readiness-2026-10-29.json`](../evidence/provider-probes/service-collection-api-readiness-2026-10-29.json).

## Critério de encerramento

Ainda é preciso observar, por provedor: faixa e coleção reais, mais de uma página,
item indisponível, falha de credencial, cancelamento/retomada e reimportação
idempotente. O limite de páginas pode produzir uma prova parcial; uma coleção
curta não comprova paginação, e uma coleção sem itens removidos não comprova
indisponibilidade real. Cancelamento entre páginas não comprova cancelamento de
uma requisição em voo. Esses resultados ficam explícitos, sem fabricar casos.

Referências: [SoundCloud OAuth](https://developers.soundcloud.com/docs/api/guide),
[erros YouTube](https://developers.google.com/youtube/data/reference/rest/v3/errors),
[motivos estruturados Google](https://github.com/googleapis/googleapis/blob/master/google/api/error_reason.proto),
[erros comuns Google](https://developers.google.com/digital-asset-links/v1/errors/core_errors).
