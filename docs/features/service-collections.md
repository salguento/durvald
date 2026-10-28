# Etapa 13 — Demais serviços e importação de coleções

> Evolução na etapa 14: histórico por origem/tentativa, sessão remota recuperável
> e navegação unificada da fila mista foram consolidados. Veja
> [Histórico e sessão consolidados](consolidated-playback.md).

Implementada em 28/10/2026 sobre as etapas 10–12. A seção **Serviços e coleções**
da biblioteca e o botão **Importar link ou coleção…** em Explorar recebem links
públicos de Bandcamp, SoundCloud e YouTube. Consultar o link apenas captura
metadados. Salvar exige selecionar ocorrências, revisar versões e confirmar;
reproduzir é uma ação separada.

## Serviços e configuração

Cada leitor tem plugin, flag, cache, falhas e credenciais independentes. Todos
começam desativados. A configuração está em **Ajustes → Serviços** e na própria
tela de importação. As credenciais usam o armazenamento protegido existente;
campo vazio mantém a credencial, e a ação de remover também desativa o leitor.

| Serviço | Entrada e leitura | Reprodução e limites |
| --- | --- | --- |
| Bandcamp | Faixa ou álbum público em um subdomínio `*.bandcamp.com`; metadados públicos da página, sem credencial. Álbum dividido em páginas locais de até 50 faixas. | Abre no serviço. A presença de stream é uma observação, sem salvar sua URL. Não comprova formato original, qualidade sem perdas, compra ou direito de download. |
| SoundCloud | Faixa, playlist pública e links curtos compartilhados. API oficial com token OAuth de um aplicativo autorizado; redirecionamento da API restrito ao próprio host. Playlist mantém ordem e ocorrências repetidas. | Widget oficial existente, com sua flag independente. Distingue acesso completo observado, prévia, bloqueio e indisponibilidade. Prévia conhecida não registra execução integral. |
| YouTube | Vídeo ou playlist pública finita, com chave da API de dados. `playlistItems` paginado e verificação em lote por `videos`, preservando identidade do vídeo e da ocorrência. | IFrame oficial, vídeo e controles visíveis, com flag própria. Exige metadados de vídeo finito e incorporável verificados há menos de 24 horas. Lives, estreias, mixes e vídeos restritos ficam fora deste fluxo. |

O token SoundCloud é informado manualmente; renovação automática e login OAuth
interativo não fazem parte desta entrega. Playlists do YouTube precisam estar
acessíveis pela chave configurada. Canal e uploader são créditos do serviço,
sem inferir identidade verificada de artista ou associação por título. A revisão
mostra esse limite e pede conferir covers, remixes, edições e introduções.

Coleções autenticadas do Bandcamp e arquivos comprados continuam condicionados
a uma prova própria. Esta etapa não extrai áudio, não baixa mídia desses serviços
e não adiciona um helper. As transferências Soulseek da etapa 12 permanecem
independentes.

## Captura, revisão e retomada

- Cada URL canônica mantém uma captura persistida. Abrir a tela ou selecionar uma
  captura consulta apenas dados locais; páginas externas são carregadas por ação
  explícita. Cache normalizado por serviço/URL/cursor dura uma hora.
- Cada captura admite até 1.000 ocorrências e 40 páginas, com até 50 itens por
  página; até 100 capturas podem ser criadas. Limites e coleções incompletas são
  apresentados como resultado parcial. Cursores repetidos são recusados.
- Seleções desmarcadas são preservadas quando outra página chega. Itens bloqueados,
  lives e indisponíveis permanecem inspecionáveis, sem criar faixas fictícias.
  Uma falha de página preserva o que já foi recebido e salvo.
- Cancelar invalida consultas em andamento e interrompe a gravação entre itens.
  Retomar é explícito. **Rever páginas recebidas** consulta novamente as páginas,
  sem prolongar artificialmente a validade da verificação do YouTube por cache.
- Ordem, IDs de ocorrência e referências conhecidas são conferidos ao rever uma
  página. Mudança incompatível é recusada e conserva a captura anterior. Não há
  sincronização automática com edições futuras de uma coleção.

A migração aditiva 25 cria o diário de capturas, cache de metadados públicos e
políticas observadas de mídia. Cada item é salvo em transação com seu recibo,
a origem e a posição na playlist. Repetir a confirmação ou reiniciar o app não
duplica origens ou ocorrências já confirmadas. Repetições legítimas compartilham
a faixa e mantêm posições distintas. Metadados pessoais e nome da playlist
editados pelo usuário são preservados. Uma posição ocupada por edição manual
falha apenas para aquele item; não substitui a alteração nem deixa uma faixa
órfã criada pela tentativa.

O cache e o diário não guardam chaves, tokens, cookies, headers, HTML bruto ou
URLs de mídia. Requisições têm prazo e resposta limitados; falhas de autenticação,
restrição, ausência, limite de requisições e timeout têm estados próprios. Um
serviço desativado não efetua novas consultas nem confirma importações.

## Player YouTube

O host nativo reutiliza o contrato de player integrado da etapa 9B, incluindo
controle de geração e exclusão com áudio nativo. Uma página própria é servida
somente em loopback, numa porta temporária e caminho aleatório, para fornecer
origem HTTP/referrer ao IFrame oficial. O servidor não expõe arquivos, proxy,
credenciais ou mídia; é encerrado junto com o WebView.

O vídeo e os controles permanecem visíveis. Ready, reprodução, pausa, progresso,
seek, término e falha vêm do SDK. Não há áudio separado, equalização, crossfade
ou promessa de reprodução sem intervalo. A verificação finita no núcleo é
obrigatória mesmo para origens antigas salvas manualmente. Desativar SoundCloud
não interrompe YouTube, e vice-versa.

## Validação

Os testes cobrem os três adaptadores com respostas controladas, importação real
em SQLite, paginação, cache, retomada, cancelamento, repetição de ocorrências,
prévia, restrição, lives, falhas parciais, credenciais isoladas, redirecionamento
externo recusado, mudanças na captura e preservação de edições pessoais. Os
testes Swift incluem o limite UniFFI real e o host WebKit com servidor local.

Em 28/10/2026, uma consulta real do adaptador Bandcamp retornou os metadados da
faixa pública `benprunty.bandcamp.com/track/civil-explore`. O smoke opt-in do
IFrame oficial YouTube com `M7lc1UVf-VE` passou com reprodução/progresso, pausa,
retomada, seek e stop. Não havia token OAuth SoundCloud nem chave YouTube Data
API para validar essas consultas autenticadas contra os serviços reais;
seus contratos foram testados com respostas controladas. O sucesso do player
YouTube não comprova acesso à API de dados com uma chave do usuário.

Resultados e evidências: [service-collections-2026-10-28.json](../evidence/provider-probes/service-collections-2026-10-28.json).

Referências dos contratos externos:
[SoundCloud API](https://developers.soundcloud.com/docs/api/guide),
[YouTube playlistItems](https://developers.google.com/youtube/v3/docs/playlistItems/list),
[YouTube videos](https://developers.google.com/youtube/v3/docs/videos/list),
[IFrame Player API](https://developers.google.com/youtube/iframe_api_reference) e
[chaves da API Google](https://docs.cloud.google.com/docs/authentication/api-keys-use).
