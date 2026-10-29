# Provas técnicas dos provedores — etapa 5

Data da execução: **27/10/2026**. Implementa o [item 5 do roteiro](../roteiro-integracoes-musicais.md).

A entrega contém executores HTTP/WebKit reproduzíveis, testes de contrato,
relatórios de observações reais e uma matriz de decisão. O código fica em
[`tools/provider-probes`](../../tools/provider-probes/README.md), separado do
runtime e dos dados pessoais do aplicativo.

## Resultado e piloto

**Piloto técnico escolhido: SoundCloud, para faixa individual pelo widget
oficial visível em WebKit.** É uma decisão sobre o próximo transporte a
implementar; não habilita streaming no aplicativo e não aprova áudio direto
para o player Rust. Completo/prévia e acesso por item continuam dependentes do
serviço, sem inferência pelo fato de uma faixa ser pública.

A escolha usa provas reais de ready, play, avanço do relógio, pause, resume,
seek, término e sinal de erro de item inexistente. SoundCloud oferece o ramo de
áudio incorporado observado; YouTube permanece alternativa para vídeo individual.
A matriz não usa sucesso de um servidor simulado para aprovar um provedor real.

| Provedor | Evidência executada | Decisão e limite |
| --- | --- | --- |
| SoundCloud | Widget oficial em WKWebView: reprodução, posição, pausa, retomada, seek e término; `ERROR` para ID inexistente. | Piloto de player incorporado. API OAuth bloqueada por credencial ausente; áudio direto e completo/prévia não validados. |
| YouTube | IFrame oficial em WKWebView, com controles e término; erro para vídeo inexistente. | Alternativa de vídeo incorporado. Não adotado como fonte de áudio isolado ou download. |
| Bandcamp | Leitura real de página individual, metadados e referência de embed oficial. | Consulta/abrir no serviço; controles de playback e download não validados. |
| Soulseek via slskd | Contrato simulado e backend nativo real: autenticação, login e criação/cancelamento/remoção de buscas. | Buscas reais sem respostas e conexão com timeouts; incremento e transferência real não validados. Backend encerrado a pedido do usuário. |

A [matriz gerada](../evidence/provider-probes/matrix.json) contém a decisão por
capacidade e o estado `production_enabled: false` para todos os candidatos.
Os JSONs no mesmo diretório são a referência das observações e dos hashes dos
executores. Uma execução posterior pode produzir outro resultado; os SDKs
remotos não são congelados pela existência deste relatório.

## Provas dos players

Os casos públicos são os exemplos usados pela documentação dos SDKs: vídeo
`M7lc1UVf-VE` e faixa SoundCloud `293`. A janela usa armazenamento não persistente,
sem som, sem conta do Durvald e sem ler sua biblioteca. O teste avança para o
final para observar o evento de término; não alega escuta integral em sequência.

Para YouTube, a prova usa [IFrame API](https://developers.google.com/youtube/iframe_api_reference),
com origem HTTP loopback e identificação do cliente pela página. Essa API
fornece controle/eventos do vídeo; sua existência não fornece uma URL de áudio
para Kira. As [políticas do provedor](https://developers.google.com/youtube/terms/developer-policies)
orientam a decisão de preservar vídeo, player e controles visíveis, sem separar
áudio, ocultar player ou introduzir extração/download como atalho.

Para SoundCloud, a prova usa [Widget API](https://developers.soundcloud.com/docs/api/html5-widget).
O widget preserva a apresentação do provedor e seus links. O evento genérico de
erro não é traduzido artificialmente para um código HTTP ou causa específica.
A [API de streaming](https://developers.soundcloud.com/docs/api/guide) é um caminho
separado: acesso OAuth, nível de acesso por faixa, atribuição e formatos precisam
ser verificados quando houver credenciais. Os [limites](https://developers.soundcloud.com/docs/api/rate-limits)
da API não são tratados como uma autorização para usar mídia de qualquer item.

URLs temporárias e sua expiração não são expostas por esses transportes
incorporados; ficam sob gestão do player oficial. A prova registra esse limite,
sem inventar uma validação de renovação de URL assinada. O futuro transporte
precisa observar erros do player e revalidar acesso por item. Também não foi
provada distribuição assinada/notarizada com App Sandbox.

## Bandcamp

O caso real é a página pública de [Civil (Explore)](https://benprunty.bandcamp.com/track/civil-explore).
Foram observados item individual e URL oficial de embed, sem extrair ou salvar
URL temporária de áudio. Isso comprova descoberta do embed, não reprodução
controlável ou download.

A [documentação de embed](https://get.bandcamp.help/en/articles/15263071-how-do-i-create-a-bandcamp-embedded-player)
e a [API publicada](https://bandcamp.com/developer) delimitam caminhos distintos.
A API publicada atende contas de selos e parceiros; não foi presumida uma API
pública geral de busca/streaming. O candidato fica em abrir no serviço até haver
um caminho adicional validado.

## slskd e destino do download

O contrato foi conferido no código oficial da versão **0.26.2**, árvore
`e472ecd706050332c8615dc3b908c92afaed592c`.
[Hashes e URLs dos contratos](../evidence/provider-probes/upstream-contracts.json)
registram a referência usada, incluindo DTOs de lote e transferência.

A prova respeita `POST searches`, leitura de respostas, `PUT` para interromper e
`DELETE` para remover somente sua busca. Downloads usam a API de lotes; o
endpoint antigo de enfileiramento individual está marcado obsoleto nessa versão.
A transferência pertence ao UUID recebido no lote criado pela prova; nome,
usuário ou tamanho não autorizam cancelar uma transferência preexistente.

Uma conclusão importante é que `Transfer.filename` é o nome no peer, não o
caminho resolvido do arquivo no computador. A [configuração do backend](https://github.com/slskd/slskd/blob/0.26.2/docs/config.md)
e um mapeamento remoto/local explícito são necessários. A ferramenta verifica
conclusão, arquivo regular, confinamento à raiz local e tamanho; registra um
hash observado para auditoria, sem alegar checksum de origem. Não importa o
arquivo na biblioteca.

Na primeira rodada não havia backend configurado. Em uma rodada posterior,
foi instalado o pacote oficial macOS ARM64, com checksum verificado, API em
`127.0.0.1:5030`, autenticação habilitada e conta nova de teste autorizada pelo
usuário. Credenciais, binários e dados ficam apenas na pasta privada ignorada
pelo Git. Nenhuma pasta da biblioteca foi compartilhada.

A API real respondeu com autenticação e rejeitou acesso sem chave (401). A conta
conseguiu login; buscas foram criadas, canceladas e removidas, mas retornaram
zero respostas. Foram observados timeouts após login e reconexões, inclusive
após testar o endpoint alternativo `server.slsknet.org:2242`. A restrição da rede
do trabalho é uma hipótese do usuário, não uma causa confirmada. O usuário
cancelou a investigação e o backend foi encerrado, sem autostart registrado.

A [evidência da configuração](../evidence/provider-probes/slskd-backend.json) é
um snapshot capturado durante a execução; não significa que o backend permaneça
rodando. A [prova real](../evidence/provider-probes/slskd-live.json) está marcada
como limitada, com incremento de respostas, transferência e mapeamento após uma
transferência real pendentes. O fixture continua sendo simulação, sem substituir
essas verificações. A configuração privada foi preservada para outra rede.

## yt-dlp e distribuição

**Não adotado nesta etapa.** Os players oficiais permitiram provas sem esse
componente; não foram instalados yt-dlp, runtimes de extração ou FFmpeg.
Disponibilidade das ferramentas no PATH está registrada nas evidências.

Se uma prova futura justificar adotá-lo, o desenho deverá selecionar versão e
artefato, verificar assinatura dos checksums contra chave confiável fixada,
verificar o binário, fazer substituição atômica com rollback e definir quem
atualiza a dependência. Um hash obtido junto do mesmo download não basta como
verificação de autenticidade. A [distribuição oficial](https://github.com/yt-dlp/yt-dlp#release-files)
publica assinaturas e descreve diferenças de licença entre artefatos. Runtime,
FFmpeg quando necessário, licenças, execução sob sandbox, assinatura e notarização
precisam de provas próprias. Nada disso foi declarado aprovado sem execução.

## Validação e próximos limites

**17 testes automatizados aprovados**, com HTTP local e arquivos temporários.
Cobrem incremento/cancelamento, autenticação sem vazamento em relatório,
rate-limit sem loop, isolamento por UUID, cancelamento de transferência,
recuperação após falha de cleanup, mapeamento, symlink/traversal, ausência de
credenciais, HTML realista de Bandcamp, descarte de URLs assinadas e decisão do
piloto sem promover fixture ou código desatualizado.

Os testes WebKit reais são adicionais a essa suíte, com resultados positivos e
negativos registrados em JSON. Eles não são confundidos com os testes locais.
Não houve alteração de core, bindings, migrações ou UI de produção nesta etapa;
a suíte Rust/macOS do aplicativo não foi repetida para uma entrega isolada de
provas. O próximo ramo deve implementar transporte de player incorporado e sua
integração com fila/eventos, respeitando as dependências de catálogo/origens do
roteiro, antes de habilitar as ações de escuta.

Após a configuração do backend, a suíte local foi ampliada e passou em **24
testes**, incluindo permissões dos arquivos privados, preservação da conta,
configuração sem compartilhamentos, arquivo de instalação e controle do processo.

## Reteste Soulseek em 28/10/2026

A mesma instalação slskd 0.26.2.0 e a configuração privada preservada foram
reativadas, com autenticação da API e login Soulseek bem-sucedidos. A busca
`debussy arabesque` recebeu **247 respostas**, observadas pela primeira vez
na terceira leitura (aproximadamente dois segundos após iniciar a busca).
As oito leituras registraram `0, 0, 247, 247, 247, 247, 247, 247`.
Criação, incremento, cancelamento e remoção da própria busca passaram.

Esse reteste não reproduziu o bloqueio anterior de busca sem respostas; não
estabelece a causa dos timeouts de 27/10 nem garante conectividade futura.
A contagem representa respostas de busca, não quantidade de arquivos baixados.
Não houve transferência, compartilhamento da biblioteca nem mudança na integração
de produção. O backend temporário foi encerrado após a execução.

[Evidência do reteste](../evidence/provider-probes/slskd-retest-2026-10-28.json).
O relatório e a matriz originais continuam preservados como registros históricos;
transferência real e mapeamento de arquivo continuam pendentes.

## Evolução: coordenação SoundCloud no aplicativo

Em 28/10/2026, a [etapa 9B](embedded-playback.md) integrou o widget visível ao
core e ao aplicativo macOS. Os testes reais do novo caminho confirmaram
reprodução, avanço, pausa, retomada, seek e faixa inexistente, sem extrair áudio.
O FINISH passou inicialmente e depois não chegou em repetições com seek perto
do fim; a prova isolada original também reproduziu essa limitação. O core
trata ausência de avanço como falha recuperável, sem fabricar término ou histórico. [Evidência da coordenação](../evidence/provider-probes/soundcloud-coordination-2026-10-28.json).
A matriz original continua sendo o registro da etapa 5; áudio nativo, acesso
completo/prévia por item e distribuição notarizada não foram promovidos por
essa implementação.
