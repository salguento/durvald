# Fase 4 — discografia e capas

Objetivo: adicionar um catálogo remoto paginado e capas do Cover Art Archive sem transformar itens online em lançamentos reproduzíveis nem substituir capas locais.

Status: **concluída**.

## Progresso

- [x] Contratos Rust/UniFFI de release-group, capa externa e página de discografia.
- [x] Separação explícita entre paginação dos registros locais e término da paginação remota.
- [x] Seções `Discography` e `Covers` no refresh e leitura local inicial de catálogo vazio.
- [x] Migration 6 e persistência transacional de catálogo, vínculos locais e capas externas.
- [x] Gerações ativa/em construção separadas, com retomada de offset e publicação atômica.
- [x] Leitura local paginada, reabertura do banco, upgrade da fase 3 e rollback cobertos por testes.
- [x] Vínculo de lançamentos locais por MBIDs de release/release-group extraídos das tags.
- [x] Conflitos, remoções e retag recompõem os vínculos sem associação por título.
- [x] Backfill transacional e idempotente para bibliotecas já escaneadas, sem reler os arquivos.
- [x] Paginação MusicBrainz com total conhecido, cursor persistido e término confirmado.
- [x] Tipos, datas parciais e procedência CC0 normalizados antes da persistência.
- [x] Limite de 10 páginas e orçamento de 20 segundos por lote de atualização.
- [x] Snapshots transacionais imutáveis, publicação completa e leitura coerente por geração.
- [x] Falhas intermediárias e respostas superadas preservam integralmente o catálogo ativo.
- [x] Adaptador Cover Art Archive com release exato, fallback identificado e preferência por `front`.
- [x] Downloads de capa limitados a JPEG/PNG, 10 MiB, 4096 px e hosts HTTPS autorizados.
- [x] Capas manuais/embutidas precedem externas sem mutação de `releases.artwork`.
- [x] Capas externas exatas exigem MBID local correspondente e precedem fallback de release-group.
- [x] Substituição externa reporta apenas caminhos realmente órfãos para limpeza conservadora.
- [x] Discografia e capas integradas ao singleflight do serviço de enriquecimento.
- [x] TTL de sete dias, cache fresco, revalidação condicional e preservação offline.
- [x] Estados de lote parcial, rate limit, cursor pendente e geração superada expostos.
- [x] Cliente macOS lê o snapshot local antes de atualizar em segundo plano.
- [x] Lançamentos reproduzíveis e itens somente online aparecem em seções distintas.
- [x] Paginação local e continuação remota explícitas, com estados offline/rate limit visíveis.
- [x] Capa externa aplicada no cliente apenas como fallback para lançamentos sem capa local.
- [x] Mudança concorrente de identidade, interrupção, múltiplas páginas e cache offline testados.
- [x] Smokes públicos de MusicBrainz, Wikimedia e Cover Art Archive aprovados.
- [x] Rust/UniFFI, bindings arm64 e build macOS validados ao concluir a fase.

O serviço atualiza discografia e capas no mesmo coordenador singleflight das demais seções. Catálogos e capas frescos são lidos sem rede por sete dias; catálogos vencidos ou forçados usam ETag/Last-Modified e uma resposta 304 apenas renova o snapshot ativo. Paginação e lotes de capas permanecem limitados e retornam `Partial` enquanto houver cursor ou trabalho pendente. No macOS, a tela do artista apresenta imediatamente o snapshot SQLite, separa a biblioteca reproduzível dos itens somente online e só então atualiza em segundo plano. O botão de continuação trata tanto páginas remotas quanto lotes de capas pendentes. Falhas de rede, rate limit e mudança de identidade preservam o conteúdo exibido.

## Roteiro de implementação

1. **Definir o contrato público**
   - Criar `ExternalReleaseGroup`, `ArtistDiscographyPage` e tipos auxiliares.
   - Diferenciar registros armazenados de catálogo remoto completamente consultado.
   - Incluir MBID, título, tipos, data parcial, capa, procedência e ID opcional do lançamento local.
   - Adicionar `Discography` e `Covers` às seções de refresh.

2. **Criar as migrations** — concluído
   - Criar `external_release_groups`, `external_artist_release_groups` e `local_release_external_ids`.
   - Persistir estado de paginação e geração do snapshot.
   - Associar capas externas por meio de `enrichment_assets` sem alterar capas locais.
   - Testar banco novo, upgrade, reabertura e rollback.

3. **Relacionar lançamentos locais** — concluído
   - Aproveitar release e release-group MBIDs já extraídos das tags.
   - Vincular lançamentos locais somente por identificadores confirmados.
   - Nunca associar discos apenas por título.
   - Preservar integralmente `songs`, `releases` e a biblioteca reproduzível.

4. **Implementar paginação MusicBrainz** — concluído
   - Consultar todos os release-groups do artista por MBID.
   - Persistir cursor/offset, total conhecido e término confirmado.
   - Normalizar tipo primário, tipos secundários e datas parciais.
   - Aplicar limite de páginas e orçamento de tempo por refresh.

5. **Implementar snapshots transacionais** — concluído
   - Gravar páginas recebidas numa nova geração de catálogo.
   - Publicar a geração somente quando todas as páginas previstas terminarem.
   - Em cancelamento, timeout ou erro intermediário, manter intacta a discografia anterior.
   - Descartar respostas quando a identidade do artista mudar.

6. **Criar o adaptador Cover Art Archive** — concluído
   - Consultar primeiro por release MBID exato.
   - Usar release-group apenas como fallback identificado.
   - Preferir imagem marcada como `front`.
   - Validar hosts e redirects do CDN, tamanho, JPEG/PNG e dimensões.
   - Adicionar smoke test opt-in contra a API pública.

7. **Definir a precedência das capas** — concluído
   - Manter capa manual ou embutida como prioridade.
   - Não sobrescrever `releases.artwork` com capa externa.
   - Identificar quando uma imagem representa o grupo e não uma edição específica.
   - Reutilizar armazenamento content-addressed e limpeza conservadora da fase 3.

8. **Integrar ao serviço de enriquecimento** — concluído
   - Adicionar refresh de discografia/capas ao singleflight existente.
   - Aplicar TTL de sete dias e revalidação condicional.
   - Preservar cache em falhas de rede.
   - Retornar estados parciais, rate limit, cursor pendente e geração superada.

9. **Integrar ao cliente macOS** — concluído
   - Ler primeiro a discografia armazenada localmente.
   - Mostrar separadamente lançamentos reproduzíveis e itens somente online.
   - Atualizar em segundo plano.
   - Usar capa externa somente quando não houver capa local prioritária.
   - Permitir continuação explícita de catálogos ainda paginados.

10. **Validar e concluir** — concluído
    - Cobrir mais de uma página, interrupção, mudança de identidade e cache offline.
    - Testar vínculos locais por MBID e rejeição de associação por título.
    - Testar fallback por release-group e preservação de capas locais.
    - Executar testes Rust/UniFFI, regenerar bindings, rodar smoke público e compilar o app macOS.

## Critério de conclusão

Uma discografia maior que uma página pode ser atualizada e continuada sem remover o snapshot anterior quando a paginação falha. O catálogo remoto permanece separado da biblioteca reproduzível, vínculos locais dependem de MBIDs e capas manuais ou embutidas sempre prevalecem sobre imagens externas.

## Validação final

- 126 testes automatizados aprovados; os 3 smokes opt-in ficam ignorados na suíte padrão.
- Smokes opt-in executados separadamente contra MusicBrainz, Wikidata/Wikipedia/Commons e Cover Art Archive, todos aprovados.
- Bindings Swift regenerados a partir da biblioteca release arm64.
- Aplicativo macOS compilado em Debug sem assinatura de código.

## Extensão do cliente: seleção visual de identidade

- A tela do artista mostra o estado da identidade MusicBrainz antes das seções enriquecidas.
- A busca de candidatos é iniciada explicitamente pelo usuário e apresenta nome, tipo, desambiguação, aliases, evidências e MBID.
- A confirmação do candidato troca a geração ativa e recarrega perfil, discografia e capas.
- Um vínculo existente pode ser removido após confirmação destrutiva; conteúdo da geração anterior deixa de ser apresentado.
- Estados offline, desabilitado, indisponível, rate limit, busca superada e tags conflitantes possuem mensagens próprias, preservando candidatos armazenados quando disponíveis.
