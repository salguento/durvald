# Etapa 12 — Transferências e importação de arquivos

> Prova real posterior: [arquivo individual até importação e reimportação após reinício](soulseek-live-acquisition.md), aprovada em 28/10/2026. Cancelamento/lote parcial reais e montagem remota continuam pendentes. O texto abaixo registra a entrega original.

Implementada em 28/10/2026 sobre a pesquisa independente da etapa 11. O Durvald
usa a API de lotes do slskd configurado pelo usuário. Não instala o daemon, não
altera seus compartilhamentos e não usa transferências como origem de streaming.
A validação desta etapa usa um servidor local simulado e áudio WAV real de teste;
a rede Soulseek do trabalho não foi usada como critério de sucesso.

## Fluxo

1. Em **Ajustes → Soulseek → Configurar transferências e pastas…**, informe o
   diretório de downloads concluídos configurado no slskd, sua pasta equivalente
   acessível neste Mac e o destino permanente da biblioteca. Para slskd remoto,
   monte a pasta compartilhada antes da importação. Confirme o mapeamento e
   habilite downloads. Pesquisa e permissão para novos downloads são separadas.
2. Na pesquisa Soulseek, selecione uma pasta e use **Selecionar arquivos para
   download…**. Escolha um arquivo ou um subconjunto, confira os destinos e
   confirme. Selecionar ou inspecionar a oferta, abrir configurações ou abrir a
   fila não inicia um download.
3. A seção **Transferências** da navegação mostra lotes e progresso por arquivo
   e por lote, fila quando informada, falhas e cancelamentos. O slskd recebe um
   destino relativo exclusivo `durvald/<UUID do lote>` sob seu diretório de
   downloads. Arquivos adicionais do peer não são incluídos.
4. Após o sucesso confirmado de um arquivo, use **Localizar arquivo concluído e
   revisar…**. O arquivo deve estar dentro da subpasta desse lote no mapeamento
   local. Um caminho do peer ou do computador remoto nunca é aberto como se fosse
   automaticamente um caminho local. Não há transporte HTTP de arquivo remoto.
5. Confira os metadados lidos do áudio e escolha adicionar uma faixa ou associar
   a uma faixa existente. Confirme a gravação e o destino. O Durvald copia o
   arquivo para uma pasta permanente própria do lote, sem mover ou alterar o
   original. A cópia validada passa a ser origem local normal, independente do
   slskd. Cache de streaming não é importado.

Arquivos selecionáveis para esta importação: MP3, WAV, FLAC e Ogg Vorbis
(`.ogg`/`.oga`), alinhados aos decoders existentes. Outros formatos continuam
inspecionáveis na pesquisa, mas não são baixados por este fluxo de importação.
Extensão, nome, tamanho, correspondência de títulos e conclusão do lote não
comprovam edição, qualidade sem perdas ou um álbum completo. A interface mostra
contagens dos arquivos selecionados, inclusive quando só parte do lote concluiu.

## Persistência, progresso e recuperação

A migração aditiva 24 cria configurações de transferência e um diário de lotes
SQLite. Preferências, destinos, arquivos esperados, tentativas, UUIDs, IDs
observados, progresso e revisões são persistidos; chaves continuam exclusivamente
no armazenamento protegido do runtime. O diário não contém URLs de áudio,
headers ou credenciais. Biblioteca, histórico e preferências existentes não são
recriados. O writer de metadados existente agora pode participar da transação
que confirma a importação e seu recibo.

O registro local é confirmado antes de enviar o lote. O app distingue falha
antes de enviar (por exemplo, consulta inicial ao backend indisponível) de envio
com resultado desconhecido. A primeira pode ser tentada novamente explicitamente.
A segunda só consulta o UUID original: timeout, cancelamento de uma chamada e
reinício não repetem o POST nem criam outro lote às cegas. Se o backend nunca
voltar a apresentar o recibo, o app mantém a incerteza e pede conferência no slskd.
Um diário ainda em `Prepared`, anterior à primeira tentativa de envio, pode ser
retomado explicitamente com o mesmo UUID.

A chave idempotente inclui instância, peer, arquivos/tamanhos e destinos.
Repetir a mesma confirmação retorna o lote existente. Uma seleção diferente com
arquivos já registrados no mesmo destino é recusada, orientando usar a fila.
Até 200 lotes e 500 arquivos por lote são admitidos neste incremento; cada lote
admite até 20 tentativas. A retomada explícita seleciona somente arquivos com
falha ou cancelamento confirmado, conserva os concluídos/importados e usa o
mesmo destino relativo. A retomada de bytes parciais segue o suporte e a política
do próprio slskd; o Durvald não muda essa configuração global.

O protocolo verifica UUID do lote, usuário, destino relativo, nomes, tamanhos,
IDs e estado de cada transferência. Uma transferência já existente fora dos
recibos próprios não é adotada ou substituída. Cancelamento usa apenas IDs
observados em lotes próprios; não há remoção global de downloads. Aceitação de
DELETE registra uma solicitação; o estado terminal é observado na consulta
seguinte. Falha ou prazo de cancelamento deixa uma solicitação pendente salva,
sem anunciar um cancelamento que não foi confirmado. A ação interrompe também
uma importação em andamento antes de confirmar a biblioteca quando possível.
Arquivos já concluídos permanecem revisáveis e importáveis em um lote parcial
cancelado.

A fila é carregada localmente após reinício. Ao abrir/selecionar um lote, a tela
reconcilia seu estado com a mesma instância e consulta a cada três segundos
enquanto houver atividade. Erro de conexão interrompe esse polling até nova
ação ou abertura da tela. Não há submissão ou importação automática no startup.
Concluídos já confirmados continuam importáveis quando registros antigos forem
removidos do slskd ou quando a conexão cair. Um arquivo sem sucesso explícito,
mesmo com todos os bytes informados, não se torna importável.

A configuração da instância é verificada no runtime e comparada à instância do
lote antes de qualquer comando. Alterar o endereço não encaminha suas credenciais
ou cancelamentos ao servidor errado. Pastas são snapshots de cada lote;
configurações novas valem para lotes novos. Para retomar um mapeamento existente,
restabeleça a pasta no caminho registrado. O app não administra montagens remotas.

## Validação e confirmação de arquivos

Antes de oferecer a revisão, o app verifica pasta e arquivo canônicos, contenção
na subpasta do lote, tamanho esperado e formato aceito. Links simbólicos que
escapem do mapeamento são recusados. O áudio é decodificado integralmente sem
criar player ou evento de escuta; cabeçalho inválido, ausência de frames ou áudio
incompleto impedem a importação. Metadados e SHA-256 são obtidos do arquivo real.
A revisão possui token próprio; revisar novamente invalida a confirmação anterior.

A confirmação grava um diário antes da cópia. A cópia temporária usa nome privado
`.part`, verifica tamanho e SHA-256, sincroniza a gravação e publica o destino
sem sobrescrever arquivos existentes. O destino deve suportar essa publicação
atômica por hard link; pastas locais usuais no macOS atendem esse requisito.
Uma cópia existente só é reutilizada se corresponder ao conteúdo revisado. O
áudio e os metadados da cópia são validados novamente antes do commit SQLite.
O arquivo original permanece intacto, inclusive seus tags.

Uma associação a faixa existente adiciona apenas a origem local e seu cache de
metadados técnicos, preservando identidade e metadados pessoais canônicos,
avaliações, favoritos, tags, histórico e ocorrências de playlist. Duração ausente
pode ser preenchida pelo áudio. Preferência de origem não é alterada. Arquivo já
pertencente a outra faixa exige revisão e não é transferido silenciosamente.
Uma nova faixa usa o writer existente e os metadados reais; colisão com uma faixa
já existente pede associação explícita, sem deduplicar apenas por semelhança.

Origem local e recibo `Imported` são confirmados na mesma transação. Cancelamento
antes do commit reverte as alterações de biblioteca. Uma interrupção depois da
cópia e antes do commit deixa uma importação pendente revisável: o app valida e
reutiliza a cópia publicada, mesmo que o original já não esteja disponível.
Repetir a confirmação não cria outra faixa nem outra origem. Revisar novamente
um arquivo que ainda não foi associado permite corrigir uma importação que
falhou, sem sobrescrever conteúdo já existente.

## Verificação e limites

Os testes locais cobrem pesquisa → seleção → lote → conclusão parcial → revisão
→ importação, persistência e reimportação, perda de recibo, falha antes do envio,
retomada explícita, cancelamento, falha parcial, identidades incompatíveis,
transferências de outros clientes, mudança de instância, retenção do backend,
conclusão de bytes sem sucesso, áudio inválido, tamanho/digest divergentes,
colisão no destino e recuperação após interrupção da cópia/commit. Verificam
preservação de valores pessoais e ausência de músicas antes da confirmação.
Testes Swift cobrem restauração, ausência de polling/importação ao carregar a
lista, resposta tardia, cancelamento e mensagens de falha. Um smoke Swift/UniFFI
verifica configurações desativadas e recusa de oferta forjada sem rede.

Não houve transferência real por Soulseek nesta etapa. Conectividade de peers,
política de retomada e comportamento de montagem em um slskd remoto continuam
condicionados ao backend e à rede. O teste local não comprova disponibilidade
atual na rede do trabalho. Distribuição notarizada e acesso persistente a pastas
em um aplicativo com sandbox mantêm os limites de empacotamento anteriores.

Contrato consultado: [API de transferências](https://github.com/slskd/slskd/blob/master/src/slskd/Transfers/API/Controllers/TransfersController.cs),
[destino relativo de lote](https://github.com/slskd/slskd/blob/master/src/slskd/Transfers/API/DTO/EnqueueDownloadBatchRequest.cs)
e [campos de transferência](https://github.com/slskd/slskd/blob/master/src/slskd/Transfers/Types/Transfer.cs).

Validação executada: **519 testes Rust e 428 testes macOS passaram**; três
smokes Rust e quatro macOS externos permaneceram opt-in. Após o último ajuste da
limpeza de temporários, os 13 testes de transferência/importação passaram novamente,
assim como 9 testes macOS de aquisição com a biblioteca Release final,
Clippy com todos os alvos/features e smoke UniFFI. Bindings e biblioteca embutida
foram regenerados em conjunto.
[Evidência consolidada](../evidence/provider-probes/slskd-transfers-2026-10-28.json).
