# Etapa 9B — Coordenação de player integrado

Implementação em 28/10/2026, com SoundCloud como piloto. A opção **Ouvir no
player integrado**, nas origens salvas de uma faixa, abre o widget oficial
visível na parte inferior da janela. O painel permanece disponível após fechar
a gestão de origens. Os controles do Durvald e os controles de mídia do macOS
encaminham pausa, retomada, volume e posição ao mesmo player.

## Fronteiras e estados

Rust controla a sessão, os comandos, as transições, a fila seguinte e o histórico.
Swift hospeda o WKWebView visível e traduz a Widget API oficial. Os contratos
públicos são aditivos: `EmbeddedPlaybackHost`, comandos, eventos e snapshot do
player integrado; o DTO existente de reprodução mantém sua estrutura.

O host é registrado explicitamente pela plataforma. Sem host, a tentativa falha
antes de interromper áudio local. Apenas origens SoundCloud habilitadas,
pertencentes à faixa e com URL individual reconhecida são aceitas. YouTube e
Bandcamp continuam com abertura externa. Preferir uma origem remota não ativa
automaticamente esse modo: a entrada deste incremento é a escolha explícita de
uma origem SoundCloud já associada. Resolução geral, seleção automática de
provedores e o fluxo completo de descoberta continuam na etapa 10.

Cada abertura tem uma geração própria. Eventos fora de ordem, duplicados ou de
uma geração anterior não alteram a sessão atual. Os estados são carregando,
tocando, pausado, encerrado e falha. Entrega de um comando não simula sucesso:
posição e reprodução dependem dos eventos observados do widget. Seek só é
oferecido depois de observar duração; comandos durante o carregamento aguardam
a página ficar pronta. Falha do serviço, término do processo WebKit e ausência
de progresso/resposta por 30 segundos encerram o transporte e permitem retry
explícito. Um retry valida novamente a origem e abre outra geração.

Para alternar de áudio local ao widget, o core encerra o backend nativo,
incluindo vozes residuais de crossfade e preload. Para voltar a áudio local,
prepara o arquivo e exige que o host confirme a suspensão de toda mídia WebKit
antes de tocar. Recusa ou falta dessa confirmação bloqueia a troca. O backend
local é recriado quando necessário, preservando as configurações locais.

O WebKit usa armazenamento não persistente. Somente a página principal do
widget atual publica eventos; URLs são codificadas como dados, sem interpolação
livre em HTML/JavaScript. Não há extração de áudio, gravação de cookies ou
persistência de URLs temporárias de mídia. O encerramento libera o widget e seu
handler de mensagens; retirar o painel da janela também solicita stop.

## Fila, histórico e limites

A ocorrência integrada aparece no início da fila apresentada pelo core. As
ocorrências seguintes, inclusive duplicatas, permanecem editáveis e preservam
seus IDs. Enfileirar uma faixa durante a reprodução integrada não inicia áudio
local simultâneo. No término, o core avança para a próxima faixa local disponível;
se ela não puder ser preparada, mantém o término e mostra uma mensagem, sem
pular silenciosamente a faixa. Próxima/anterior explícitas também exigem
encerramento confirmado do widget antes de tocar um arquivo.

Repetir uma abre outra geração. Repetir todas, sem próximas faixas, repete a faixa
integrada; com próximas faixas, a navegação segue a fila local existente. A
reconstrução de ciclos completos de uma fila mista, incluindo retorno automático
à origem remota anterior, permanece na etapa 14. A navegação anterior conserva
o histórico de navegação local, sem inventar um arquivo para a ocorrência remota.

Uma conclusão só entra no histórico se houver duração observada e tempo de
avanço suficiente: metade da duração ou quatro minutos, o que for menor.
O avanço contabilizado é limitado pelo tempo transcorrido enquanto tocava;
seek, carregamento, pausa, erro e comandos não contam como escuta. FINISH
repetido não duplica o registro. A duração gravada vem do widget, preservando
os metadados canônicos da faixa. Scrobbling Last.fm remoto não foi ativado
neste incremento.

A sessão do widget é temporária: reiniciar não abre rede nem retoma áudio remoto
automaticamente. A origem associada e as próximas faixas locais persistidas
continuam disponíveis; a reprodução remota exige nova ação explícita.
Equalizador, normalização, espectro, saída de áudio escolhida no player nativo,
crossfade e gapless não processam o áudio WebKit. Duração observada não comprova
áudio completo em vez de prévia. Acesso por item, distribuição assinada e
notarização continuam com os limites registrados na prova do provedor.

## Validação

Oito testes offline pela API Rust cobrem host ausente, propriedade/habilitação da
origem, comando versus evento, gerações e sequência, números inválidos, pausa,
seek, volume, timeout, stop recusado, fila com duplicatas, avanço local, repetição,
retry e histórico com duração efetiva sem contagem por seek. O caso adicional
de cancelamento bloqueia a troca local enquanto há uma abertura em trânsito,
e verifica que nenhuma abertura tardia sobreviva à substituição.

A suíte macOS inclui um fixture WebKit real através da ponte UniFFI, incluindo
pausa antes de a página disponibilizar comandos. Os smokes externos são opt-in
com `TEST_RUNNER_DURVALD_EMBEDDED_LIVE_SMOKE=1` no executor do Xcode e usam um
widget oficial visível e sem som. A execução positiva testa avanço do relógio,
pausa, retomada, seek, término e encerramento; a negativa usa uma faixa
inexistente.

A suíte completa passou em **484 testes Rust e 416 testes macOS**; três smokes
externos Rust e dois macOS permanecem opt-in. Clippy em todos os alvos/features,
com avisos como erros, passou. Release, bindings e smoke UniFFI foram verificados.

**Limitação externa observada:** a primeira execução real concluiu todos os
controles, incluindo FINISH. Nas repetições, o widget avançou até aproximadamente
213,15 s de uma duração reportada de 213,89 s e não enviou FINISH após seek perto
do fim. Repetir a prova original da etapa 5, fora do Durvald, reproduziu a
limitação: ready/play/progress/pause/resume/seek passaram; ended ficou falso.
Isso não é convertido em término artificial: após 30 segundos sem avanço, o
core suspende o widget e apresenta falha recuperável. O caso de faixa inexistente
passou, assim como os fixtures de término, timeout, cancelamento e stop.

[Evidência consolidada](../evidence/provider-probes/soundcloud-coordination-2026-10-28.json)
e [reteste da prova de referência](../evidence/provider-probes/soundcloud-widget-retest-2026-10-28.json).

Referência de comandos e eventos: [SoundCloud Widget API](https://developers.soundcloud.com/docs/api/html5-widget).
