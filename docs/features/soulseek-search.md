# Etapa 11 — Pesquisa Soulseek independente

Implementação em 28/10/2026. O Durvald conecta uma instância slskd fornecida e
configurada pelo usuário. Não instala, inicia ou distribui o daemon e não
implementa o protocolo Soulseek. A pesquisa não depende de reprodução,
enriquecimento automático, transferência ou importação.

## Uso

Em **Ajustes → Soulseek**, informe o endereço da instância e uma chave de API
slskd com permissão para criar e remover pesquisas. Revise os compartilhamentos
no próprio slskd e confirme essa revisão antes de habilitar. A pesquisa começa
desativada. O Durvald não configura a conta Soulseek nem modifica diretórios de
compartilhamento; habilitar não compartilha a biblioteca.

A chave usa o armazenamento protegido existente (Keychain no macOS, com as
regras de fallback privado de SecureStore), separada das preferências públicas
do runtime. Campo vazio mantém a chave; **Remover chave e desativar** a exclui.
O formulário não recupera nem mostra a chave salva. Endereços remotos exigem
HTTPS; HTTP é aceito apenas para localhost, 127.0.0.1 e ::1. URLs com login,
senha, parâmetros ou fragmentos são recusadas. Redirecionamentos HTTP não são
seguidos, e a chave é enviada somente no header sensível X-API-Key.

**Buscar opções de download** aparece em Explorar, detalhes do catálogo,
informações da faixa e página de álbum. A consulta é editável e sugerida a partir
dos nomes disponíveis. Abrir a tela e filtrar resultados não disparam consultas.
Não há pesquisa automática de discografias, wishlist ou tentativas repetidas.

Os resultados chegam progressivamente e são agrupados por usuário e pasta.
Subpastas CD1/CD2 ou Disc 1/Disc 2 são reunidas sob a pasta do álbum, preservando
os caminhos completos dos arquivos. Filtros locais permitem texto, formato,
bitrate informado e slot livre. A inspeção mostra tamanho, duração, bitrate,
frequência e profundidade quando fornecidos; fila, slot e velocidade também
permanecem desconhecidos quando não informados. Campos ausentes não viram zero,
lossless ou disponibilidade garantida. Arquivos bloqueados e anexos não musicais
não são oferecidos neste recorte.

A referência vem das faixas locais conhecidas do álbum/faixa ou da tracklist da
edição MusicBrainz que já foi carregada explicitamente. Uma tracklist parcial é
identificada como referência de faixas carregadas. Não há seleção automática de
edição para um release-group. Compara-se título normalizado, posição, disco e
duração (tolerância de três segundos quando ambos informam duração). Uma
referência com vários discos exige que o disco seja observado nas subpastas.
A interface informa a cobertura e as durações efetivamente comparadas. Esses
sinais sugerem conjuntos para revisão; não comprovam edição ou qualidade sem
perdas. Uma pasta só com o nome do álbum não ganha correspondência de tracklist.

Selecionar uma oferta apenas inspeciona os arquivos da sessão. Não cria origem
HTTP, faixa, artista, lançamento, histórico ou transferência; não toca áudio e
não altera arquivos locais. Downloads, destino, progresso, retomada, mapeamento
remoto e importação pertencem à etapa 12.

## Execução e limites

O adaptador interno `slskd` declara somente `DownloadSearch`, com rede e
credenciais. Ele usa os limites, cancelamento, habilitação, geração e cooldown
do runtime. O host de cooldown deriva do endereço configurado. Cada sessão
possui UUID próprio e só consulta, interrompe e remove as pesquisas que criou.
Nenhuma operação lista ou remove pesquisas de outros clientes.

O início cria a busca; a tela consulta o snapshot a cada segundo enquanto aberta.
São usados POST /api/v0/searches, GET da própria busca e de suas responses,
PUT para parar e DELETE para remover a própria busca. O timeout da busca enviado
ao slskd é 20.000 ms, conforme o contrato testado da série 0.26.x. Cada requisição
tem limite de cinco segundos e conexão de três; o prazo local após iniciar é
25 segundos. Há limites de 8 MiB por resposta, 200 respostas de peers e 5.000
arquivos exibidos. Ao atingir o limite, a tela pede para refinar a consulta.

Cancelar, fechar, substituir a consulta ou alterar a configuração impede a
publicação de resultados antigos. A limpeza guarda cliente e UUID da instância
original, portanto mudar o endereço não envia cancelamento ao novo servidor.
A sessão faz limpeza explícita; descartar a sessão ou abortar a criação também
inicia uma limpeza limitada a seis segundos. Essa tarefa só interrompe/remove a
busca própria e não faz polling ou retries permanentes. Se a limpeza explícita
não puder ser confirmada, a tela informa isso; a pesquisa no daemon também possui
prazo próprio. Retorno vazio não é tratado como inexistência de arquivos na rede.

Falhas de autenticação, configuração, indisponibilidade, resposta incompatível,
limite de requisições e timeout são distintas. Resultados parciais já recebidos
continuam inspecionáveis após falha. Não se atribui automaticamente a causa do
timeout à rede: firewall, daemon e peers podem impedir respostas. Na rede de
trabalho informada pelo usuário, os testes não dependem de acesso real ao Soulseek.

## Validação

Um servidor HTTP local simula respostas progressivas, metadados incompletos,
múltiplos discos, duplicatas, anexos, arquivos bloqueados, erros 401/403/429/503,
resposta incompatível e transporte sem resposta. Testes verificam cancelamento,
substituição, isolamento entre configurações, persistência da configuração com
segredo separado, ausência de correspondência enganosa e preservação de parciais.
Os testes macOS cobrem abrir sem pesquisar, filtros sem consultas, inspeção,
progresso, timeout e descarte de resposta tardia. Um teste Swift/UniFFI verifica
que a pesquisa desativada não altera biblioteca nem playback.

A prova externa anterior e seu reteste são registros históricos, não resultados
produzidos por esta implementação. Esta etapa não afirma conectividade atual
na rede do trabalho nem valida transferências reais.

Contrato consultado: [controller de buscas slskd](https://github.com/slskd/slskd/blob/master/src/slskd/Search/API/Controllers/SearchesController.cs),
[campos dos arquivos](https://github.com/slskd/slskd/blob/master/src/slskd/Search/Types/File.cs),
[respostas](https://github.com/slskd/slskd/blob/master/src/slskd/Search/Types/Response.cs)
e [unidade do timeout em 0.26.x](https://github.com/slskd/slskd/issues/1820).

Validação final: **506 testes Rust e 424 testes macOS passaram**; três
smokes Rust e 4 testes macOS externos permaneceram opt-in. Os nove testes
do novo adaptador usam exclusivamente um servidor local simulado. Clippy com
todos os alvos/features, geração Release/bindings e smoke UniFFI passaram.
[Evidência consolidada](../evidence/provider-probes/slskd-search-2026-10-28.json).

## Atualização: transferências

A [etapa 12](soulseek-transfers.md) acrescenta seleção explícita de arquivos,
fila persistente, cancelamento, retomada e importação revisada. Ofertas continuam
temporárias; pesquisar ou selecionar uma pasta não inicia transferência.
