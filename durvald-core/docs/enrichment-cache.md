# Correção do enrichment — 16/09/2026

## Causas e comportamento

- `DurvaldCoreStore.refreshArtistCatalog` solicitava apenas discografia e capas. Agora solicita também `.popularTracks`. `ArtistView` relê as faixas persistidas após atualização/retry.
- `LastFm.artist_info` prioriza o retrato Last.fm, ignora a imagem placeholder `2a96cbd8b46e442fc41c2b86b821562f` e tenta `og:image`/`twitter:image` na página pública quando a API não fornece foto. Páginas bloqueadas ou sem foto têm cache negativo; uma biografia válida continua utilizável. HTTP 429 da página é propagado.
- `LastFm.artist_info` e `LastFm.top_tracks` tentam o nome local quando o MBID retorna erro 7. Faixas vazias por MBID também recebem uma única consulta pelo nome. O parser aceita lista ausente/nula, string vazia e objeto único; MBID de faixa inválido ou nulo não descarta toda a lista.
- `metadata::normalize_remote_artwork` aceita JPEG, PNG, WebP e GIF, decodifica com limites de 10 MiB, 4096 pixels por dimensão e 64 MiB de alocação. WebP/GIF são convertidos para PNG (primeiro quadro). HTML e imagens truncadas são rejeitados.
- `LastFmClient.download_metadata_image` verifica MIME, tamanho, decode e cada redirect; não encaminha credenciais ao CDN. JPEG/PNG permanecem no formato recebido. Uma resposta HTML bloqueada não é tratada como imagem.
- `EnrichmentService.store_lastfm_portrait` reutiliza um arquivo local válido com o mesmo `provider_id`, renova expiração/atribuição e mantém dimensões. Arquivo ausente/corrompido exige novo download. Falhas de SQLite/arquivo são diagnósticos de armazenamento, separados de imagem inválida.

## Persistência e concorrência

`enrichment/cache.rs` mantém representações HTTP em `enrichment-http.sqlite`, na pasta de capas da instância. Os snapshots de domínio continuam no banco da biblioteca, com geração de identidade e acesso offline. Chaves contêm namespace/host e hash do recurso; URLs de requisição e credenciais não são gravadas como chaves. Corpos remotos podem conter os URLs públicos do próprio provedor.

- JSON: 15 minutos, com ETag/Last-Modified e revalidação 304. Respostas Last.fm de MBID desconhecido também são persistidas para evitar repetir o erro antes do fallback.
- Imagens: 30 dias; HTML público sem foto: 24 horas; página com erro: cooldown de 15 minutos por padrão, ou Retry-After numérico entre 60 segundos e 24 horas.
- HTTP negativo no transporte comum: 15 minutos. Cooldown 429/503 com Retry-After é persistido por host; Last.fm também compartilha cooldown em memória entre clientes e registra erro API 29. Force não remove cooldown ativo.
- `EnrichmentService.cached_request` cobre identidade, atualização do artista e detalhes externos de releases, incluindo operações de capas fora de `provider_request`. Contextos são task-local; locks de recurso pertencem à instância e são compartilhados por seus clones. Consultas simultâneas normais rechecam o cache após adquirir o lock. Os coordenadores existentes continuam agrupando pedidos idênticos e cancelando trabalho sem assinantes.
- `clear_provider_data` remove também o cache HTTP do provedor; `clear_provider_failures` remove seu cooldown persistido. Budgets em memória continuam respeitados. A troca da chave Last.fm usa a limpeza já existente do provedor.
- Representações HTTP são limitadas a 256 MiB de payload e 10.000 registros, removendo os mais antigos. Páginas SQLite são reutilizadas; o arquivo físico não é reduzido automaticamente. Essa retenção não apaga snapshots de domínio nem arquivos de imagem publicados.

## Validação e limites

Os testes de transporte usam o mesmo cache de produção com SQLite e relógio real: reabertura, ETag/304, resposta negativa, cooldown mesmo com force e requests simultâneos. Testes de serviço com clientes scripted e relógio pausado não ativam automaticamente o cache HTTP; verificam publicação, geração, cancelamento e snapshots. Isso evita que `spawn_blocking` avance timeouts virtuais. Há regressões para MBID desconhecido persistido, 304 rematerializável, WebP/GIF/truncamento, formatos de faixas e reaproveitamento de retrato sem fixture de download.

A página pública de Casey MQ retornou HTML de bloqueio durante a consulta anterior. O parser foi validado com fixture; **não houve confirmação live da foto de Casey MQ**, nem atualização live de todos os artistas do banco pessoal. Artistas recebem a nova política no próximo refresh permitido; force solicita atualização explícita, respeitando cooldowns.

A dylib pendente do checkout foi preservada. O Xcode foi validado numa cópia em `/tmp/durvald-enrichment-validation`, com a dylib compilada neste trabalho. Nenhum commit ou publicação foi feito.
