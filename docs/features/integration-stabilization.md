# Estabilização das integrações — etapa 15

Implementação de 28/10/2026 do [item 15](../roteiro-integracoes-musicais.md).
Esta etapa acrescenta diagnóstico local, corrige isolamento de concorrência,
protege o ciclo do helper de provas e fornece medição reproduzível em Release.
A expansão de provedores continua condicionada às evidências por capacidade.

## Diagnóstico e isolamento

Ajustes → Serviços → **Diagnóstico dos serviços** lê um snapshot em memória.
Abrir/atualizar não faz chamadas HTTP, não consulta o Keychain, não inicia helpers
e não habilita integrações. Também funciona quando as preferências dos plugins
estão corrompidas ou são de versão futura. O arquivo original é preservado.

`integration_diagnostics()` expõe, por adaptador e operação, andamento, conclusões,
sucessos, cancelamentos, falhas, último resultado e p95 de tempo total/espera.
Cada operação mantém no máximo **64 pares de tempos**, sem consultas, identidades,
URLs, tokens, cookies ou respostas. Contadores são cumulativos nesta execução;
p95 usa apenas a janela recente, incluindo falhas/cancelamentos. Não é uma
telemetria enviada a servidor. Reiniciar limpa o diagnóstico; desativar/reconfigurar
preserva os contadores; remover elimina o registro. Não há tarefa de polling.

O tempo total inclui espera por vagas, credenciais, cooldown e execução do
adaptador. O tempo de espera termina ao obter ambas as vagas; se não houve
dispatch, corresponde ao tempo total. Preparação de fonte **não mede buffering
nem término de playback do SDK**. Respostas parciais encapsuladas pelo adaptador
podem concluir a chamada com sucesso; o resultado funcional da tela prevalece.
Enriquecimento/Last.fm possuem seus próprios diagnósticos e não passam por esse
registro. Ausência de amostras não comprova funcionamento ou custo zero.

Foi corrigida a aquisição de vagas: obter primeiro a vaga do provedor evita que
pedidos enfileirados para o mesmo serviço esgotem as vagas globais antes de
executar. Limites continuam 4 operações globais, 2 por plugin, 32 admitidas,
deadline de 30 segundos incluindo espera. Cancelamento e abandono do chamador
abortam a tarefa supervisionada e contabilizam cancelamento, liberando recursos.
Biblioteca/áudio local não dependem desse agendador.

## Matriz de suporte e recuperação

| Provedor/modo | Suporte atual | Limite e recuperação |
| --- | --- | --- |
| Biblioteca/áudio nativo | Arquivos MP3/WAV/FLAC/Ogg, fila, histórico e sessão | Sem rede/helper. Arquivo ausente: reparar/selecionar outra origem. Baseline abaixo usa WAV, não comprova todos os formatos. |
| MusicBrainz | Busca/detalhe/cache; novidades de artistas seguidos | Cobertura e datas variáveis. Offline usa dados salvos. Respeitar cooldown/Retry-After; tentar novamente após o prazo. |
| SoundCloud widget | Player oficial visível de faixa individual, opt-out persistente | Rede/SDK/acesso por item. ERROR não informa causa HTTP; ausência de avanço é recuperável. Tentar novamente ou escolher outra origem. EQ/gapless nativos não se aplicam. |
| SoundCloud importação | Metadados de faixa/coleção com token OAuth, opt-in | Token ausente/expirado: substituir nos ajustes. Não é download nem prova de faixa integral. |
| YouTube | Importação pública com chave; vídeo IFrame visível, opt-in separado | Restrição regional/remoção/live/incompatibilidade são falhas por item. Renovar metadados vencidos, conferir chave/rede, tentar novamente; sem áudio isolado. |
| Bandcamp | Página pública de faixa/álbum, metadados revisados e abrir no serviço, opt-in | Layout pode mudar; falha de parser não importa dados inventados. Sem playback controlado, conta privada ou arquivos de compra. |
| Soulseek/slskd | Busca independente e transferência explícita; importação de arquivo revisada | Backend configurado pelo usuário; API acessível não garante peers. Timeout na rede do trabalho não comprova ausência. Cancelar busca/tentar em outra rede; conferir autenticação e mapeamento antes de importar. Sem compartilhamento automático. |
| Last.fm | Autenticação/scrobbling e enriquecimento opcionais | Não é pré-requisito para novidades, sugestões locais ou áudio. Revogar/reautorizar conta quando necessário. |

Novidades já encaminham ao detalhe local/externo, a Ouvir depois e ao serviço.
Sugestões locais já abrem o álbum e permitem ação na biblioteca. Não foi
introduzida nova dependência de recomendação externa. Discogs e outros catálogos
não foram adicionados: registrar primeiro casos concretos de edição/classificação
que a identificação e o catálogo atuais não resolvem, com taxa de sucesso,
latência, licença/acesso e ação útil antes de propor expansão.

## Helpers: ausência, incompatibilidade e atualização

O aplicativo não executa yt-dlp/FFmpeg nem instala um daemon. slskd é um serviço
opcional configurado pelo usuário; ausência, versão incompatível/resposta inválida,
401 e timeout ficam restritos às operações remotas. Não há atualizador automático.

O helper **isolado de provas** permite `slskd_backend.py verify`: confere offline
versão/asset/checksum fixados no código, confinamento do executável, permissão de
execução e hash do binário. Ausência, modificação ou incompatibilidade falham sem
executar/baixar substituto. `install` reaproveita apenas instalação verificada;
instalação nova compara metadados e pacote com o hash fixado, não confia somente
no hash do mesmo download. Falha de prontidão encerra o processo exato iniciado
pela chamada e remove seu registro; conta/configuração são preservadas. Não
encerra instância preexistente. O registro fica disponível se a parada falhar.

Atualizar exige alterar/revisar o pin no código e executar as provas numa pasta
isolada nova. Preservar instalação/configuração anterior para rollback; só adotar
novo pin depois de verificar pacote e contratos. Não se oferece substituição
in-place nem se declara atualização assinada/notarização validada. Verificar o
executável existente não verifica novamente todos os arquivos do runtime.

## Medições e budgets

Executor: `tools/provider-probes/measure_integrations.py`; estímulo Rust em
`durvald-core/examples/integration_baseline.rs`. Ambos usam biblioteca descartável,
5.000 registros sintéticos, renderer real e WAV PCM silencioso estéreo 44,1 kHz.
Volume zero, sem biblioteca pessoal, credenciais ou consultas externas. O custo
de preparar os registros fica fora das fases idle/playback. Não mede a UI SwiftUI.

```sh
cargo build --locked --release --manifest-path durvald-core/Cargo.toml --example integration_baseline
python3 tools/provider-probes/measure_integrations.py --report /tmp/integration-baseline.json
python3 -m unittest discover -s tools/provider-probes/tests -v
python3 tools/provider-probes/slskd_backend.py verify
```

O relatório registra hardware/OS, commit/árvore modificada, hashes, p95 de 50
leituras quentes e 20 inícios de áudio. O primeiro acesso é separado, sem alegar
cache físico frio. Preparação e observação de avanço são separadas; esta última
inclui resolução temporal da consulta de 10 ms, não mede latência acústica.
CPU usa diferença do tempo de CPU por intervalo; RAM soma RSS do processo e
filhos, podendo contar páginas compartilhadas; disco mede blocos alocados de
banco/WAL/cache/configuração, excluindo WAV. Fases de 10 segundos precisam de ao
menos cinco amostras; são baseline curto, não ensaio prolongado de vazamento.
Descendentes observados são conferidos ao sair, sem encerrar processos alheios.

Budgets iniciais de regressão para a máquina registrada na evidência:

| Medida | Budget |
| --- | ---: |
| Lista local quente / busca local quente | p95 ≤ 200 ms |
| Detalhe local quente | p95 ≤ 300 ms |
| Clique até avanço do renderer WAV | p95 ≤ 3.000 ms |
| CPU média idle / reprodução local | ≤ 2% / ≤ 30% de um core |
| RSS máxima por fase | ≤ 512 MiB |
| Crescimento de disco por fase | ≤ 1 MiB |
| Filhos vivos após saída | 0 |

Repetir três vezes sem builds/testes concorrentes para comparar regressões;
registrar carga da máquina e variação, sem promover uma rodada isolada a SLO.
Para UI Release, usar também `durvald-macos/scripts/measure-release-performance.sh`
e o [protocolo existente](../../durvald-core/docs/performance-release-baseline.md).

**Na entrega inicial**, custo de banda, CPU/RAM WebKit, buffering dos SDKs e p95
remoto ainda não tinham nova medição. O baseline local mantém banda indisponível,
não zero. Uma [coleta posterior dos players externos](external-player-measurements.md)
mediu três rodadas reais por SoundCloud/YouTube, incluindo bytes atribuídos,
CPU/RSS, avanço, pausa e recuperação; os seis casos passaram sem timeout.
São medidas por item/modo, não um p95 de provedor ou da primeira página de
catálogo remoto. Os relatórios iniciais permanecem históricos. Provas HTTP locais
não validam rede Soulseek real. Nenhuma nova integração foi habilitada por
padrão; a meta externa de catálogo de 2 s exige sua própria prova.

A [evidência desta rodada](../evidence/provider-probes/integration-baseline-2026-10-28.json)
registra os números locais e seus limites. O resultado de processo sem relatório
válido/amostras suficientes nunca aprova desempenho. Falhas produzem `blocked`
ou `budget_exceeded`, sem substituir relatório existente.

## Resultado local desta entrega

Mac17,3 ARM64, macOS 27.2; sem builds/testes concorrentes durante a coleta.
A rodada final teve p95 de lista **0,066 ms**, detalhe **0,029 ms**, busca
**0,334 ms** e início até avanço do renderer **27,948 ms** (preparação **1,535 ms**,
observação de buffering **26,305 ms**). CPU média idle/reprodução: **0,11%/1,50%**;
RSS máxima: **30,59/30,81 MiB**. Crescimento de disco nas fases: **0 bytes**;
nenhum filho observado ou vivo após saída. São números do core/fixture, sem
custo SwiftUI, WebKit ou escuta audível.

Uma [segunda rodada com preferências incompatíveis](../evidence/provider-probes/integration-baseline-broken-plugins-2026-10-28.json)
confirmou `preferences_available: false`, registro remoto vazio e reprodução
nativa funcional com p95 **27,900 ms**, dentro dos mesmos budgets. Para reproduzir,
acrescentar `--broken-plugins` ao executor Python. Os arquivos pessoais nunca
são lidos ou modificados. Ambos os resultados são baselines curtos, sem garantia
de p95 em outra biblioteca/hardware ou estabilidade prolongada.

## Validação

540 testes Rust aprovados (4 smokes externos ignorados); 437 testes macOS
aprovados (5 smokes externos omitidos); 30 testes Python aprovados. Clippy em
todos os targets/features sem warnings; smoke Swift/UniFFI aprovado. O teste de
ciclo de vida confirmou áudio local com preferências incompatíveis, e o teste
Swift confirmou leitura de diagnóstico sem habilitar/consultar serviços. O
executável slskd instalado foi verificado offline sem iniciar processo.

[Resumo e hashes de validação](../evidence/provider-probes/integration-stabilization-2026-10-28.json).
Nenhuma migração ou alteração de dados pessoais nesta etapa.
