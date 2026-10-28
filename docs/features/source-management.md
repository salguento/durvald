# Etapa 8 — Busca e gestão mínima de fontes

Concluída em 28/10/2026. A tela **Origens…** nas informações da faixa e a ação
**Onde ouvir / origens** nos detalhes do catálogo permitem buscar e associar
origens para uma faixa individual. Abrir a tela não inicia consultas externas.

## Busca e associação

A busca consulta somente os provedores habilitados, com resultados e falhas
independentes. MusicBrainz consulta relações de streaming/vídeo da gravação
selecionada; uma faixa local pode reutilizar sua referência MusicBrainz, quando
identificada sem ambiguidade. Sem essa identidade, não há busca por aproximação
de título. O adaptador `service-links`, habilitado inicialmente, reconhece links individuais
de SoundCloud, YouTube e Bandcamp sem consultar a rede. Links curtos explícitos
`https://on.soundcloud.com/…` usam uma consulta limitada aos redirecionamentos
do SoundCloud, preservando somente o permalink canônico da faixa. Ele não
pesquisa o catálogo desses serviços. Links de álbuns e playlists ficam fora deste
recorte.

Os candidatos mostram provedor, uploader, versão, duração e capacidade; dados que
não vieram do provedor aparecem como não informados. Os links atuais oferecem
**Abrir no serviço** e têm disponibilidade desconhecida. Não comprovam áudio
completo, prévia nem player integrado. URLs canônicas descartam contexto de
playlist, fragmentos e parâmetros temporários. Não há scraping ou extração de
mídia.

Resultados permanecem na sessão até a revisão explícita. É possível adicionar
uma faixa externa à biblioteca ou escolher uma faixa existente como destino.
A confirmação alerta para artista, versão, edição e duração. A associação é
transacional e idempotente; uma origem já pertencente a outra faixa gera erro,
sem transferir o vínculo nem mesclar dados pessoais. Gerações de consulta e
sessões fechadas rejeitam candidatos antigos; desabilitar o provedor impede
novas associações.

## Gestão e reprodução

Origens salvas podem ser listadas, verificadas, habilitadas, desabilitadas,
removidas e marcadas como preferidas. Também é possível anexar um arquivo local.
O teste local abre o arquivo pelo decoder; falhas ficam como indisponibilidade
da origem. Testar um link apenas valida seu formato e informa que é necessário
abrir o serviço para conferir o acesso. Falhas externas não viram arquivos
locais ausentes.

**Tocar agora com esta origem** usa um arquivo local habilitado e verificado,
sem mudar a preferência salva. A escolha vale para a ocorrência atual em memória,
incluindo sua repetição; não é persistida como seleção de sessão após reinício.
A preferência local participa da seleção padrão já existente. Links remotos
preferidos não ativam streaming: reprodução interna remota depende das etapas
9–10. Abrir um serviço não simula eventos de escuta ou histórico.

Remover uma origem preserva faixa, favoritos, avaliações e demais dados pessoais.
A preferência é invalidada quando a origem é excluída. A migração aditiva 23
armazena observações por origem, com exclusão em cascata; referências persistentes
continuam separadas de URLs temporárias de mídia. API e bindings UniFFI/Swift
foram atualizados, inclusive a biblioteca distribuída com o aplicativo macOS.

## Validação

- Suíte completa do core com todas as features: 475 testes passaram; três smokes
  externos previamente ignorados permaneceram ignorados.
- Fixture adicional MusicBrainz: passou, cobrindo escopo por gravação, cache,
  deduplicação, relações encerradas, rejeição de coleções e capacidade externa.
- Testes de associação pela API cobrem revisão obrigatória, idempotência,
  propriedade do vínculo, gerações, cancelamento, provedor desabilitado,
  reprodução local explícita, reinício, preferência e preservação de dados.
- Dois testes macOS passaram: abertura sem busca, resultados parciais enquanto
  outro provedor aguarda/falha e descarte de resultados após trocar o item.
- Compilação Release com UniFFI e regeneração de bindings concluídas.
- Clippy em todos os alvos/features, com avisos como erros, passou; smoke real
  da ponte Swift/UniFFI passou com os bindings e a biblioteca Release.

A suíte é offline; não comprova disponibilidade atual dos links nos serviços.

## Atualização: player integrado

A [etapa 9B](embedded-playback.md), concluída em 28/10/2026, acrescenta
**Ouvir no player integrado** para uma origem SoundCloud salva e habilitada.
A escolha é explícita; candidatos continuam como links até a associação, e
YouTube/Bandcamp mantêm somente abertura externa. A capacidade real de cada
item é observada ao carregar o widget, sem inferir áudio completo ou prévia.

## Atualização: fluxo de ponta a ponta

A [etapa 10](provider-playback.md) acrescenta ouvir um candidato SoundCloud antes
de salvar, associar durante a audição e usar a preferência no botão normal de
reprodução. A audição temporária não cria itens na biblioteca ou no histórico.
O controle do player SoundCloud é separado dos provedores de busca de fontes.
