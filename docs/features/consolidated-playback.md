# Etapa 14 — Histórico, sessão e experiência consolidados

> Prova real posterior em 29/10/2026: [SoundCloud até FINISH, avanço único da fila e histórico idempotente](soundcloud-completion-recovery.md), incluindo seek sem escuta fabricada e recuperação explícita.

Implementada em 28/10/2026 sobre a etapa 13. Arquivos locais e players integrados
compartilham a identidade da faixa, a ocorrência da fila, o contexto da coleção
e as regras de navegação. O transporte permanece específico de cada origem.

## Histórico e tempo ouvido

A migração aditiva 26 acrescenta `source_id`, `effective_duration_seconds` e
`session_id` a `play_history`. Eventos anteriores mantêm IDs, datas e durações;
os novos campos ficam nulos, sem deduzir uma origem ou uma duração observada.
Uma origem removida não apaga o evento histórico nem reatribui sua identidade.

Cada tentativa tem uma identidade lógica independente da geração do WebView.
Confirmar a conclusão grava, numa transação, um recibo dessa identidade, o evento,
o contador e a última reprodução da faixa. Eventos repetidos e retry não criam
outro play. Os recibos sobrevivem à remoção de eventos do histórico: uma nova
tentativa de entrega do mesmo evento não recria o registro apagado. Uma nova
reprodução explícita ou um ciclo de repeat cria outra tentativa válida.

A duração efetiva vem do arquivo preparado ou do SDK, sem alterar os metadados
canônicos da faixa. O campo de tempo ouvido registra o avanço observado,
arredondado para segundos, em vez de atribuir a duração declarada inteira ao
usuário. A conclusão precisa de término do transporte, duração observada e tempo
ouvido de pelo menos metade dessa duração ou quatro minutos, o que for menor.
Prévias conhecidas e audições temporárias sem faixa salva não geram plays integrais.

No transporte nativo, um contador acompanha o relógio do renderizador. Seek é
reconhecido em bloco posterior pelo Kira; seu salto não entra no contador. Pausa,
carregamento e preparação do prefixo gapless também não contam como escuta da
próxima faixa. Nos players integrados, o avanço continua limitado pelo tempo
transcorrido enquanto tocando e pelos eventos observados. Comandos não simulam
confirmações. A última faixa local também registra a conclusão quando não há
outra faixa na fila.

Replay usa a duração observada quando disponível e conserva o cálculo legado
para eventos antigos. Rankings e tempo ouvido da retrospectiva usam os eventos,
inclusive para músicas sem arquivo local. Playlists inteligentes por reproduções
e última escuta usam o mesmo registro canônico e seus contadores transacionais.
A linha do histórico mostra tempo ouvido e duração observada nos novos eventos;
eventos legados continuam sem essa atribuição adicional.

## Sessão e restauração

O envelope de sessão evolui para a versão 4 e continua lendo as versões 1–3.
Persistem os IDs das faixas e origens, exclusividade de uma origem escolhida,
identidade lógica da tentativa, ocorrências, contextos, posição, evidência de
escuta, coleção capturada, exclusões e navegação anterior. Não são persistidos
URLs resolvidos de mídia, cookies, headers ou a geração do host.

A sessão é restaurada **pausada e sem rede**. Somente uma ação de retomar verifica
novamente a origem e prepara o arquivo ou resolve o player oficial. Origem
explicitamente escolhida permanece exclusiva; falha conserva a fila para revisão.
Seleção automática pode recorrer à política de origens antes de começar áudio.
Se essa retomada precisar de outra origem, começa do início e não une evidência
de escuta de versões diferentes. Fallback durante áudio continua fora desta etapa.

No player integrado, posição remota só é enviada depois de `Ready` e da duração
observada. Retomar uma tentativa já terminada começa do início, mantendo o recibo
que impede contagem duplicada do retry. Uma geração antiga não controla a atual.

A sessão captura a coleção no início. Alterar uma playlist posteriormente não
reescreve a fila em andamento. Ao restaurar, IDs que desapareceram são omitidos;
as ocorrências recuperáveis e seus contextos são conservados. Se a coleção completa
não puder mais ser validada, ela não é usada para reconstruir um ciclo fictício.
A navegação anterior também resolve novamente cada faixa existente.

O progresso ativo é salvo em intervalos de aproximadamente um segundo e em ações
relevantes, incluindo pausa, seek confirmado, término e troca explícita do host.
Uma interrupção abrupta pode perder o intervalo ainda não salvo. Não há escrita
periódica de sessão parada nem atualização de provedores em segundo plano.

## Fila mista e interface

A fila canônica mantém a ocorrência atual mesmo quando o WebView possui o áudio.
Repeat Uma, Repeat Tudo, shuffle, retorno à ordem original, reordenação, remoções,
duplicatas e anterior/próxima passam pela mesma política de navegação. O índice
original da ocorrência e seu contexto continuam definindo o destaque na coleção.
A entrada no histórico depende de conclusão observada, não de navegação manual.

A barra do player mostra a origem em uso e se ela corresponde à preferência
salva. Esse controle abre a gestão de origens, que identifica **Em uso** e
**Preferida** separadamente. Avisos de fallback e de sessão restaurada permanecem
visíveis; mudar uma origem não recria a faixa nem apaga favorito, avaliação ou
outros metadados pessoais. O player visível e o áudio nativo continuam exigindo
encerramento confirmado antes da troca de transporte.

## Validação

A suíte inclui casos reais de SQLite, decoder WAV, renderizador simulado, contrato
de host e UniFFI Swift, sem depender de conexão Soulseek ou de credenciais externas.
Cobre fila mista com duplicatas, repeat/shuffle/anterior, reinício, origem desativada,
seek após Ready, faixa removida da coleção, histórico legado, recibo após exclusão
e reinício, último áudio nativo, seek sem play fabricado, Replay e playlists
inteligentes para faixas sem arquivo. A suíte prévia de prévias/retry permanece
obrigatória. As limitações dos SDKs e os critérios externos da etapa 13 continuam
válidos; scrobbling remoto e fallback durante áudio não foram ampliados.

[Evidências e resultados](../evidence/provider-probes/consolidated-playback-2026-10-28.json).
