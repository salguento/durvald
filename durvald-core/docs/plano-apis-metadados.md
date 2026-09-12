# Plano de integração de APIs de metadados no core Rust

Data: 11/09/2026. Status: fases 1 (fundação) e 2 (identidade) implementadas; fase 3 em andamento; fases 4–5 pendentes.

## Objetivo e escopo

Enriquecer artistas e lançamentos da biblioteca com biografia, nascimento ou formação, imagens, discografia externa e links de videoclipes. O core Rust resolve identidades, consulta provedores, normaliza respostas, persiste dados e entrega DTOs pela UniFFI. Os clientes apresentam o resultado e solicitam atualizações.

Primeira entrega: MusicBrainz, Wikidata, Wikipedia, Wikimedia Commons e Cover Art Archive. Segunda entrega: TheAudioDB como complemento de imagens e vídeos; YouTube para busca sob demanda. Spotify e Discogs ficam fora desta implementação inicial. Last.fm continua com seu papel atual, sem refatoração obrigatória para acomodar os novos provedores.

O enriquecimento é opcional. Biblioteca, scan e reprodução funcionam sem rede. Não escrever tags nos arquivos nem substituir valores locais ou escolhas manuais durante atualizações remotas.

## 1. Pontos de integração existentes

| Arquivo | Situação e mudança planejada |
|---|---|
| `src/core.rs` | `DurvaldCore` possui pool SQLite, player e Last.fm. Acrescentar um `EnrichmentService` e métodos de fachada finos. |
| `src/api.rs` | `Artist` contém apenas ID e nome. Preservá-lo e criar DTOs próprios para detalhes remotos. |
| `src/database/operations.rs` | Schema criado por `create_tables`, com evolução pontual. Acrescentar migrações versionadas para enriquecimento. |
| `src/database/models.rs` | Modelos locais permanecem; novos registros ficam em módulo separado. |
| `src/metadata.rs` | Extração local via Lofty e validação limitada de imagens. Extrair helpers de artwork reutilizáveis e preservar IDs MusicBrainz das tags. |
| `src/lastfm.rs` | Referência existente para reqwest, timeouts e respostas limitadas. Reutilizar os princípios, sem compartilhar credenciais ou seu limitador. |
| `src/secure_store.rs` | Guardar chaves opcionais dos provedores, com nomes próprios. |
| `src/durvald.udl` e script de bindings | Registrar novos tipos conforme o padrão atual e regenerar a interface Swift. |

Já existem Tokio, reqwest, serde, rusqlite, r2d2 e image. Não acrescentar SDKs de cada serviço nem outro runtime. A tabela legada `artists_releases` deve ter seus usos auditados; não reaproveitá-la automaticamente como catálogo remoto, pois seu contrato não representa identidade, origem e paginação de provedores.

## 2. Organização de módulos

```text
src/
  enrichment.rs                 # entrada interna do módulo
  enrichment/
    service.rs                  # coordenação e atualização por seção
    models.rs                   # domínio normalizado, sem JSON dos provedores
    identity.rs                 # candidatos, evidências e vínculos
    transport.rs                # HTTP, limites, retries e cancelamento
    policy.rs                   # seleção de fonte, idioma, TTL e capacidades
    providers/
      musicbrainz.rs
      wikidata.rs
      wikipedia.rs
      commons.rs
      cover_art_archive.rs
      theaudiodb.rs             # segunda entrega
      youtube.rs                # segunda entrega
  artwork.rs                    # validação e persistência de imagens gerenciadas
  database/
    migrations.rs
    enrichment.rs               # consultas e transações do novo domínio
```

Cada adaptador contém seus DTOs de desserialização, construção de requisições e conversão para o domínio interno. Evitar um trait universal com operações que nem todos suportam: usar interfaces pequenas por capacidade — identidade, perfil, discografia, imagens e vídeos — apenas quando houver reutilização real. A testabilidade inicial vem de transporte injetável, relógio controlável e URL-base configurável nos testes.

## 3. Identidade antes do conteúdo

1. Ler vínculos já confirmados para o artista local.
2. Aproveitar MBIDs presentes nas tags, preservando o papel: artista da faixa, artista do álbum, release, release-group e recording são entidades diferentes.
3. Na ausência de vínculo, buscar candidatos no MusicBrainz e comparar nome/aliases, tipo de artista e lançamentos locais conhecidos.
4. Aceitar automaticamente somente evidência forte e sem conflito. Nome igual ou score de busca alto, isoladamente, não confirmam identidade. Calibrar a regra com fixtures de homônimos.
5. Retornar candidatos com evidências quando houver ambiguidade. Não buscar biografia ou retrato para um candidato ainda incerto.
6. A partir do MBID, aproveitar relações para Wikidata e outros serviços; obter o artigo Wikipedia pelos sitelinks do item correto.

Estados: `unresolved`, `ambiguous`, `resolved`, `not_found`. Guardar a origem do vínculo: tag, associação automática ou confirmação manual. Uma confirmação manual persiste entre atualizações; alterações conflitantes nas tags geram nova evidência, sem substituí-la silenciosamente.

O modelo local atual pode reunir homônimos pelo nome. Se faixas do mesmo artista local trouxerem MBIDs incompatíveis, retornar conflito e adiar o enriquecimento desse registro. Separar/mesclar artistas locais exige uma operação própria futura; não escolher um MBID arbitrariamente.

Cada alteração de identidade incrementa uma geração. Respostas iniciadas com a geração anterior são descartadas antes da gravação. Isso impede que uma biografia antiga reapareça após correção do artista.

## 4. Modelo de persistência

Manter catálogo remoto separado de `songs` e `releases`. Um disco descoberto online não se torna automaticamente reproduzível.

| Estrutura proposta | Conteúdo e restrições |
|---|---|
| `artist_external_ids` | Artista local, provedor, ID externo, origem, estado, evidências, confirmação e geração. Um vínculo ativo por artista/provedor; indexar também provedor/ID. |
| `artist_profile_sources` | Snapshot normalizado por artista, fonte e idioma, com versão do payload, timestamps, atribuição e geração. JSON interno versionado é suficiente para campos ainda sem necessidade de consulta SQL. |
| `artist_profile_overrides` | Escolhas manuais por campo e idioma, incluindo opção de limpar explicitamente um campo. |
| `external_release_groups` | MBID de grupo como chave, título, tipos primário/secundários e data com precisão. |
| `external_artist_release_groups` | Relação muitos-para-muitos entre artista e grupo; papel/crédito e geração da atualização. |
| `local_release_external_ids` | Vínculo de lançamento local com release MBID e/ou release-group MBID; sem associação só pelo título. |
| `enrichment_assets` | Provedor/ID, URL de origem, caminho gerenciado, autoria/licença, tamanho, timestamps e referências de uso. |
| `artist_videos` | Provedor/ID, artista, título, URL, origem do vínculo, canal quando conhecido e estado de verificação. |
| `enrichment_fetch_state` | Recurso, fonte, idioma, fingerprint dos parâmetros, cursor, ETag, Last-Modified, validade, última falha e próxima tentativa permitida. |
| `enrichment_settings` | Habilitação, idioma preferido, fontes opcionais e versão da política; sem segredos. |

Perfis guardam tipo de entidade e datas parciais. Uma data conhecida apenas como ano continua sendo ano; não inventar dia/mês. Nascimento aplica-se a pessoa; formação aplica-se a grupo. Cidade de origem, nascimento e formação são campos distintos. Textos incluem idioma efetivo, URL do artigo e revisão quando disponível.

Migrar após a inicialização idempotente atual, com uma tabela de versões e transações. Cobrir bancos novos e existentes, reabertura e falha com rollback. Habilitar as mesmas foreign keys usadas no pool atual; adicionar limpeza de referências órfãs. Não renumerar IDs locais.

## 5. Contrato público proposto

Assinaturas conceituais, a ajustar às restrições da UniFFI 0.27 já fixada no projeto:

```rust
artist_details(artist_id, language) -> ArtistDetails
artist_discography(artist_id, offset, limit) -> ArtistDiscographyPage
artist_videos(artist_id, offset, limit) -> ArtistVideoPage

refresh_artist(artist_id, request: ArtistRefreshRequest) -> ArtistRefreshResult
resolve_artist_candidates(artist_id) -> ArtistIdentityCandidates
confirm_artist_identity(artist_id, musicbrainz_id) -> ArtistIdentity
clear_artist_identity(artist_id) -> ()

set_artist_override(artist_id, value: ArtistFieldOverride) -> ()
clear_artist_override(artist_id, field, language) -> ()
configure_enrichment(settings: EnrichmentSettings) -> ()
set_enrichment_api_key(provider, key) -> ()
remove_enrichment_api_key(provider) -> ()
```

Todos retornam `CoreResult<T>` e são async quando envolvem I/O. As três leituras consultam apenas o estado local. `refresh_artist` executa uma atualização limitada e aguardável; a UI primeiro mostra o cache, depois chama refresh numa tarefa e relê os dados. Evitar worker permanente e polling de jobs na primeira entrega.

`ArtistRefreshRequest` define seções, idioma e se o cache pode ser revalidado antes do TTL. Forçar refresh nunca ignora rate limit, indisponibilidade temporária nem cota. Cada chamada tem orçamento de páginas/tempo; discografias grandes retornam cursor persistido para continuação. O DTO de página diferencia fim dos registros já armazenados de fim confirmado da consulta remota.

`ArtistDetails` contém identidade, fatos, biografia, referência de imagem e procedência por campo selecionado. `ArtistRefreshResult` contém resultados por seção, por exemplo: `updated`, `unchanged`, `not_found`, `needs_identity`, `unavailable`, `rate_limited`, `disabled`, além de `retry_after` quando aplicável. Não reduzir uma atualização parcialmente bem-sucedida a um erro genérico.

Preservar os métodos existentes `artist`, `artist_releases`, `artist_tracks` e o record `Artist`. Discografia externa recebe tipo próprio e, quando houver vínculo confirmado, um ID opcional do lançamento local.

## 6. Fluxo de atualização

1. Verificar configuração e ID local; carregar identidade, geração e cache numa operação SQLite curta.
2. Agrupar solicitações equivalentes em andamento por artista, seção e idioma. Uma chamada aguarda o resultado da mesma operação, sem duplicar HTTP.
3. Resolver identidade quando necessário. Se ambígua, encerrar as seções dependentes com estado apropriado.
4. Consultar fontes independentes com concorrência limitada. Wikipedia depende da resolução do artigo; retrato Commons depende da identificação do arquivo.
5. Normalizar cada resposta e validar limites; baixar apenas a imagem selecionada quando requisitada.
6. Persistir cada seção válida em transação curta, verificando geração e existência do artista. Falha de uma fonte não apaga dados de outra.
7. Construir a visão consolidada usando escolhas manuais, prioridades de fonte e idioma.

Não segurar conexão SQLite ou mutex de áudio durante rede. Usar `spawn_blocking` para SQLite, decodificação e escrita de arquivos, seguindo o padrão do core. Não iniciar enriquecimento em `open`, no scan ou ao trocar de faixa. O primeiro gatilho será abrir os detalhes de um artista ou solicitar atualização explicitamente.

Cancelar a espera de uma tela não deve cancelar trabalho compartilhado ainda necessário a outra. Quando não houver consumidores, cancelar rede/paginação; limpeza da operação em andamento deve ocorrer mesmo em cancelamento. Nenhuma tarefa deve manter `Arc<DurvaldCore>` vivo indefinidamente.

## 7. Chamadas por provedor

| Provedor | Operações previstas | Tratamento |
|---|---|---|
| MusicBrainz | Busca de artista; lookup por MBID com aliases/relações; browse paginado de release-groups; lookup de release quando necessário | JSON, User-Agent identificável, máximo de uma chamada/segundo compartilhado entre consumidores do processo. Não depender da lista truncada incluída no lookup do artista. |
| Wikidata | Entidades por QID, claims e sitelinks; resolução de nomes dos lugares referenciados | Obter data/local de nascimento, formação e imagem quando presentes. Preservar precisão, referências e ausência/conflito de fatos. Evitar SPARQL no caminho comum. |
| Wikipedia | Action API para introdução textual do artigo resolvido por sitelink | Preferir idioma solicitado, com fallback explícito; guardar idioma realmente recebido. Não usar busca textual cega como vínculo. |
| Commons | Action API para metadados e miniatura do arquivo ligado pelo Wikidata | Obter autoria, licença e página de origem junto da imagem. Escolher JPEG/PNG compatível com o decoder atual. |
| Cover Art Archive | Consulta por release MBID; release-group como fallback identificado | Preferir front thumbnail. Capa embutida/manual prevalece. Imagem de grupo não deve ser apresentada como capa exata de uma edição. |
| TheAudioDB | Lookup de artista, imagens e vídeos por endpoint específico | Habilitar por capacidade verificada no plano da chave; não assumir que todos os endpoints são gratuitos. |
| YouTube | `search.list` sob demanda; `videos.list` para verificar disponibilidade e metadados | Manter vídeo candidato como não verificado até haver evidência de canal oficial. Retornar links; não baixar mídia nem introduzir playback de vídeo no core. |

As rotas Wikimedia e CAA devem ter seus parâmetros confirmados e exercitados em um smoke test de cada adaptador na implementação; ainda não foram executadas neste planejamento.

## 8. Transporte, cache e política de fontes

Criar clientes reqwest reutilizáveis por política de host, com pool de conexões. Defaults de projeto: conexão 5 s, chamada 20 s, JSON limitado a 2 MiB; tornar exceções explícitas por endpoint. Para imagens, reutilizar o teto atual de 10 MiB e limites de decodificação. Processar o corpo incrementalmente; Content-Length não basta.

Usar URLs-base fixas e query builder; escapar também a sintaxe de busca do provedor. Validar hosts e redirecionamentos de imagens, incluindo os destinos CDN legítimos de CAA/Commons. Não encaminhar chaves a outro host nem registrar URLs que contenham segredo.

Rate limits usam relógio monotônico e estado compartilhado por provedor; Wikimedia deve ter também orçamento agregado entre seus hosts. Respeitar `Retry-After`, aplicar backoff com jitter e no máximo duas novas tentativas para GET em erros transitórios. Não repetir autenticação inválida, 404 ou erro de parse automaticamente. Cooldown de um provedor não paralisa os outros.

Defaults de cache propostos, subordinados aos termos e cabeçalhos de cada fonte: perfil/biografia 30 dias, discografia 7 dias, ausência confirmada 24 horas. Uma falha de rede não vira ausência nem apaga cache bom. Usar ETag/Last-Modified quando suportados. TTL vencido significa elegibilidade para revalidação, não exclusão automática; armazenar separadamente qualquer prazo obrigatório de remoção.

Prioridade inicial: override manual; Wikidata para fatos; Wikipedia para biografia; Commons para retrato; TheAudioDB como fallback opcional. Um snapshot novo da fonte deve refletir campos removidos, mas só após resposta completa e válida. Não deixar um campo antigo sobreviver eternamente por usar apenas merges aditivos.

Imagens ficam dentro de `covers_dir`, preservando o contrato de caminhos absolutos gerenciados e validação de symlinks. Usar temporário e rename atômico, deduplicar por conteúdo e coletar apenas assets remotos sem referências. A limpeza nunca remove capas locais ainda usadas.

Para discografia, atualizar páginas numa geração de snapshot; só remover relações antigas quando todas as páginas dessa geração concluírem. Paginação interrompida não é evidência de que discos desapareceram.

## 9. Configuração, credenciais e operação

Persistir preferências separadas de `CoreConfig` para evitar alterar sua inicialização pública. Habilitar enriquecimento por configuração explícita do cliente; modo offline impede novas chamadas e mantém leituras locais. Essa opção deve informar que nomes/identificadores serão enviados aos provedores habilitados.

TheAudioDB premium e YouTube usam SecureStore, nunca SQLite ou logs. Chave embarcada num app desktop distribuído não é segredo protegido: para distribuição, definir chave do usuário ou backend próprio com orçamento central antes de habilitar uma chave compartilhada. Um contador local não controla a cota global de todas as instalações.

Registrar métricas sem dados sensíveis: provedor/operação, duração, hit de cache, número de tentativas e classe de erro. Não introduzir envio de telemetria. Diferenciar falta de credencial, limite atingido e ausência de conteúdo na resposta pública.

O uso comercial do serviço hospedado MusicBrainz precisa ser avaliado separadamente da licença CC0 dos dados. Guardar atribuição/licença dos textos e imagens desde a primeira entrega. Para YouTube, confirmar política de retenção/atualização antes de escolher seu TTL; não aplicar automaticamente os 30 dias do cache de biografia.

## 10. Ordem de implementação e aceite

| Fase | Entrega | Critério de conclusão |
|---|---|---|
| 1 — Fundação | Módulos, migrations, modelos, transporte, política e leitura local dos DTOs | Banco existente abre sem perda; falhas HTTP simuladas respeitam timeout, limite de corpo e retry; reprodução permanece independente. |
| 2 — Identidade | Tags MBID, candidatos MusicBrainz, confirmação e invalidação por geração | Homônimos e MBIDs conflitantes não são associados silenciosamente; correção sobrevive a rescan/refresh. |
| 3 — Perfil | Wikidata, Wikipedia, Commons, biografia e retrato | Artista conhecido tem fatos, texto, idioma e atribuição; incompletude de uma fonte produz resultado parcial utilizável offline. |
| 4 — Discografia e capas | Paginação MusicBrainz, catálogo separado e CAA | Discografia maior que uma página funciona; interrupção não remove discos; biblioteca reproduzível e capa embutida preservadas. |
| 5 — Complementos | TheAudioDB e YouTube opcionais | Ausência de chave não afeta o núcleo; limite de busca não causa loop; vídeo candidato não é rotulado automaticamente como oficial. |

Cada fase inclui DTOs/exportações UniFFI correspondentes e verificação do consumidor Swift. A primeira entrega utilizável termina na fase 4; fase 5 pode ser implementada depois sem reformular o domínio.

## 11. Verificação

Testes determinísticos com fixtures JSON e servidor HTTP local: homônimos; datas parciais; grupo versus pessoa; idioma ausente; campos nulos; 404/429/503; JSON inválido; corpo sem Content-Length acima do teto; redirects de imagens; paginação interrompida; cache vencido; cancelamento; duas telas consultando o mesmo artista; identidade corrigida durante resposta em voo; override manual; migração e rollback.

Testar integração com SQLite temporário e player mock já usado no core. Verificar que requisição lenta não mantém conexão ocupada nem interfere em operações do player. Cobrir o caso em que um artista é removido pelo scan durante o refresh.

Comandos previstos a partir de `durvald-core`: `cargo fmt --check`, `cargo test`, `cargo test --features uniffi`, `cargo check --features uniffi`. Regenerar bindings pelo script existente e compilar o app macOS após mudanças de FFI. Testes contra APIs reais são smoke tests manuais pequenos, separados do CI; nenhum teste depende da disponibilidade pública ou consome cota do YouTube rotineiramente.

## Referências e pontos a validar

- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API): identidade, browse paginado, User-Agent, limite de uma chamada/segundo e condições do serviço hospedado.
- [Licenças MusicBrainz](https://musicbrainz.org/doc/About/Data_License): separar dados centrais e suplementares.
- [Wikidata — acesso](https://www.wikidata.org/wiki/Wikidata:Data_access) e [conteúdo Wikimedia](https://developer.wikimedia.org/use-content/content/): acesso a entidades, reutilização e atribuição.
- [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API): referência para validação das rotas durante a fase 4.
- [TheAudioDB — documentação](https://www.theaudiodb.com/free_music_api) e [preços](https://www.theaudiodb.com/pricing): validar capacidades reais porque as páginas apresentam diferenças entre planos e exemplos.
- [YouTube — cotas](https://developers.google.com/youtube/v3/getting-started): documentação consultada informa 100 buscas/dia e 10 mil unidades para os demais endpoints; configuração real deve ser verificada no projeto.

Este plano não depende de cobertura completa dos catálogos e não atribui qualidade curatorial a texto enciclopédico. Conteúdo editorial próprio poderá ser acrescentado posteriormente como fonte distinta, com procedência explícita.


## Entrega da fase 2 — identidade

Implementada em 12/09/2026:

- Extração tipada dos MBIDs pelo Lofty, preservando artista da faixa, artista do álbum, release, release-group e recording. A versão de metadados do scan passou a 4: o próximo scan relê arquivos existentes mesmo sem mudança de mtime. Nenhuma tag é escrita.
- Migração 2 armazena os IDs por faixa, evidências por papel, confirmação manual e candidatos normalizados. Evidências com créditos múltiplos não recebem correspondência por posição; ficam incertas. Release/recording MBIDs nunca são usados como IDs de artista.
- `artist_identity`, `resolve_artist_candidates`, `confirm_artist_identity` e `clear_artist_identity` exportados via UniFFI. `artist_details` continua local e respeita a geração atual.
- Apenas uma tag de artista inequívoca permite resolução automática nesta fase. A busca MusicBrainz retorna até 10 candidatos com nome, aliases, tipo, desambiguação e evidências. Compara títulos locais com uma amostra de até 100 release-groups dos três primeiros candidatos, sem interpretar ausência na amostra como ausência no catálogo. Nome, score ou títulos coincidentes não confirmam automaticamente.
- Confirmação manual valida o formato do MBID e persiste inclusive offline; a escolha do ID é responsabilidade do consumidor. Tags incompatíveis bloqueiam o enriquecimento, mas preservam o ID confirmado no DTO para correção. Limpar a identidade também impede reassociação automática pelas mesmas tags; nova confirmação explícita volta a estabelecer o vínculo.
- Alterações de evidência e confirmação invalidam a geração; snapshots anteriores deixam de aparecer e respostas em voo não substituem a correção. Um rescan com evidências idênticas mantém a geração. A exclusão de faixas remove evidências por foreign key.
- Consulta explícita, sem worker permanente, com prazo total de 30 segundos, cliente reutilizável e limitador MusicBrainz compartilhado no processo. Chamadas simultâneas para o mesmo artista compartilham trabalho; cancelar uma espera preserva os demais consumidores, e o último cancelamento aborta a tarefa. SQLite fica livre durante HTTP.
- Busca retorna estado de indisponibilidade, rate limit, modo offline/desabilitado ou resposta superada. Falhas preservam candidatos já armazenados e não viram `not_found`. Nesta fase, uma nova chamada explícita reconsulta candidatos; TTL de busca e seleção automática por evidências compostas ficam para evolução da política.

Os detalhes de perfil, relações Wikidata, retrato, discografia pública e UI de confirmação pertencem às fases seguintes. A fase 2 entrega o contrato e os bindings para o cliente, sem iniciar consultas automaticamente ao abrir o app.

Verificação: fixtures de homônimos, tags com papéis distintos, créditos incertos, conflitos, confirmação/limpeza, rescan idêntico, reabertura, resposta superada e teste de HTTP local com consumidores concorrentes. As rotas de busca e browse seguem a [documentação oficial do MusicBrainz](https://musicbrainz.org/doc/MusicBrainz_API); os testes automatizados não acessam serviços públicos.

Validação concluída: `cargo fmt --check`, `cargo test` (87 testes), `cargo test --features uniffi` (87 testes) e `cargo check --features uniffi`. Bindings Swift e biblioteca arm64 regenerados pelo script do projeto; build Debug do app macOS concluído com `CODE_SIGNING_ALLOWED=NO`. O teste de HTTP local exige permissão de abertura de porta quando executado dentro de sandbox.

## Fase 3 — perfil (concluída)

Primeiro recorte implementado em 12/09/2026:

- `refresh_artist` e seus DTOs públicos distinguem perfil e retrato e retornam estado por seção, incluindo identidade pendente, modo offline, indisponibilidade, rate limit e resposta superada.
- O vínculo curado do MusicBrainz resolve o QID sem busca textual e é persistido na migração 3, sempre associado à geração atual da identidade.
- O adaptador Wikidata normaliza pessoa/grupo, nascimento ou formação com precisão parcial, locais, país de origem, sitelink e arquivo de imagem. Rótulos de locais são complementares: sua falha não invalida os demais fatos.
- O adaptador Wikipedia consulta somente o artigo vindo do sitelink, extrai a introdução, registra idioma efetivo, URL canônica, revisão, autoria e licença. Falha da Wikipedia preserva o snapshot Wikidata como resultado parcial utilizável offline.
- Snapshots usam o TTL de perfil já definido, são substitutivos e só são gravados quando a geração ainda coincide. Leituras continuam estritamente locais.
- Bindings Swift e biblioteca arm64 foram regenerados para o novo contrato.

Segundo recorte implementado em 12/09/2026:

- O adaptador Commons consulta `imageinfo`, seleciona miniatura JPEG/PNG, preserva página de origem, autoria e licença e rejeita outros formatos.
- Downloads usam teto incremental de 10 MiB, não carregam credenciais e validam novamente cada redirect contra a lista explícita de hosts Wikimedia permitidos.
- Retratos são validados pelo decoder existente e gravados em `covers_dir` por hash de conteúdo, com temporário no mesmo diretório e rename atômico. O mesmo conteúdo é deduplicado.
- A migração 4 adiciona `enrichment_assets`; `ArtistDetails.portrait` expõe a referência offline somente quando sua geração ainda coincide com a identidade do artista.
- Refreshes equivalentes agora compartilham uma única tarefa por artista, idioma, seções e opção de força. O último consumidor cancelado interrompe a tarefa compartilhada.
- O orçamento total de perfil e retrato é limitado a 30 segundos. Falha no retrato não elimina fatos ou biografia já persistidos.
- Há fixture integrada cobrindo MBID → QID → fatos → Commons → arquivo gerenciado → leitura offline, além de testes de redirect, formato, atribuição, migração e geração superada.

- O cliente macOS agora oferece habilitação explícita, modo offline e idioma preferido em Ajustes. A tela do artista lê o cache antes da rede, atualiza em segundo plano, usa o retrato gerenciado no cabeçalho e apresenta fatos e biografia com link de atribuição.

Recorte final implementado em 12/09/2026:

- Wikidata e Wikipedia reutilizam `ETag`/`Last-Modified`; respostas `304` renovam timestamps e TTL sem regravar o payload. Sitelink e alvo Commons derivados ficam associados à geração para que todas as fontes possam ser revalidadas independentemente.
- A coleta remove referências de retratos pertencentes a gerações antigas e apaga somente arquivos content-addressed dentro de `covers_dir` que não estejam mais referenciados por outra fonte, faixa ou lançamento. Substituição e resposta superada seguem a mesma verificação conservadora.
- A migração 5 adiciona overrides manuais por campo. Fatos são globais (`und`), biografias são específicas por idioma e `None` representa limpeza explícita; valores, enums e datas parciais são validados antes da gravação. Overrides sobrevivem à troca de geração e têm precedência no consumidor Swift.
- Smoke tests opt-in separados exercitam MusicBrainz e as rotas públicas de Wikidata, Wikipedia e Commons. A execução real corrigiu a presença de metadados Commons não textuais, o host oficial `thumb.wikimedia.org` e o caso transitório `Retry-After: 0` do MusicBrainz.

Validação final: `cargo fmt --check`, suíte Rust com e sem UniFFI, smoke tests públicos opt-in e build Debug arm64 do app macOS com assinatura desabilitada. Bindings Swift e biblioteca arm64 foram regenerados para o contrato final.
