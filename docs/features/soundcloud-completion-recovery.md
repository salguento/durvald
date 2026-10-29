# SoundCloud: término, fila, histórico e recuperação

Data: 29/10/2026. Segunda pendência da
[avaliação do roteiro](../avaliacao-roteiro-integracoes-musicais.md).

## Entrega

A validação passa pelo controller WebKit de produção e pela ponte Swift/UniFFI
até o core Rust, com uma biblioteca descartável, player oficial visível e volume
zero. Os casos reais usam `https://soundcloud.com/forss/flickermood`, o mesmo
exemplo das provas anteriores. Nenhuma biblioteca pessoal é aberta ou alterada.

O caso de **término natural** não usa seek ou aceleração: aguarda a reprodução
até FINISH e verifica avanço para o próximo WAV local, contexto e ocorrência
corretos, preservação da ocorrência duplicada seguinte e um único histórico
atribuído à origem remota. Reentregar o término da geração anterior não cria play
adicional nem salta outro item.

O caso de **seek próximo ao fim** observa progresso inicial, solicita posição
próxima ao fim e aceita apenas duas saídas documentadas: FINISH real com avanço
uma vez e zero plays por seek, ou falha recuperável sem inventar conclusão,
sem histórico e conservando a fila. O caso natural exige FINISH real; recuperação
por timeout não o transforma em sucesso de conclusão natural.

## Correções

1. **Prazo de falta de progresso:** notificações PLAY repetidas enquanto o estado
   já era Playing renovavam o prazo de 30 segundos. Um SDK que repetisse PLAY sem
   avançar podia manter a tentativa indefinidamente. Agora só a entrada em Playing
   concede nova tolerância de início/retomada; depois é necessário avanço real.
   O teste novo falhou antes da correção (Playing em vez de Failed) e passou depois.
2. **Seek do adaptador SoundCloud:** removida a chamada PLAY adicional imediatamente
   após `seekTo`. O comando de posição não injeta um segundo comando de reprodução
   antes de observar a resposta assíncrona do widget. A reprodução e a pausa seguem
   seus próprios eventos. O teste com SDK controlado observou duas chamadas PLAY
   antes do ajuste, em vez de uma.
3. **Término idempotente no host:** cada geração entrega FINISH apenas uma vez,
   usa a posição informada pelo evento quando disponível e ignora eventos de
   progresso/play/pause posteriores à conclusão daquela geração. O core mantém
   sua própria proteção por geração/tentativa; não depende apenas do filtro Swift.
4. **Recuperação na interface:** Tentar novamente faz uma retomada explícita da
   geração falha, sem depender de um snapshot desatualizado de play/pause. Uma
   ação antiga não reinicia outra geração. Quando há próximo item, a mensagem
   oferece Próxima faixa; se o item anterior já terminou e preparar o seguinte
   falhou, oferece Tentar próxima faixa. Avançar manualmente não fabrica escuta.
5. **Mensagem de timeout:** informa que o término não foi confirmado e que a fila
   foi preservada. A tentativa falha é suspensa, sem trocar a origem silenciosamente
   depois de começar áudio.

O cálculo de duração, a política de conclusão e os recibos de histórico da etapa
14 são preservados. Não há mudança de schema ou contrato público/ABI; a biblioteca
Rust embutida é reconstruída com os bindings correspondentes.

## Evidência e alcance

As provas de 28/10 registraram ausência intermitente de FINISH após seek perto do
fim, inclusive no executor isolado de referência. A rodada de baseline desta
entrega, ainda antes das correções do adaptador, recebeu FINISH tanto no término
natural quanto após seek. Isso impede atribuir a ausência histórica a uma causa
única ou afirmar que uma mudança do app corrigiu o serviço externo.

Os testes atuais registram o comportamento observado por rodada. Não inferem
FINISH por posição/duração, proximidade do fim, tempo transcorrido, PAUSE ou
estado de carregamento. Um player pausado por intenção do usuário não deve ser
convertido automaticamente em término. A prova de SDK controlado confirma que
atingir a posição da duração, por si só, não publica Ended.

O baseline real natural levou aproximadamente 217 segundos e registrou uma
escuta; o seek levou aproximadamente oito segundos e não registrou escuta.
Os relatórios finais e a regressão são consolidados na evidência desta entrega.
A disponibilidade e entrega dos eventos podem mudar com o serviço; não se
promete FINISH infalível em todos os itens ou redes, áudio integral por inferência,
gapless, equalização do WebKit ou nova modalidade de streaming.

## Reproduzir

Por padrão, os novos testes reais ficam opt-in. O fixture de término/duplicatas,
o SDK controlado e o teste de recuperação explícita rodam sem rede.

```sh
TEST_RUNNER_DURVALD_SOUNDCLOUD_COMPLETION_LIVE=1 \
TEST_RUNNER_DURVALD_SOUNDCLOUD_COMPLETION_REPORT_DIR=/tmp/durvald-completion \
xcodebuild test \
  -project durvald-macos/Durvald/Durvald.xcodeproj -scheme Durvald \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:DurvaldTests/SoundCloudCompletionTests
```

Executar com a sessão gráfica desbloqueada e manter a janela do player visível.
O preflight dos testes omite a execução real quando identifica tela bloqueada;
um skip não aprova a prova. Uma atividade temporária do processo evita App Nap
no diagnóstico e é encerrada ao finalizar; não desativa o bloqueio da tela nem
altera ajustes do sistema. Executar sequencialmente evita concorrência entre
os dois casos reais. A escuta natural requer cerca de quatro minutos e tem prazo
limitado. Os relatórios exportam eventos/tempos/checks de uma biblioteca sintética,
sem credenciais, cookies, dados da biblioteca pessoal ou URLs temporárias de mídia.

Referência verificada em 29/10/2026:
[Widget API oficial](https://developers.soundcloud.com/docs/api/html5-widget),
com `seekTo`, eventos assíncronos e FINISH como sinal de término.

## Sessão gráfica

Após o baseline positivo, duas tentativas naturais da versão corrigida deixaram
de avançar por volta de seis segundos e foram suspensas pelo core com fila
preservada e zero histórico. O executor de referência, fora do core, também ficou
sem completar os controles e atingiu seu prazo nativo. Uma consulta somente ao
indicador booleano do IORegistry constatou tela bloqueada; nenhuma imagem,
identidade de sessão ou credencial foi capturada.

Essas rodadas são preservadas como tentativas limitadas e não aprovam término
natural nem demonstram uma regressão do serviço. A sessão gráfica era uma
condição de ambiente relevante a controlar. A prova final exige nova execução
com desbloqueio confirmado pelo operador e checks reais de FINISH/fila/histórico.
Não se declara suporte a reprodução WebKit sob tela bloqueada a partir destes
ensaios. O áudio nativo mantém seu transporte próprio.

## Resultado final e validação

A escuta natural final com desbloqueio confirmado passou em aproximadamente
**216,5 segundos até FINISH**: um histórico com **214 segundos ouvidos e 214
segundos de duração efetiva** (arredondados), seguido do WAV local correto. A
ocorrência duplicada seguinte foi preservada. Reentregar o evento da geração
anterior não duplicou histórico nem avançou outro item.

O seek próximo ao fim passou numa rodada anterior com **o mesmo código de
produção corrigido**, com FINISH, avanço uma vez e **zero registros de histórico**.
Na última suíte, a sessão voltou a estar bloqueada antes de repetir esse caso;
o preflight o omitiu. A evidência aprovada de seek é a rodada anterior, sem
contabilizar o skip como sucesso. Nenhuma garantia é derivada das tentativas
limitadas durante o bloqueio.

Regressão padrão: **541 testes Rust e 440 macOS aprovados**, mantendo quatro e
sete smokes externos, respectivamente, opt-in/omitidos. Clippy em todos os
alvos/features e smoke Swift/UniFFI aprovados. A suíte final de conclusão teve
quatro testes aprovados e um omitido; as duas provas reais aprovadas estão
identificadas individualmente no relatório. Biblioteca Release/embutida/app
testado têm o mesmo hash; bindings Swift correspondentes conferem.

[Evidência consolidada e hashes](../evidence/provider-probes/soundcloud-completion-2026-10-29.json).
[Comparação isolada durante a limitação da sessão](../evidence/provider-probes/soundcloud-completion-reference-2026-10-29.json).

A pendência de implementação, recuperação e prova individual de término/fila/
histórico está atendida nesse escopo. Os relatos históricos de FINISH intermitente
são preservados; não se declara o SDK infalível ou uma causa única corrigida.
