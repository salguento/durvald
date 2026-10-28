# Etapa 7 — Catálogo e fila sem arquivo local obrigatório

A migração 22 permite `songs.file_path = NULL`; o valor vazio continua inválido. A faixa mantém sua identidade e seus dados pessoais independentemente das origens disponíveis. A coluna legada permanece como espelho opcional da origem local escolhida, para compatibilidade dos consumidores durante a transição.

## Banco e recuperação

A migração reconstrói `songs`, `track_sources` e o diário de edição de metadados em uma única transação. Preserva IDs, sequências de origens, relacionamentos, índices e gatilhos; verifica FKs antes do commit e restaura o modo de fiscalização mesmo se falhar. FKs são desabilitadas apenas na conexão responsável pela reconstrução, fora da transação, para evitar cascatas ao substituir tabelas.

Bibliotecas que já estavam na versão 21 ganham `<database_path>.pre-optional-local-files.sqlite` antes da migração. Bibliotecas anteriores usam o backup pré-origens da etapa 6, que antecede ambas as mudanças. A API de backup SQLite inclui WAL e valida o snapshot. A abertura é interrompida se não puder criar ou validar o backup.

**Não abra o banco migrado em builds antigos.** Eles desconhecem os novos DTOs, estados sem arquivo e gatilhos. Para voltar, feche o aplicativo e restaure o backup pré-migração em outro arquivo, usando o [utilitário de snapshots](../../tools/library-snapshots/README.md).

## Identidades e origens

`save_remote_track(CatalogEntry)` é uma ação explícita de adoção. A busca e os bookmarks anteriores continuam sem criar músicas implicitamente. O vínculo é idempotente por provedor, tipo e ID externo em `catalog_track_references`.

Uma gravação do MusicBrainz pode ser salva sem qualquer origem de áudio: a página de uma gravação não comprova mídia reproduzível. Entradas de áudio/vídeo com URL canônica podem criar uma origem remota, inicialmente `unknown`. As referências são validadas antes da escrita, e a transação não associa artistas homônimos por nome. Um crédito sem identidade externa confirmada mantém um artista provisório; não cria uma associação de perfil por suposição.

Origens locais têm caminho normalizado único; origens remotas têm chave única `(provider, external_id)`, sem caminho fictício. Preferências continuam restritas às origens da própria faixa. Inserções, alterações e exclusões de origens atualizam o espelho legado na mesma transação. Excluir uma origem não exclui a faixa; estados, metadados e preferências dessa origem são removidos por FK.

## Scanner, reparo e metadados

O scanner encontra a faixa pela origem local e mantém versão/mtime por origem. Arquivos secundários atualizam seus próprios metadados sem substituir os metadados canônicos da faixa. A atualização de metadados canônicos também respeita sua versão, independentemente do cache por origem.

Quando um arquivo desaparece e há outra origem, só a origem desaparecida é removida. Isso vale para origens remotas desabilitadas ou sem conectividade; ausência de rede não comprova ausência de arquivo. Se o último arquivo de uma faixa exclusivamente local desaparece, permanece o fluxo de arquivamento/recuperação de dados pessoais da biblioteca. A proteção existente contra scans vazios que apagariam uma biblioteca continua ativa.

Faixas sem origem local não participam da análise de arquivos quebrados nem do cálculo de tamanho em disco. Busca, páginas, playlists, filtros e estatísticas de catálogo continuam incluindo essas faixas. Edições e desfazer apenas no banco funcionam sem arquivo; tentar gravar tags em arquivo ausente retorna erro explícito. No macOS, faixas sem arquivo usam edição apenas na biblioteca, inclusive em lotes.

## Fila e reprodução

A fila recebe IDs de catálogo e um identificador opaco próprio por ocorrência (`QueueItem.occurrence_id`). Duas inserções da mesma música têm IDs distintos. Reordenação, shuffle, navegação, contexto de coleção e reinício preservam esses IDs e as duplicatas.

A sessão persiste IDs, contextos e coleção na versão 3 do envelope, sem caminhos de áudio. Sessões antigas em texto simples e versões 1/2 continuam legíveis; ocorrências antigas recebem novos IDs uma vez ao serem restauradas. A coluna de contexto conserva seu contrato opaco.

O core consulta as origens habilitadas apenas para a faixa selecionada ou a próxima transição, considerando preferência e prioridade. A preparação pode tentar outra origem local da mesma faixa se a anterior falhar. Carregar a fila ou restaurar a sessão não abre todos os arquivos nem resolve mídia remota. Um relink posterior à inserção na fila é respeitado quando a ocorrência começa a tocar.

Uma faixa remota pode entrar na fila mesmo quando ela está vazia, sem iniciar streaming. Até a etapa 9, a tentativa de reprodução sem áudio local retorna erro e preserva a fila e a reprodução anterior; não resolve URLs de stream nem descarta a ocorrência automaticamente.

## API e clientes

- `Track.file_path` é `Option<String>` no Rust e `String?` no Swift. Extração explícita de metadados de um arquivo continua exigindo um caminho real.
- `QueueItem.occurrence_id` identifica a inserção; `position` continua sendo a posição atual para comandos de navegação.
- `DurvaldCore.save_remote_track` salva a seleção no catálogo local sem exigir um arquivo.
- Bindings Swift e biblioteca nativa são regenerados juntos. O macOS ignora caminhos ausentes em operações de arquivo e tamanho, apresenta “Sem arquivo local” nos detalhes e não fabrica nomes de arquivo. Exportação M3U8 registra essas faixas como comentários informativos, sem inventar uma URL de mídia.
- O cliente GTK atual conta todo o catálogo pela API pública, sem depender de `file_path`. A documentação do cliente descreve o campo opcional e o novo fluxo; a verificação de compilação neste ambiente depende de pacotes ausentes do cache offline.

## Validação

Testes cobrem reconstrução e rollback com FKs, índices e gatilhos; backup da versão 21; origem secundária sobrevivente; faixa remota preservada por scan/reparo/reinício; playlists com duplicatas; edição/desfazer sem arquivo; ausência de associação de artista por nome; fila com origens remotas e duplicatas; reordenação e restauração dos IDs de ocorrência; e relink após enfileirar. A suíte existente continua cobrindo reprodução local, gapless, coleções, histórico e regras de playlists.
