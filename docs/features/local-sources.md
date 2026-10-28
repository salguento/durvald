# Etapa 6 — Migração aditiva das origens locais

Implementada em 27/10/2026. A migração versionada 21 cria `track_sources`, `track_source_state`, `track_source_metadata` e `playback_source_preferences`. Cada música existente ganha uma origem `local`, habilitada, principal e com disponibilidade `unknown`. A migração não acessa serviços nem verifica a existência dos arquivos: volumes desconectados continuam válidos.

## Identidade e compatibilidade

`song_id`, dados pessoais e relacionamentos permanecem intactos; não há reconstrução de `songs`. `songs.file_path` continua obrigatório e usado pelos leitores atuais. As origens têm IDs próprios que não são reutilizados, proveniência, prioridade e datas. A preferência de reprodução só pode apontar para uma origem da mesma música e é removida quando sua origem desaparece.

A chave local exige caminho absoluto e preserva caixa, Unicode e segmentos `..` (que podem atravessar symlinks). Apenas separadores repetidos e segmentos `.` são normalizados, sem acesso ao sistema de arquivos. Antes das restrições de unicidade, a migração verifica colisões e informa os IDs conflitantes; não mescla músicas automaticamente. Caminhos legados relativos também interrompem a migração com o ID correspondente. A transação reverte alterações de esquema, backfill e versão em qualquer falha; uma nova abertura não duplica origens.

## Escrita e reparo

Gatilhos SQLite fazem a escrita conjunta de origem e coluna legada na mesma transação de importação/scanner. Alterar `songs.file_path` mantém o ID da origem, atualiza sua chave e invalida o estado de disponibilidade; conflitos desfazem a alteração inteira. Atualizações de qualidade mantêm os metadados da origem principal alinhados. A função determinística usada pelos gatilhos é instalada em cada conexão do pool. A origem principal não pode ser apagada isoladamente nem receber um caminho divergente por escrita direta.

No reparo de duplicatas, os arquivos do doador passam a ser origens secundárias da música sobrevivente. Ao arquivar uma faixa ausente, `missing_track_sources` preserva suas origens e metadados; o relink os restaura como candidatos secundários, inicialmente `unknown`. Um caminho já pertencente a outra música impede a restauração e reverte o reparo. Excluir músicas remove suas origens, estados, metadados e preferências por FKs; excluir registros de ausentes remove os registros auxiliares correspondentes.

## Backup e recuperação

Antes de atualizar uma biblioteca existente, a abertura do core cria `<database_path>.pre-local-sources.sqlite` pela API de backup SQLite, incluindo páginas confirmadas no WAL. O arquivo é publicado atomicamente, sem sobrescrever tentativas anteriores. Um backup existente é validado; falha na criação/validação interrompe a abertura antes de atualizar a biblioteca. Bibliotecas novas não precisam desse backup.

[Exportação e restauração completas, sem rede](../../tools/library-snapshots/README.md) usam snapshots SQLite e incluem as origens. A restauração sempre cria um arquivo novo, com verificação de integridade e relacionamentos. Feche o aplicativo antes de selecionar o banco restaurado. Não reabra o banco migrado com builds antigos, que não instalam a função dos novos gatilhos; para voltar a um build antigo, use o backup anterior à migração.

A etapa 7 continuará a transição dos leitores e da fila. Esta etapa não permite músicas exclusivamente remotas nem altera a interface pública.

## Validação

Os testes cobrem preservação de IDs, avaliações, favoritos, histórico e posições repetidas em playlists; idempotência; rollback em colisões; escrita conjunta e unicidade; propriedade de preferências; exclusão em cascata; reparo de duplicatas e ausentes; e backup com WAL/restauração. O utilitário de snapshots também verifica ida e volta de tabelas e rejeição de destinos existentes ou entradas inválidas.
