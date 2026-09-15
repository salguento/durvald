O melhor caminho é **não criar uma segunda infraestrutura de metadata para Last.fm**. O Durvald já tem quase tudo necessário: snapshots por provider, cache/TTL, falhas persistidas, `identity_generation`, publicação serializada no SQLite e diagnóstico por seção. Last.fm deve entrar como mais um provider dentro disso. As tabelas atuais de perfil e assets já aceitam `provider TEXT` sem whitelist SQL, então bio e retrato podem reutilizar a persistência existente.

## Decisões de produto

- MusicBrainz continua sendo a identidade canônica e a fonte da discografia.
- Last.fm será a fonte primária do retrato do artista.
- Wikipedia continua sendo a fonte preferencial da biografia; Last.fm será o fallback.
- Wikidata continua sendo a fonte de fatos estruturados, como nascimento, formação e origem.
- A UI nunca consulta o Last.fm diretamente: rede atualiza o SQLite e a interface lê snapshots locais.
- O ranking global será chamado de **“Mais populares”**; o ranking por `Track.playCount` será chamado de **“Mais ouvidas nesta biblioteca”**.

### Risco conhecido sobre imagens

Por decisão de produto, a imagem retornada por `artist.getInfo` será usada como retrato primário, com atribuição e link visíveis para o Last.fm. O aplicativo está em desenvolvimento sem intenção comercial.

Os termos públicos da API do Last.fm contêm uma restrição específica ao uso de imagens e artworks que não é eliminada apenas pelo caráter não comercial ou pela atribuição. A implementação deve permanecer documentada como risco conhecido. Antes de uma distribuição pública, recomenda-se obter autorização escrita do Last.fm e revalidar os termos vigentes. [Termos da API](https://www.last.fm/api/tos)

Há também duas correções de conceito importantes. Hoje “Mais ouvidas” em `ArtistView` é apenas `Array(visibleTracks.prefix(10))`; não usa `Track.playCount`, embora esse campo já exista no domínio. E o Last.fm oferece duas coisas diferentes: `artist.getTopTracks` retorna as faixas **mais populares daquele artista no Last.fm**, enquanto `user.getTopTracks` retorna as faixas mais ouvidas **pela conta Last.fm do usuário**. Para a tela `ArtistView`, use `artist.getTopTracks(limit=10)` e renomeie a seção para **“Mais populares”**. [Last.fm](https://www.last.fm/api/show/artist.getTopTracks)

### Roteiro recomendado

1. **PR 1 — integrar Last.fm ao framework de enrichment, sem ainda mudar a UI.** Adicione `LastFm` a `EnrichmentProvider` em `src/api/enrichment.rs` e a `"last_fm"` em `policy.rs`. Em vez de duplicar HTTP dentro de `enrichment/providers`, faça `enrichment/providers/lastfm.rs` ser um adaptador sobre o `LastFmClient` que já existe em `src/lastfm.rs`. Hoje `DurvaldCore` já possui simultaneamente `Arc<LastFmClient>` e `EnrichmentService`, mas constrói os dois separadamente; portanto, construa o cliente como `Arc` antes do serviço e injete `lastfm.clone()` em `EnrichmentService::new`. O `LastFmClient` já concentra credenciais, limite de resposta, timeouts e rate limiting, então duplicar um segundo cliente seria regressão arquitetural.

    Para leitura de metadata, **não exija sessão autenticada**: `artist.getInfo` e `artist.getTopTracks` precisam da API key, mas não de autenticação Last.fm. Crie uma operação GET própria para metadata pública e preserve o fluxo POST/assinado existente para autenticação e scrobble. Configure um `User-Agent` identificável com nome e versão do Durvald. Faça o transporte preservar `ETag`, `Last-Modified`, `Cache-Control`, `Expires` e `Retry-After`, quando presentes, para que cache e retry respeitem as instruções do servidor. [Last.fm](https://www.last.fm/api/show/artist.getInfo) [Introdução à API](https://www.last.fm/api/intro)

    **Critérios de aceite:** metadata pública funciona sem conta conectada; o core usa uma única instância do cliente; o `User-Agent` é enviado; limites atuais de resposta e timeout permanecem ativos; cabeçalhos HTTP relevantes chegam à política de cache.

2. **PR 2 — retrato primário e fallback de biografia, em nível de campo.** Implemente no adaptador `artist_info(mbid, language)`. O endpoint aceita diretamente o MusicBrainz ID, retorna bio e referências de imagem; portanto o MBID já confirmado pelo Durvald deve ser sempre a chave principal, sem procurar primeiro pelo nome. [Last.fm](https://www.last.fm/api/show/artist.getInfo) A precedência fica: **override manual > Wikipedia > Last.fm > ausente** para bio; e **Last.fm > Commons > artwork local do álbum > artwork da discografia > ausente** para retrato. Last.fm não deve substituir fatos estruturados de Wikidata como nascimento/origem/formação.

    Aqui há uma mudança importante em `refresh_profile_once()`. Hoje, se MusicBrainz não fornecer relação Wikidata, o método termina em `NotFound`; e, se Wikidata não fornecer `commons_file`, `Portrait` vira `NotFound`. Isso precisa virar fallback por campo: falhar em Wikidata não significa que `Profile` acabou; falhar em Commons não significa que `Portrait` acabou.

    Para a bio, grave normalmente um `ProfileSnapshot { provider: LastFm, ... }`, reutilizando `artist_profile_sources`. Para imagem, escolha a maior variante útil retornada, reutilize `AssetSnapshot`/`enrichment_assets` e grave com `provider = 'last_fm'` e `catalog_key = ''`. Não crie `lastfm_bios` ou `lastfm_images`. Essas abstrações já foram feitas justamente para múltiplos providers.

    A imagem deve passar pelo mesmo pipeline seguro das demais fontes: URL HTTPS, limite de bytes, MIME permitido, dimensões válidas, escrita atômica em diretório gerenciado e remoção apenas quando o arquivo substituído não possuir outra referência. Uma URL HTTP, imagem ausente ou payload inválido deve acionar o fallback para Commons sem remover um retrato Last.fm válido já armazenado.

    Há ainda um ajuste obrigatório em `database/enrichment.rs`: `read_artist_details()` hoje seleciona o portrait explicitamente com `provider = 'commons'`. Isso precisa passar a escolher por precedência — Last.fm primeiro, Commons depois. No Swift, `biographySource` também está hardcoded para `.wikipedia`, e o texto da fonte é literalmente `"Fonte: Wikipedia"`; altere-o para escolher a melhor fonte disponível e usar seu provider/attribution.

    **Critérios de aceite:** retrato Last.fm válido prevalece sobre Commons; imagem inválida cai para Commons; falha remota preserva o asset publicado; Wikipedia prevalece na bio; Last.fm pode fornecer bio mesmo sem QID Wikidata; fonte e link exibidos correspondem ao provider efetivo.

3. **PR 3 — introduzir “PopularTracks” como uma seção própria do enrichment.** Não coloque essas informações dentro de `Profile`, porque possuem TTL, UI, modelo e semântica diferentes. Em `api/enrichment.rs`, acrescente `ArtistRefreshSection::PopularTracks` e algo como `ArtistPopularTrack { rank, title, musicbrainz_id, play_count, listeners, lastfm_url, local_track_id }` e `ArtistPopularTracks { artist_id, identity_generation, items, fetched_at, expires_at, stale }`. O endpoint suporta MBID e `limit=10`, então a chamada fica pequena e determinística. [Last.fm](https://www.last.fm/api/show/artist.getTopTracks)

    Adicione a migration **v16** para um snapshot `artist_popular_tracks`, pois a v15 já pertence ao cache de detalhes de releases externas. Armazene **um payload JSON por artista/provider/generation**, não dez linhas independentes: essa lista é um ranking atômico e deve mudar inteira. Algo conceitualmente equivalente a `(artist_id, provider, identity_generation, payload_version, payload, fetched_at, expires_at)` é suficiente. Inclua índice de expiração e invalidação quando mudar `identity_generation`.

    Respeite primeiro os cabeçalhos HTTP de cache; na ausência deles, use **24 horas para popular tracks**, versus os 30 dias atuais de perfil. Não faça chamada quando `ArtistView` abre se o snapshot ainda estiver fresco. Expiração deve marcar o snapshot como `stale`, não apagá-lo. A própria documentação do Last.fm pede uso razoável e desencoraja chamadas contínuas em carregamento de página. [Last.fm](https://www.last.fm/api/intro)

    **Critérios de aceite:** a leitura é exclusivamente local; snapshot fresco evita uma nova chamada; modo offline preserva o ranking; troca de identidade durante a chamada descarta o resultado; a lista só é publicada integralmente.

4. **PR 4 — matching com a biblioteca e correção da seção “Mais ouvidas”.** Não transforme uma faixa Last.fm diretamente em `Track`: `Track` representa arquivo local tocável. O ranking externo deve ter `local_track_id: Option<i64>`. Primeiro tente MusicBrainz recording/track ID se futuramente estiver disponível de forma confiável; no estado atual, faça matching conservador dentro do artista já confirmado: título normalizado exato e, se necessário, versão muito limitada de remoção de pontuação/case. Evite fuzzy matching agressivo de `"Radio Edit"`, `"Remaster"`, `"feat."`, etc., porque ele facilmente associa gravações erradas.

    Na UI, para cada item popular que tenha `local_track_id`, use o `Track` local e permita playback. Para os que não existirem localmente, você pode mostrá-los como informação externa não tocável ou omiti-los no primeiro release.

    E tenha um fallback útil: sem Last.fm, faça realmente `tracks.sorted { $0.playCount > $1.playCount }.prefix(10)`. Isso corrige imediatamente a semântica atual e funciona offline. Exiba **“Mais populares”** quando houver ranking Last.fm e **“Mais ouvidas nesta biblioteca”** quando o fallback local estiver ativo. Não permita que pesquisa ou ordenação da listagem geral alterem qualquer um desses rankings.

    **Critérios de aceite:** apenas correspondências locais são reproduzíveis; faixa externa não entra na fila; matching duvidoso permanece sem `local_track_id`; elementos textuais de itens externos usam cor secundária; pesquisa e ordenação não modificam o ranking.

5. **PR 5 — erros, cache, retenção e diagnóstico.** Faça todas as chamadas passarem pelo `provider_request()` já existente, usando `EnrichmentProvider::LastFm`, para ganhar automaticamente cache de falha por provider/operação, `force`, `identity_generation` e invalidação. Mapeie erros Last.fm `10/26` para configuração/permanente, `11/16` para indisponibilidade temporária e `29` para rate limit. Respeite `Retry-After` quando fornecido e adicione um diagnóstico estável de provider não configurado, sem confundir API key ausente com sessão de usuário desconectada. A documentação atual enumera explicitamente esses códigos. [Last.fm](https://www.last.fm/api/show/artist.getTopTracks)

    Mantenha o limiter global existente inicialmente. Ele é conservador; a documentação oficial não determina “1 req/s” como regra rígida, mas pede que clientes não façam várias chamadas contínuas por segundo e usem `User-Agent` identificável. [Last.fm](https://www.last.fm/api/intro) Muito mais importante é não criar retries ou refreshes disparados pelo SwiftUI a cada recomposição.

    Para imagens, **não reduza as garantias do roteiro atual** para acomodar Last.fm. Aceite apenas URL HTTPS, aplique os mesmos limites de bytes/MIME/dimensões e escrita gerenciada usados por Commons. A própria amostra oficial ainda mostra URLs de imagem `http://...`; se a resposta real vier apenas assim, trate a imagem como indisponível em vez de permitir HTTP. [Last.fm](https://www.last.fm/api/show/artist.getInfo)

    Limite a retenção total dos snapshots Last.fm e exponha uma operação de limpeza por provider. Ao remover as credenciais ou encerrar a integração, apague perfis, rankings e assets Last.fm sem afetar MusicBrainz, Wikidata, Wikipedia ou Commons.

    **Critérios de aceite:** falha temporária preserva cache; erro permanente não entra em retry contínuo; diagnósticos identificam o provider; limpeza remove somente dados Last.fm; a UI continua funcional offline.

6. **PR 6 — testes e cliente macOS.** No Rust, cubra: `artist.getInfo` com/sem bio e imagem; seleção da maior imagem; rejeição de HTTP/MIME/dimensões inválidas; Last.fm válido prevalecendo sobre Commons; fallback para Commons; `artist.getTopTracks` com menos de dez resultados, MBIDs vazios, números em string e payload malformado; Wikidata ausente + Last.fm bio presente; Wikipedia existente sem substituição pela bio Last.fm; erros `10`, `11`, `16`, `26` e `29`; offline mantendo cache; revalidação condicional; troca de `identity_generation` durante a chamada; publicação atômica e limpeza do provider. Depois regenere UniFFI. No Swift, teste retrato Last.fm → Commons → artwork local, biografia override → Wikipedia → Last.fm e `PopularTracks` Last.fm → ranking local → vazio. O diagnóstico por seção já existe no projeto e deve apenas ganhar `PopularTracks`, sem criar outro sistema de estado.


A arquitetura final ficaria, portanto:

**MusicBrainz = identidade canônica + discografia → Last.fm = retrato primário, biografia complementar e popularidade → Wikidata/Wikipedia/Commons = fatos, biografia preferencial e fallbacks → SQLite = fonte lida pela UI.**

Eu não faria Last.fm disputar identidade com MusicBrainz. O ganho mais importante de já possuir MBID confirmado é justamente poder chamar `artist.getInfo` e `artist.getTopTracks` por MBID e evitar homônimos. E não faria `ArtistView` consumir Last.fm diretamente: ela deve continuar lendo exclusivamente os DTOs/cache do core.

Para esse caso específico, a ordem de execução é **PR 1 → PR 2 → PR 3 → PR 4 → PR 5 → PR 6**. O transporte e a política de cache precisam estar corretos antes de publicar retrato ou biografia; o snapshot de faixas precisa existir antes da UI; diagnósticos, retenção, testes e bindings fecham a integração. A maior armadilha seria colocar métodos novos diretamente em `ArtistView` ou criar um `LastFMViewModel` paralelo ao enrichment — o projeto já tem abstrações melhores para isso.
