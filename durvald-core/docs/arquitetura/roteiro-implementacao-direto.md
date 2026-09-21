# Roteiro direto para a retificação da arquitetura

## Decisão executiva

A migração deve continuar como refatoração incremental dentro de uma única crate, preservando `DurvaldCore`, os DTOs públicos, `CoreError`, UniFFI e o comportamento observado pelos clientes.

O trabalho documental da Fase 0 já é suficiente para começar a implementar. Não é necessário fechar os 186 itens da matriz antes da primeira extração. O gate correto é menor:

1. proteger os contratos P0 da área que será alterada;
2. executar os gates globais de Rust, UniFFI, Swift e GTK;
3. fazer uma extração estrutural sem mudança de comportamento;
4. repetir por fatias.

A primeira fatia deve ser playback. É a área mais crítica, concentra estado e coordenação em `core.rs`, já possui testes internos reaproveitáveis e fornece um bom limite para provar o desenho de `application/` sem introduzir repositories ou um novo modelo de domínio.

## O que os documentos já decidiram

Os documentos convergem nas seguintes decisões:

- a arquitetura alvo é um monólito modular com elementos hexagonais pragmáticos;
- `DurvaldCore` permanece como fachada pública para Swift e GTK;
- casos de uso e coordenação migram gradualmente para `application/`;
- regras independentes de infraestrutura podem migrar para `domain/`, sem criar entidades artificiais;
- SQLite, áudio, HTTP, filesystem e secure storage tornam-se adapters apenas quando a extração exigir uma fronteira;
- traits só devem existir quando houver troca real, isolamento de efeitos ou necessidade concreta de testes;
- não haverá divisão em crates, novas integrações ou mudanças de produto durante a migração;
- a API protegida é `DurvaldCore` mais `api::*`, `CoreError`, UniFFI e comportamento observável;
- exports de database, áudio, Last.fm, metadata, enrichment e secure storage são dívida de superfície, mas só serão reduzidos no fim.

## Por que o processo ficou pesado

O problema não é falta de informação. É excesso de granularidade antes de produzir feedback executável.

- A Fase 0 original possui 40 subetapas e mistura inventário, infraestrutura, cobertura funcional, performance, concorrência, mapas arquiteturais e CI.
- A matriz transforma 180 casos de uso e 6 gates em 186 itens rastreáveis. Ela é útil como catálogo de risco, mas grande demais para funcionar como bloqueio integral da migração.
- Há muitos testes relevantes dentro de `src/`, mas quase nenhuma baseline pela API pública em `tests/`. Reescrever toda a cobertura antes de mover código geraria custo sem aumentar proporcionalmente a segurança.
- Os documentos detalhados descrevem corretamente o destino, mas não definem um limite de trabalho por PR nem um ponto de corte para documentação.
- Documentos de features futuras, performance, Last.fm, Soulseek e metadata contêm boas ideias, mas não devem entrar no caminho crítico desta migração.

## Regras operacionais a partir de agora

1. Não criar outro documento de análise antes de concluir a primeira extração.
2. Cada PR altera uma única fronteira arquitetural.
3. Cada PR lista os IDs da matriz realmente afetados, sem tentar fechar uma área inteira por conveniência.
4. Testes existentes são movidos ou promovidos quando protegem o contrato; não são reescritos apenas para mudar de diretório.
5. Testes de integração verificam comportamento público. Testes unitários continuam junto da regra interna quando essa é a forma mais barata e determinística de protegê-la.
6. Nenhuma PR combina refatoração com correção de bug, schema novo, otimização ou feature.
7. Uma abstração nova precisa ter um consumidor real e resolver uma dependência observada no código atual.
8. `domain/`, `ports/` e `infrastructure/` não precisam nascer completos. Eles aparecem somente quando uma fatia extraída precisar deles.
9. O tamanho de uma PR deve permitir identificar a origem de uma regressão sem investigação ampla.

## Roteiro de implementação

### Marco 1 Base mínima de testes

**Objetivo:** tornar possível abrir o core em ambiente descartável e exercitar a API pública.

**PR 1 Infraestrutura temporária**

- implementar `tests/common/filesystem.rs` e `tests/common/fixtures.rs`;
- criar paths isolados para app support, covers, library e SQLite;
- garantir cleanup automático e rejeitar destinos fora do root temporário;
- adicionar somente as fixtures exigidas pelos primeiros testes;
- testar a própria infraestrutura.

**PR 2 TestCore e smoke contracts**

- implementar um `TestCore` pequeno sobre a fachada real;
- cobrir abertura de instalação nova, diretórios, banco, defaults e reabertura;
- adicionar teste de compilação para os reexports protegidos;
- testar as variantes públicas de `CoreError`, sem congelar mensagens;
- manter geração UniFFI, build Swift e build GTK como gates.

**Gate de saída:** CORE-001–CORE-007, API-001–API-002 e FFI-003 possuem evidência; gates já existentes continuam verdes.

### Marco 2 Baseline P0 por risco

**Objetivo:** proteger somente o comportamento necessário para extrair playback com segurança.

**PR 3 Biblioteca mínima**

- fixture de áudio pequena e versionada;
- scan, leitura de track, paginação limitada, formatos suportados e symlinks;
- cancelamento parcial não remove registros;
- promover testes existentes sempre que já comprovarem o mesmo contrato.

**PR 4 Playback e sessão**

- play, pause, resume, stop, seek e volume;
- queue, next, previous, shuffle e repeat;
- proteção do item ativo em remove, move e clear;
- persistência e restauração após reabertura;
- avanço automático sem polling da UI;
- separar nos asserts navigation history de playback history.

**Gate de saída:** os P0 de Library e Playback afetados pela extração estão verdes. Não é necessário concluir P1 e P2 de outros domínios.

### Marco 3 Primeira extração arquitetural

**Objetivo:** provar o padrão com uma fatia vertical real.

**PR 5 Criar PlaybackApplication**

- criar `src/application/mod.rs` e `src/application/playback.rs`;
- mover coordenação de playback de `DurvaldCore` para `PlaybackApplication` em pequenos grupos de métodos;
- manter assinaturas públicas e DTOs inalterados;
- fazer os métodos de `DurvaldCore` apenas delegarem;
- reutilizar inicialmente pool, player e estado concretos; não criar ports nesta PR;
- executar os testes de playback a cada grupo movido.

Ordem interna sugerida:

1. snapshot e comandos simples;
2. queue e navegação;
3. persistência de sessão;
4. completion, preloading e gapless.

**Gate de saída:** comportamento público idêntico, `DurvaldCore` delegando playback, nenhuma alteração de schema ou bindings e todos os gates verdes.

### Marco 4 Segunda fatia e validação do padrão

**PR 6 Criar LibraryApplication**

- mover scan, paths de biblioteca, listagem, busca e consultas derivadas;
- manter operações SQLite concretas inicialmente;
- extrair regras puras apenas quando elas puderem ser nomeadas e testadas sem infraestrutura;
- preservar DTOs e paginação pública.

**Gate de saída:** duas aplicações seguem o mesmo padrão; a equipe consegue avaliar se a estrutura funciona antes de replicá-la.

### Marco 5 Completar a fachada por domínio

Extrair em PRs independentes, nesta ordem:

1. playlists e history;
2. metadata e artwork;
3. settings e secure storage;
4. enrichment;
5. Last.fm.

Antes de cada extração, fechar os P0 e P1 diretamente afetados daquela área. P2 entra somente quando protege o trecho alterado ou quando o risco de perda de dados ou segurança exigir.

Enrichment e Last.fm devem ficar por último porque já possuem decomposição interna, grande volume de testes e mais dependências remotas. Alterá-los cedo aumenta o raio da migração sem aliviar primeiro o acoplamento central de `DurvaldCore`.

### Marco 6 Separar modelos e infraestrutura

Somente depois de `PlaybackApplication` e `LibraryApplication` estabilizarem:

- distinguir DTO público, modelo de domínio e row de persistência onde hoje uma mesma struct acumula responsabilidades;
- introduzir IDs de domínio gradualmente, com conversão na fronteira da API;
- mover SQLite para `infrastructure/sqlite` sem reescrever queries;
- criar ports pequenos apenas para dependências que application precisa substituir ou isolar;
- manter transações e operações relacionadas coesas.

**Gate de saída:** application não depende de detalhes de row/SQL nas áreas migradas e os adapters implementam contratos pequenos e orientados a capacidade.

### Marco 7 Composição e redução da API

- concentrar construção de DB, player, HTTP, services e secure storage em um composition root;
- remover accessors concretos de `DurvaldCore` quando nenhum consumidor protegido depender deles;
- reduzir exports legados de database, áudio, Last.fm, metadata, enrichment e secure storage em mudanças explícitas;
- regenerar bindings e validar Swift e GTK após cada redução;
- documentar a arquitetura resultante em um único documento curto.

**Gate de saída:** `DurvaldCore` é uma fachada fina, casos de uso estão em `application/`, infraestrutura está atrás de fronteiras justificadas e a superfície pública contém apenas contratos deliberados.

## Gate padrão de cada PR

Toda PR da migração deve informar:

- fronteira alterada;
- IDs da matriz afetados;
- comportamento que deve permanecer igual;
- testes adicionados, promovidos ou reaproveitados;
- qualquer bug encontrado e separado para trabalho posterior.

E deve passar:

1. formatação, lint, build e testes Rust;
2. build/test com UniFFI e geração dos bindings;
3. build e testes do cliente macOS;
4. build do cliente GTK;
5. testes P0 globais e testes cobertos da área alterada.

## Itens que saem do caminho crítico

Os seguintes trabalhos permanecem no backlog e não bloqueiam a migração inicial:

- completar todos os 97 itens P1 e 39 itens P2 antes de mover código;
- baseline de performance ampla;
- mapa exhaustivo comportamento para cada função atual;
- mapa completo de dependências antes da primeira extração;
- reorganização de enrichment e Last.fm antes de playback e library;
- divisão em múltiplas crates;
- Soulseek, Jellyfin, novos formatos, novas features e correções de UI;
- cobertura de 100 por cento;
- definição antecipada de todos os ports e repositories.

## Próxima ação

Começar pela PR 1 e implementar somente a infraestrutura descrita em `test-fixtures-infrastructure.md`. Não escrever novas especificações. Ao terminar, criar o `TestCore` e a smoke baseline da PR 2. A primeira mudança de arquitetura acontece na PR 5, depois que playback possuir uma proteção P0 suficiente.

Esse corte transforma a Fase 0 de um projeto separado em uma esteira de proteção sob demanda: testar a fronteira, mover uma fatia, validar e repetir.
