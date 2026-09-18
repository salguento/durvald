Pelo estado atual do `main`, há alguns pontos concretos que podem explicar aumento de CPU após a entrada do enrichment/MusicBrainz. Eu priorizaria assim:

1. **Refresh automático sempre que `ArtistView` aparece — alta probabilidade.** A `ArtistView` termina o `.task(id: artist.id)` chamando `await refreshEnrichment()`. Esse método dispara em paralelo `refreshArtistDetailsWithResult` e `refreshArtistCatalog`. Portanto, navegar entre artistas, reconstruir a view ou voltar para ela pode iniciar bastante trabalho de enrichment, mesmo que visualmente o usuário só esteja abrindo a tela.  
    O `refreshArtistCatalog` inclui `.discography` e `.covers`; portanto, uma entrada na tela pode produzir leitura de SQLite, decisão de cache, chamadas remotas, parsing JSON, persistência e eventualmente processamento de imagens.  
    **Teste:** comentar temporariamente `await refreshEnrichment()` no `.task`. Se o CPU cair imediatamente, este é o principal gatilho.
    
2. **Uma atualização de discografia pode gerar até 10 requests MusicBrainz consecutivos. — alta probabilidade durante refresh.** `MusicBrainz::discography_with_limits` executa:  
    `while pages.len() < max_pages && !remote_exhausted`, com `MAX_DISCOGRAPHY_PAGES_PER_REFRESH = 10`, páginas de 100 itens e orçamento de 20 s. Isso significa até **1.000 release groups processados em uma única atualização de um artista**.  
    Há inclusive teste no service que confirma um primeiro refresh fazendo **10 chamadas** antes de retornar `Partial`, seguido de outra chamada no refresh seguinte.  
    A espera de 1 request/s reduz tráfego, mas não necessariamente o trabalho local entre requests: serde, normalização, `HashSet`, SQLite e atualização dos snapshots continuam ocorrendo.
    
3. **Refresh de catálogo parcial pode ser reexecutado ao revisitar a tela. — alta probabilidade em discografias grandes.** Quando as 10 páginas não esgotam o catálogo, o resultado fica parcial e guarda `remote_next_offset`. O próximo refresh continua dali. Isso é correto funcionalmente, mas combinado com o refresh automático de `ArtistView` transforma a navegação em uma espécie de mecanismo de continuação da importação.  
    Assim, um artista com milhares de release groups pode gerar lotes repetidos sempre que a tela reaparece, até finalizar.
    
4. **Fan-out de operações simultâneas ao abrir um artista. — média/alta.** Primeiro a view dispara simultaneamente tracks, albums, identity, details e discography locais. Logo depois dispara simultaneamente profile/portrait e discography/covers remotos.  
    Não é um loop infinito, mas forma um pico significativo de tarefas, `spawn_blocking`, queries SQLite, parsing e publicação de estado. Em uma máquina pequena, isso pode aparecer facilmente como 10–20% de CPU sustentado durante alguns segundos ou enquanto vários lotes continuam.
    
5. **Muitas transações/jobs SQLite pequenos durante uma única sincronização. — média/alta.** O enrichment encaminha operações de DB por `tokio::task::spawn_blocking`; as escritas ainda passam por um mutex global `write_coordinator`.  
    A discografia publica páginas individualmente:
    
    ```
    for page in value.pages {
        ...
        write_database_idempotent(...)
    }
    ```
    
    e outras etapas limpam/storeiam failures, revalidam snapshots, gravam artwork etc. Isso pode gerar muitas aquisições de conexão, context switches e commits pequenos.  
    Eu mediria especialmente `spawn_blocking`/SQLite antes de culpar o HTTP propriamente dito.
    
6. **MusicBrainz identity search pode fazer 1 + até 3 requests por busca. — média.** A busca inicial faz `/ws/2/artist/`; depois, para até três candidatos, executa outra chamada `/ws/2/release-group/` para comparar títulos locais. Logo, uma resolução de identidade pode representar até quatro requests MB e várias comparações de strings.  
    Além disso, para cada `local_release`, cada grupo retornado executa comparação baseada em:
    
    ```
    g.title.to_lowercase() == local.to_lowercase()
    ```
    
    dentro de `.any()`. Ou seja, há alocações `to_lowercase()` repetidas dentro de loops aninhados. Para bibliotecas grandes isso é CPU desperdiçado, embora provavelmente não explique sozinho 20%.
    
7. **Normalização da resposta da discografia faz bastante alocação por item. — média.** Para até 1.000 release groups por refresh, o código faz normalização de texto via:
    
    ```
    split_whitespace().collect::<Vec<_>>().join(" ")
    ```
    
    cria `HashSet` para tipos secundários, executa `to_lowercase()`, valida UUID/data e constrói URLs/Strings.  
    Novamente: não é bug lógico, mas é um ponto quente plausível quando multiplicado por centenas ou milhares de registros.
    
8. **Retries podem multiplicar o custo em falhas de rede/5xx. — média.** O transport possui retry interno para timeout/connection/network e para 500/502/503/504. Cada request pode ser repetido até duas vezes adicionais. O `ProviderGate` impõe intervalo de 1 segundo especificamente para MusicBrainz e também possui cooldown de 429.  
    Não vi busy-spin aqui: o gate usa `sleep_until`, e o backoff também é assíncrono. Portanto **não parece haver loop ativo no rate limiter**. Mas rede instável pode transformar um refresh de 10 páginas em dezenas de tentativas.
    
9. **Possível churn por `spawn_blocking` para praticamente cada acesso ao enrichment DB. — média.** `database()` cria um novo `tokio::task::spawn_blocking` para cada operação.  
    Se um refresh gera dezenas/centenas de pequenas operações, isso pode produzir uma quantidade relevante de scheduling e wakeups. Um worker de DB serial ou operações agrupadas provavelmente seriam mais eficientes.
    
10. **`ProviderGate::wait()` não parece ser o loop culpado. — baixa probabilidade.** Existe um `loop`, mas quando o request ainda não pode executar ele libera o mutex e chama `sleep_until(due).await`; portanto não é busy-wait.  
    Eu descartaria esse trecho como causa primária de CPU elevada, salvo algum problema externo no runtime/timer.
    
11. **Os flights de deduplicação também parecem corretos e não são busy loops. — baixa probabilidade.** `resolve_artist_candidates` e `refresh_artist` compartilham operações concorrentes via `watch::Receiver`. A espera é feita por `receiver.changed().await`, não polling.  
    Isso reduz, em vez de aumentar, duplicação simultânea.
    
12. **O polling de playback a 4 Hz continua sendo um consumidor permanente e pode mascarar a análise.** O cliente macOS chama `core.playback()` a cada 250 ms enquanto o app está aberto. Isso aparentemente é anterior ao MusicBrainz, então não é minha principal suspeita para a regressão, mas é importante separar o baseline: se os 11–20% continuam indefinidamente com nenhuma `ArtistView` aberta e nenhuma sincronização acontecendo, eu investigaria esse polling e o player/core antes do enrichment.
    

Há um detalhe importante: o transport explicitamente não possui workers permanentes; as chamadas são futuras canceláveis e o MusicBrainz é rate-limited para aproximadamente 1 request/s. Portanto, **se esses 11–20% forem realmente sustentados em idle por minutos**, e não somente enquanto enrichment está ocorrendo, eu suspeitaria menos de um `while` interno do MusicBrainz e mais de **um gatilho externo chamando refresh repetidamente**, churn de UI/DB ou outro polling.

A sequência que eu usaria para encontrar isso rapidamente é: **(1)** desabilitar somente `refreshEnrichment()` automático da `ArtistView`; **(2)** medir CPU; **(3)** reativá-lo mas desabilitar `.discography/.covers`; **(4)** depois deixar apenas uma página MusicBrainz por refresh; **(5)** instrumentar contadores `refresh_artist`, `musicbrainz request`, `spawn_blocking` e `SQLite writes`. Os TTLs em si são razoáveis — perfil 30 dias e discografia 7 dias — portanto, com cache funcionando, revisitar um artista não deveria resultar em trabalho remoto pesado frequente.

Minha principal hipótese é **`ArtistView.task → refreshEnrichment → refreshArtistCatalog → discography_with_limits`**, especialmente para artistas cuja discografia ainda está `Partial`. Esse caminho tem o melhor encaixe temporal com a introdução do MusicBrainz e consegue gerar volume suficiente para explicar a regressão.