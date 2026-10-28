# Snapshots completos da biblioteca

A migração 21 cria automaticamente `<database_path>.pre-local-sources.sqlite` antes de alterar uma biblioteca existente. O snapshot usa a API de backup do SQLite, inclui gravações confirmadas no WAL e não substitui um backup anterior. Se a criação falhar, a abertura da biblioteca é interrompida antes da atualização.

Para exportar uma biblioteca completa, sem rede:

```sh
python3 tools/library-snapshots/snapshot.py export /caminho/library.sqlite /caminho/backup.sqlite
```

Para restaurar em um **novo arquivo**:

```sh
python3 tools/library-snapshots/snapshot.py restore /caminho/backup.sqlite /caminho/restored.sqlite
```

Os comandos incluem todas as tabelas, índices e gatilhos: músicas, origens, disponibilidade, metadados, preferências, arquivos ausentes, avaliações, favoritos, histórico e posições repetidas em playlists. A mídia e as capas externas ao banco não são copiadas. O destino deve ser novo; os comandos nunca sobrescrevem uma biblioteca aberta ou existente. Para usar a restauração no aplicativo, feche o aplicativo e configure o banco restaurado como `database_path`. Um backup anterior à migração será atualizado na próxima abertura pelo core.

A exportação lê um snapshot consistente mesmo com WAL ativo. A restauração passa pelas verificações de integridade e relacionamentos antes de publicar o destino. Nenhuma credencial ou serviço externo é necessário.

Verificações:

```sh
python3 -m unittest discover -s tools/library-snapshots -p 'test_*.py'
```
