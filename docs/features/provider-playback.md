# Etapa 10 — SoundCloud de ponta a ponta

Concluída em 28/10/2026. O primeiro provedor é SoundCloud pelo widget oficial
visível, usando o transporte da etapa 9B. Não há extração de áudio nem transporte
HTTP nativo. YouTube e Bandcamp continuam oferecendo abrir no serviço.

## Fluxo entregue

Em Explorar, **Ouvir link SoundCloud…** recebe um link de faixa individual e um
nome informado pelo usuário. Também é possível buscar fontes para uma faixa da
biblioteca ou do catálogo, usando suas relações MusicBrainz ou um link individual.
Links de compartilhamento `https://on.soundcloud.com/…` são expandidos ao
confirmar a busca; o formulário aguarda a resposta e distingue erro de campos,
link expirado e falha de conexão. A expansão consulta somente headers HTTPS do
host de compartilhamento, com até três saltos e limite total de 15 segundos.
O destino deve ser uma faixa individual SoundCloud; apenas seu permalink
canônico segue para revisão e persistência. Links completos continuam offline.
Não foi criada uma busca textual geral na API SoundCloud. Nomes informados não
são tratados como metadados verificados nem como prova de identidade de artista.

O usuário escolhe um candidato SoundCloud e usa **Ouvir antes de salvar**. Isso
abre o widget e mantém uma identidade própria de sessão, sem inserir música,
artista, lançamento ou origem na biblioteca. Controles do Durvald e do macOS
funcionam durante a audição. A fila persistente continua contendo apenas IDs
reais de faixas; o item temporário aparece no painel do widget, sem ID fictício.
Audições temporárias não entram no histórico persistente da biblioteca.

No painel, **Salvar / associar…** permite adicionar uma faixa ou escolher uma
existente. A confirmação exige revisão de artista, versão e duração no widget.
A associação é transacional, preserva valores pessoais e não reinicia o áudio.
Confirmar novamente não duplica a faixa ou a origem. Uma origem pertencente a
outra faixa não é transferida silenciosamente. Salvar valida a geração atual,
portanto uma confirmação antiga não pode associar a origem de outra audição.

Depois de salvar, os IDs da faixa e da origem entram na sessão em andamento.
Ocorrências seguintes na fila mantêm seus IDs. Salvar não cria uma escuta por
si só; o histórico continua dependendo de conclusão e avanço observado, com
as regras da etapa 9B. Prévia, carregamento, retry e seek não fabricam plays.

## Seleção de origem e fallback

O botão normal de reprodução passa a usar esta política no core:

1. Uma origem explicitamente escolhida é exclusiva, sem fallback automático.
2. A preferida da faixa é tentada se estiver habilitada.
3. Arquivos locais são abertos e preparados, respeitando prioridade e identidade.
4. Origens SoundCloud restantes seguem prioridade e ID estável da origem.

No piloto existe somente um provedor remoto de reprodução; links de outros
serviços não são anunciados como áudio nativo. Uma preferida que apenas abre
um serviço pode ser ignorada em favor de áudio compatível, com aviso. Uma
seleção automática considera no máximo oito origens por tentativa.

Falha ao preparar arquivo, resolver provedor, carregar widget ou aguardar seu
início pode usar a próxima origem antes do áudio. A mudança aparece em um aviso
e não altera a preferência salva. Após PLAY **ou progresso observado**, os
candidatos de fallback são descartados: uma falha não muda de versão nem reinicia
áudio silenciosamente. Retry explícito valida novamente a origem atual e abre
outra geração, sem voltar à cadeia automática de fallback.

A mesma seleção é usada para a faixa escolhida de uma coleção e para o próximo
item da fila. Resolução ocorre perto da reprodução; não percorre a fila inteira.
O preload gapless fica restrito a áudio local preparado. Uma próxima origem
integrada usa transição normal. Reconstrução completa de ciclos e navegação de
uma fila mista continuam na etapa 14.

## Adaptador e persistência

O adaptador interno `soundcloud` declara a capacidade `Playback` e o host
`w.soundcloud.com`. Registro, configuração e execução passam pelo runtime de
plugins. O controle **Reprodução SoundCloud no player integrado**, nas origens,
habilita/desabilita a integração de forma persistente; desabilitar encerra o
widget ativo e preserva biblioteca, origens e valores pessoais. Sem host visível
registrado na plataforma, a origem é recusada antes de abrir áudio remoto.

O resolvedor valida a referência e devolve um permalink canônico para o widget.
O SDK oficial resolve mídia, autenticação e expiração durante a execução; o core
não recebe URLs de stream, tokens, cookies ou headers temporários para persistir.
Não há helper externo, subprocesso de extração ou loop de renovação de URLs.
A fila de comandos do host permanece limitada e ordenada, inclusive quando uma
chamada é cancelada, preservando a exclusão entre áudio local e WebKit.

Não houve migração SQLite. O snapshot integrado evoluiu para IDs opcionais e
inclui título, crédito e URL canônica para representar sessões temporárias sem
inventar identidade de biblioteca. As duas cópias dos bindings Swift, o header
UniFFI e a biblioteca embutida são regenerados em conjunto. Consumidores devem
usar os bindings correspondentes à mesma biblioteca. O contrato interno de
plugins permanece na versão 1.

## Validação e limites

Testes Rust cobrem ouvir sem salvar, confirmação e geração, associação idempotente,
preferência e valores pessoais após reinício, plugin desabilitado, escolha explícita,
fallback antes de PLAY/progresso, timeout, proibição de troca durante áudio,
fila com duplicatas, transição local → SoundCloud e identidade temporária.

Os testes macOS cobrem os estados da tela e um fluxo completo com WebKit e UniFFI
reais usando uma página fixture. O smoke opt-in `testLiveSoundCloudListenThenSave`
executa o widget oficial visível e sem som, observa progresso, salva sem reiniciar
a geração e reproduz a faixa salva pelo botão normal. Ele também verifica que a
busca e a audição temporária não adicionaram itens à biblioteca nem histórico.

A [limitação do FINISH após seek perto do fim](embedded-playback.md) permanece:
o core não infere conclusão pelo relógio. Esse caso não foi promovido a sucesso
por esta etapa. Duração observada não comprova áudio completo em vez de prévia.
Controles de áudio locais, scrobbling remoto e distribuição notarizada mantêm os
limites documentados na etapa 9B.

Validação executada: **492 testes Rust e 419 testes macOS passaram**. Três
smokes externos de cada suíte permaneceram opt-in. O fluxo real SoundCloud
foi executado separadamente e passou com a biblioteca Release final, assim
como o fixture WebKit/UniFFI do mesmo fluxo. Clippy com todos os alvos/features
e avisos como erros, geração dos bindings e smoke UniFFI passaram.
[Evidência consolidada](../evidence/provider-probes/soundcloud-end-to-end-2026-10-28.json).

Correção posterior do formulário: o link curto informado pelo usuário foi testado
contra o SoundCloud real pela interface Swift/UniFFI; resolução, nomes e busca
passaram sem inserir itens na biblioteca. A suíte Rust atual passou com 497 testes.
[Evidência do link compartilhado](../evidence/provider-probes/soundcloud-shared-link-2026-10-28.json).
