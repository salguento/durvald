# Roteiro — carregamento progressivo e fontes alternativas de capas

## Objetivo

Reduzir o tempo percebido para abrir páginas de artistas e discografias sem
trocar precisão por velocidade. Metadados textuais, identidade, discografia e
imagens devem progredir independentemente: a ausência ou lentidão de uma capa
nunca deve bloquear a navegação.

O resultado esperado é:

- conteúdo local e cache aparecem imediatamente;
- somente cards visíveis solicitam imagens;
- uma fonte lenta não impede tentativa nas fontes seguintes;
- capas permanecem disponíveis offline depois de materializadas;
- correspondências ambíguas nunca são publicadas automaticamente;
- origem, atribuição e regras de uso de cada imagem permanecem auditáveis.

## Diagnóstico inicial

O atraso atual não deve ser atribuído apenas ao Cover Art Archive. A abertura
de uma página pode envolver, em sequência, validação de identidade, várias
páginas de discografia MusicBrainz, consulta de metadados de capa e download da
imagem. O MusicBrainz limita cada aplicação a uma requisição por segundo. O
Cover Art Archive não declara atualmente um limite fixo, mas pode apresentar
latência, indisponibilidade e respostas `503`.

Referências:

- MusicBrainz API: <https://musicbrainz.org/doc/MusicBrainz_API>
- Cover Art Archive API: <https://musicbrainz.org/doc/Cover_Art_Archive/API>

Antes de adicionar provedores, medir separadamente:

1. tempo para resolver a identidade;
2. tempo até a primeira página textual da discografia;
3. tempo de resposta da consulta de artwork;
4. tempo de download e decodificação da imagem;
5. tempo até a primeira capa visível;
6. quantidade de requisições iniciadas, concluídas e canceladas.

## Decisões de produto

### Ordem recomendada de fontes

1. artwork embutido no arquivo local;
2. arquivo já existente no cache gerenciado, mesmo expirado;
3. Cover Art Archive por release ou release-group identificado;
4. Apple Music para correspondências confiáveis;
5. TheAudioDB, preferencialmente por MusicBrainz Release Group ID;
6. Spotify somente como integração conectada e opcional.

A ordem deve ser configurável por política, não codificada na interface.

### Spotify não será fallback transparente

A Web API do Spotify oferece imagens de álbum em várias resoluções e uma CDN
rápida, mas impõe requisitos incompatíveis com um fallback invisível:

- autenticação OAuth;
- restrições de quota e usuários em Development Mode;
- atribuição visual ao Spotify;
- link próximo ao álbum ou conteúdo correspondente;
- proibição de recortar, sobrepor ou modificar a capa;
- armazenamento apenas quando necessário ao funcionamento da integração.

Uma integração futura deve usar Authorization Code com PKCE no aplicativo
desktop, possuir consentimento explícito e identificar imagens Spotify no DTO e
na interface.

Referências:

- autorização: <https://developer.spotify.com/documentation/web-api/concepts/authorization>
- quotas: <https://developer.spotify.com/documentation/web-api/concepts/quota-modes>
- política: <https://developer.spotify.com/policy>
- álbum e imagens: <https://developer.spotify.com/documentation/web-api/reference/get-an-album>

### Apple Music

Apple Music é o candidato comercial preferencial para o aplicativo macOS. A
API fornece artwork parametrizado por resolução e recursos de catálogo para
álbuns e artistas. A integração exige Developer Token e deve persistir o ID de
catálogo e o storefront usados na correspondência.

Referências:

- Apple Music API: <https://developer.apple.com/documentation/applemusicapi>
- Artwork: <https://developer.apple.com/documentation/applemusicapi/artwork>

### TheAudioDB

TheAudioDB será um fallback comunitário. O lookup por MusicBrainz Release Group
ID evita busca textual e se encaixa no modelo atual do Durvald. A implementação
deve aceitar respostas sem imagem e respeitar diferenças entre os planos v1 e
v2.

Referências:

- API: <https://www.theaudiodb.com/free_music_api>
- tamanhos de artwork: <https://www.theaudiodb.com/docs_artwork>

## Arquitetura proposta

### Separação do pipeline

```text
abrir artista
  ├─ ler artista, perfil e fontes locais do SQLite
  ├─ publicar imediatamente o cache textual
  ├─ carregar uma página limitada da discografia
  └─ para cada card que se torna visível
       ├─ exibir cache gerenciado, inclusive stale
       ├─ revalidar em segundo plano
       ├─ tentar Cover Art Archive com prazo curto
       ├─ tentar Apple Music
       └─ tentar TheAudioDB
```

Identidade, discografia e artwork devem possuir estados independentes. Uma
falha de artwork não muda o estado da identidade nem invalida a discografia.

### Interface de provedor

Criar um contrato interno semelhante a:

```text
ArtworkProvider.resolve(request) ->
    Found(candidate)
    | NotFound(ttl)
    | Ambiguous(candidates)
    | TemporarilyUnavailable(retry_after)
```

`ArtworkRequest` deve conter somente evidências já persistidas:

- `artist_id` interno;
- `release_group_mbid` e `release_mbid`, quando disponíveis;
- UPC/EAN normalizado;
- IDs externos já confirmados;
- artista, título, tipo e data como evidência secundária;
- tamanho necessário para a apresentação.

`ArtworkCandidate` deve registrar:

- provedor;
- ID externo do recurso;
- URL de origem e URL da imagem;
- dimensões;
- escopo: release-group ou edição exata;
- método e confiança da correspondência;
- link de atribuição;
- restrições de apresentação;
- instante de obtenção e expiração.

### Persistência

Reutilizar `enrichment_assets` quando possível, acrescentando apenas campos que
forem necessários para política e auditoria. Não gravar URLs de terceiros em
`releases.artwork`.

IDs externos de catálogo devem permanecer separados por provedor:

```text
release_group_mbid -> apple_music_album_id + storefront
release_group_mbid -> theaudiodb_album_id
release_group_mbid -> spotify_album_id
```

O arquivo gerenciado deve possuir chave derivada do conteúdo ou da identidade
imutável do asset. Uma troca de URL que entregue os mesmos bytes não deve gerar
duplicação.

Persistir também resultados negativos:

- `not_found`: TTL longo;
- erro transitório ou `5xx`: TTL curto com backoff;
- rate limit: respeitar `Retry-After`;
- ambiguidade: não repetir automaticamente até mudança das evidências;
- resultado stale: continuar apresentável durante revalidação.

## Regras de correspondência

Ordem de confiança para publicação automática:

1. ID externo já confirmado para o provedor;
2. MusicBrainz Release ID ou Release Group ID aceito diretamente pelo provedor;
3. UPC/EAN exato combinado com artista compatível;
4. artista, título, tipo e ano consistentes;
5. artista e título apenas: candidato, nunca publicação automática.

Nomes normalizados ajudam a pontuar candidatos, mas não constituem identidade.
Edições com capas diferentes devem preservar o escopo exato. Quando não houver
prova da edição, publicar somente como artwork do release-group.

## Política de carregamento

- Não esperar artwork para concluir a abertura da página.
- Prefetch limitado aos primeiros 6–10 cards.
- Iniciar trabalho adicional quando o card entrar na área visível.
- Cancelar tarefas quando o card ou a página desaparecer.
- Limitar concorrência global e por provedor.
- Usar thumbnails de 250 ou 500 pixels nas grades do Cover Art Archive.
- Baixar resolução maior somente para hero, detalhe ou inspeção.
- Aplicar deadline por tentativa e permitir fallback antes do timeout global.
- Deduplicar requisições simultâneas para a mesma chave de catálogo.
- Fazer publicação atômica subordinada à geração da identidade e do catálogo.

Valores iniciais para medição, não contratos definitivos:

- cards em prefetch: 8;
- downloads simultâneos: 3;
- consultas simultâneas por provedor: 2;
- deadline do primeiro provedor: 1,5–2 segundos;
- resultado negativo definitivo: 7 dias;
- falha transitória: backoff de minutos até poucas horas.

## Etapas de implementação

### 1. Instrumentação e baseline

- registrar spans por identidade, discografia, lookup e download;
- medir p50, p90 e p95 até primeira capa;
- contar cache hit, miss, stale, cancelamento e fallback;
- registrar bytes e resolução efetivamente usados.

Critério: distinguir claramente atraso do MusicBrainz, Cover Art Archive,
download, decodificação e renderização.

### 2. Desbloquear a página

- publicar cache textual antes de qualquer capa;
- limitar a primeira página da discografia;
- eliminar waits que agregam todas as capas;
- exibir placeholder estável sem deslocamento de layout.

Critério: uma fonte de imagem indisponível não altera o tempo de apresentação
dos metadados textuais.

### 3. Scheduler orientado à visibilidade

- criar fila priorizada por posição visível;
- deduplicar pela chave `(provider, catalog_key, size_class)`;
- cancelar trabalho não iniciado e ignorar publicação obsoleta;
- integrar o scheduler ao ciclo de vida dos cards SwiftUI.

Critério: navegar rapidamente por artistas não deixa uma fila crescente de
downloads antigos.

### 4. Otimizar Cover Art Archive

- solicitar thumbnail adequado ao componente;
- aplicar deadline curto e fallback;
- manter stale-while-revalidate;
- persistir `not_found`, `503` e validators separadamente;
- priorizar edição exata somente quando houver mapeamento comprovado.

Critério: o Cover Art Archive lento não monopoliza a fila nem bloqueia outras
fontes.

### 5. Integrar Apple Music

- adicionar configuração segura do Developer Token;
- implementar busca e lookup de catálogo por storefront;
- resolver primeiro por UPC e IDs persistidos;
- salvar template de URL, dimensões e link do recurso;
- solicitar a resolução final adequada ao componente;
- adicionar atribuição exigida pela plataforma.

Critério: uma correspondência Apple Music ambígua nunca substitui uma capa
existente automaticamente.

### 6. Integrar TheAudioDB

- implementar lookup por MusicBrainz Release Group ID;
- selecionar thumbnail pequeno ou médio para grids;
- persistir ID e origem do álbum;
- adicionar cache negativo e backoff;
- tratar ausência de imagem como resultado válido.

Critério: o provedor funciona como fallback e não cria associação por nome
quando existe conflito de identidade.

### 7. Spotify opcional

- implementar OAuth Authorization Code com PKCE;
- armazenar tokens no secure store;
- respeitar quotas, `429` e expiração de token;
- mostrar atribuição, marca e link Spotify junto da imagem;
- impedir recorte, overlays e uso desconectado do conteúdo associado;
- permitir ao usuário desativar e limpar todos os dados Spotify.

Critério: nenhuma requisição ou imagem Spotify existe sem configuração e
consentimento explícitos.

### 8. Rollout e seleção de política

- habilitar novos provedores individualmente por feature flag;
- registrar qual provedor venceu e por quê;
- comparar cobertura, latência, erros e falsos positivos;
- permitir preferência do usuário sem quebrar o cache offline;
- documentar limpeza e migração de assets antigos.

Critério: ativar um provedor novo não piora o p95 de abertura da página nem
reduz a precisão observada.

## Testes necessários

- cache hit, stale e revalidação em segundo plano;
- snapshot sem imagem e TTL negativo;
- fallback após timeout e `503`;
- cancelamento ao sair da página;
- deduplicação de cards simultâneos;
- alteração de geração durante download;
- UPC conflitante com artista;
- homônimos e títulos iguais em anos diferentes;
- release-group versus edição exata;
- modo offline sem tentativa de rede;
- remoção de credenciais e dados de provedor;
- atribuição e link obrigatórios para Spotify e Apple Music;
- limites de memória com centenas de cards catalogados.

## Métricas de sucesso

- tempo até conteúdo textual utilizável;
- tempo até primeira capa visível;
- tempo até todas as capas visíveis naquele viewport;
- cache hit ratio por provedor;
- taxa de fallback e `not_found`;
- requisições e bytes por abertura de artista;
- downloads cancelados antes do início;
- pico de memória durante rolagem;
- taxa de correção manual de capas incorretas.

O provedor deve ser escolhido a partir dessas medições. Cobertura nominal ou
velocidade de CDN isoladamente não justificam uma integração.
