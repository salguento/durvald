# Roteiro — persistência de artistas similares e homônimos

## Objetivo

Transformar artistas descobertos por similaridade, busca remota ou futura
aquisição em entidades navegáveis persistentes, mesmo sem arquivos locais. O
nome e os demais metadados pertencem ao catálogo; arquivos locais, resultados
Soulseek e streams são fontes opcionais associadas posteriormente.

Toda relação de similaridade deve registrar simultaneamente:

- o artista de origem;
- o `artist_id` interno do artista relacionado;
- a identidade externa usada para materializá-lo;
- o provedor, a pontuação e a validade da descoberta.

Nome nunca é identidade e nunca pode unir automaticamente dois artistas.

## Decisão de escopo

A persistência e a navegação de artistas similares abrangem as etapas 1–7 e a
remoção do armazenamento JSON legado da etapa 9. Fontes Soulseek e streaming
não fazem parte desta entrega: serão introduzidas futuramente por features
dedicadas, sem alterar a identidade textual já persistida no catálogo.

## Estado atual

- `artists` contém os artistas criados pelo scan da biblioteca local.
- `artist_enrichment_state` associa identidade MusicBrainz aos IDs locais.
- `artist_external_ids` guarda IDs adicionais por provedor.
- a migração 17 guarda artistas similares como JSON nas colunas
  `artists.similar_artists*`;
- `SimilarArtist` possui nome, MBID opcional, URL Last.fm e score, mas não possui
  `artist_id` persistente nem retrato;
- o cliente macOS encontra artistas similares locais comparando nomes e abre o
  Last.fm quando não encontra correspondência.

Esse modelo não permite navegar um artista externo dentro do Durvald e pode
associar homônimos incorretamente.

## Modelo proposto

### Entidade canônica

Manter `artists.artist_id` como chave interna opaca e ampliar `artists` com:

```sql
catalog_origin TEXT NOT NULL
    CHECK (catalog_origin IN ('local_scan', 'similar_artist', 'remote_search', 'manual')),
created_at INTEGER NOT NULL,
updated_at INTEGER NOT NULL
```

`name` continua sendo texto de apresentação, não chave única. Um artista pode
existir sem músicas ou releases locais.

Adicionar unicidade efetiva às identidades externas:

```sql
CREATE UNIQUE INDEX idx_artist_external_identity
ON artist_external_ids(provider, external_id);
```

Para MusicBrainz, `external_id` é o MBID normalizado. Para Last.fm, usar um ID
canônico fornecido pelo serviço; enquanto ele não existir, usar a URL canônica
normalizada como identidade provisória. Nunca usar apenas o nome.

### Relação de similaridade

Substituir o JSON por uma tabela normalizada:

```sql
CREATE TABLE artist_similarities (
    source_artist_id INTEGER NOT NULL REFERENCES artists(artist_id) ON DELETE CASCADE,
    target_artist_id INTEGER NOT NULL REFERENCES artists(artist_id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    target_identity_provider TEXT NOT NULL,
    target_identity_value TEXT NOT NULL,
    source_identity_generation INTEGER NOT NULL CHECK (source_identity_generation >= 0),
    match_score REAL NOT NULL CHECK (match_score BETWEEN 0.0 AND 1.0),
    fetched_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at >= fetched_at),
    PRIMARY KEY (source_artist_id, target_artist_id, provider),
    UNIQUE (source_artist_id, provider, target_identity_provider, target_identity_value),
    CHECK (source_artist_id != target_artist_id)
);
```

`target_artist_id` é a identidade interna estável. O par
`target_identity_provider/target_identity_value` registra a identidade externa
que justificou a associação e permite auditoria, revalidação e migração. Esses
campos não substituem `artist_external_ids`: ambos devem ser gravados na mesma
transação.

### Disponibilidade

Não inferir “artista local” pela existência da linha em `artists`. Consultas de
biblioteca devem usar a existência de uma fonte reproduzível:

```text
artista de catálogo -> releases/faixas textuais -> media_sources
                                              ├─ local_file
                                              ├─ soulseek_candidate
                                              └─ stream
```

Até a introdução de `media_sources`, a compatibilidade pode usar `EXISTS` em
`song_artists`/`songs` para decidir se o artista pertence à biblioteca local.

## Diferenciação de homônimos

### Regras obrigatórias

1. MBIDs iguais representam a mesma entidade; MBIDs diferentes representam
   entidades diferentes, ainda que os nomes sejam idênticos.
2. Um ID canônico do mesmo provedor pode localizar uma entidade existente.
3. Nome, caixa, acentos ou similaridade textual nunca autorizam merge.
4. Um resultado sem identidade externa confiável cria uma entidade provisória
   própria, vinculada à URL/ID do provedor que a descobriu.
5. Entidades provisórias de provedores diferentes não são unidas
   automaticamente por nome.
6. Ao descobrir posteriormente um MBID, executar reconciliação transacional;
   não trocar silenciosamente a identidade de uma entidade já confirmada.

### Estados de identidade

Reutilizar `artist_enrichment_state.identity_status` e acrescentar uma origem
explícita da identidade:

```text
provisional_provider — possui apenas identidade Last.fm/provedor
unresolved            — aguarda candidatos MusicBrainz
ambiguous             — há mais de um candidato plausível
resolved              — possui MBID canônico
confirmed             — MBID confirmado manualmente pelo usuário
```

Se alterar o enum persistido existente for arriscado, `confirmed` permanece
representado por `confirmed_musicbrainz_id`, e `provisional_provider` pode ser
uma coluna separada de estágio. A API deve expor essa distinção sem interpretar
`name` como resolução.

### Reconciliação e merge

Quando uma entidade provisória recebe um MBID já pertencente a outro artista:

1. iniciar transação `IMMEDIATE`;
2. escolher como sobrevivente a entidade confirmada ou, na ausência dela, a
   que possui fontes locais;
3. redirecionar similaridades, IDs externos, assets, perfis, overrides,
   discografia e futuras fontes de mídia;
4. deduplicar relações pelo par de IDs externos, preservando maior score e
   `fetched_at` mais recente;
5. manter o nome anterior como alias;
6. remover a entidade provisória somente após validar todas as referências;
7. incrementar a geração de identidade e invalidar caches incompatíveis.

Conflitos entre dois MBIDs confirmados nunca são mesclados automaticamente.

## Etapas de implementação

### 1. Migração e invariantes

- criar migração 18 para `artist_similarities` e origem de catálogo;
- criar índice único de identidade externa;
- permitir artistas sem músicas e sem releases;
- manter temporariamente as colunas JSON da migração 17 para rollback e leitura
  compatível;
- adicionar testes de banco novo, banco migrado e rollback integral.

Critério: dois artistas com o mesmo nome e MBIDs distintos sobrevivem à
migração como linhas distintas.

### 2. Upsert por identidade

Criar uma operação transacional:

```text
upsert_discovered_artist(name, provider, external_id, optional_mbid, origin)
    -> artist_id
```

Ordem de resolução:

1. MBID normalizado;
2. `(provider, external_id)`;
3. criar nova entidade provisória.

O nome só atualiza a apresentação da entidade localizada por identidade. Ele
nunca participa da seleção da linha.

Critério: chamadas repetidas são idempotentes; homônimos sem identidade igual
continuam separados.

### 3. Publicação atômica das similaridades

- normalizar a resposta Last.fm antes de abrir a transação;
- para cada resultado, fazer upsert da entidade e de seus IDs externos;
- gravar `artist_similarities` com a mesma identidade externa;
- substituir o snapshot da origem de forma atômica e subordinada à geração;
- preservar o snapshot anterior em falha parcial, timeout ou cancelamento;
- limitar o lote aos 20 resultados já adotados.

Critério: nunca existe relação apontando para artista sem a identidade que a
originou.

### 4. API de catálogo

Alterar `SimilarArtist` para expor:

```text
artist_id
name
identity_status
musicbrainz_id opcional
discovery_provider
discovery_external_id
lastfm_url
match_score
portrait opcional
has_playable_sources
```

Adicionar lookup de artista externo por `artist_id`; manter os endpoints atuais
durante uma janela de compatibilidade.

Critério: o frontend navega por ID, nunca por nome.

### 5. Retratos sob demanda

- ao tornar um card similar visível, solicitar apenas perfil mínimo/retrato;
- reutilizar `enrichment_assets` e a política Last.fm → Commons → artwork;
- limitar concorrência e evitar discografia/capas completas para cards;
- persistir resultados negativos com TTL;
- retornar o caminho gerenciado no DTO do card.

Critério: similares externos exibem retratos persistidos e continuam visíveis
offline depois de materializados.

### 6. Navegação macOS

- remover `localArtist(for:)` baseado em nome;
- abrir sempre o artista persistido por `artist_id`;
- indicar visualmente “não está na biblioteca” quando não houver fonte local;
- manter o link do Last.fm como fonte, não como única navegação;
- carregar retratos apenas para cards visíveis.

### 7. Busca remota futura

- fazer resultados de busca passarem pelo mesmo `upsert_discovered_artist`;
- persistir apenas ao abrir/selecionar um resultado, ou conforme política de
  retenção explícita, evitando poluir o catálogo com toda resposta de busca;
- usar a mesma solução de homônimos e a mesma página de artista.

### 8. Fontes Soulseek e streaming

- introduzir entidades textuais de release/faixa separadas das fontes;
- adicionar `media_sources` sem alterar identidade textual;
- resultados Soulseek permanecem candidatos até escolha/download;
- arquivo concluído cria fonte `local_file` e passa a incluir o artista nas
  consultas da biblioteca;
- remoção do arquivo remove a fonte, não o artista nem seus metadados.

### 9. Remoção do legado JSON

- fazer leitura paralela e comparar resultados durante uma versão;
- parar de escrever `artists.similar_artists*` após validação;
- migrar snapshots válidos que possuam identidade externa;
- não materializar automaticamente entradas legadas identificadas apenas por
  nome;
- remover as colunas somente em migração posterior compatível com a política de
  suporte do banco.

## Testes essenciais

- dois homônimos com MBIDs distintos;
- mesmo MBID retornado por duas origens converge para um único `artist_id`;
- mesmo nome sem IDs cria provisórios distintos por identidade de provedor;
- repetição do refresh é idempotente;
- mudança de geração não publica snapshot obsoleto;
- falha no meio do lote preserva snapshot anterior;
- merge redireciona todas as FKs sem perder assets ou fontes;
- artista externo não aparece na biblioteca antes de possuir fonte local;
- artista externo é navegável e exibe retrato offline;
- download futuro adiciona disponibilidade sem duplicar artista/release/faixa.

## Ordem recomendada dos commits

1. `feat(core): add canonical similar artist relations`
2. `feat(core): upsert discovered artists by external identity`
3. `feat(core): persist similar artist snapshots atomically`
4. `feat(core): expose navigable discovered artists`
5. `feat(macos): navigate and render remote similar artists`
6. `refactor(core): remove legacy similar artist JSON storage`

Cada commit deve preservar leitura de bancos existentes e evitar iniciar rede
durante abertura, scan ou reprodução.
