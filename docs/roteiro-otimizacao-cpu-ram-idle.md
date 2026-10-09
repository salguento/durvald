# Roteiro de otimização de CPU e RAM em idle — macOS

Data: 09/10/2026. Referência inicial do código: commit `8e92139`.

Status: planejamento; nenhuma otimização deste roteiro foi implementada ou validada. As etapas abaixo devem gerar mudanças pequenas, com medição antes/depois e commits independentes.

## Objetivo e limites

Eliminar trabalho periódico desnecessário com reprodução pausada e buscar memória entre **50 e 70 MB** no cenário de idle de referência. Preservar navegação, qualidade das capas, reprodução, troca automática de dispositivos e atualização do catálogo.

O alvo de CPU é aparecer em **0% na maior parte do idle**, sem o padrão de picos de aproximadamente 1% a cada 2 segundos. Isso não significa garantir literalmente zero instruções ou zero wakeups: eventos do sistema e ações do usuário continuam exigindo trabalho.

A meta de memória pertence ao **processo completo**, não apenas ao heap ou ao cache de capas. Sua viabilidade precisa ser confirmada em Release. Não considerar o objetivo alcançado apenas por mudar a métrica, esconder recursos ou reduzir qualidade. Caso o custo mínimo medido dos frameworks e da janela ultrapasse o orçamento, registrar a evidência e discutir o alvo antes de mudar a experiência.

## Evidências disponíveis

- A captura do usuário mostrou CPU em 0% e memória em 119,3 MB; outra captura mostrou picos recorrentes durante idle.
- O PID `58782` estava executando `Build/Products/Debug/Durvald.app`, com `debugserver` como processo pai.
- `vmmap -summary` e uma amostragem de stacks de 5 segundos registraram footprint de 97,1 MiB e pico de 169,6 MiB. São observações pontuais, não um baseline nem prova de vazamento.
- A thread principal apareceu predominantemente aguardando eventos. A amostra também identificou `DurvaldCoreStore.startAudioOutputPolling(using:)` chamando `audioOutputState()`.
- Esse loop consulta as saídas de áudio a cada **2 segundos**. É o principal suspeito para a cadência relatada; a contribuição exata precisa ser isolada por medição antes/depois.
- A reconciliação de playback já usa **5 segundos em idle** e **1 segundo durante reprodução**. Não confundir esse loop com o de dispositivos.
- `ArtworkRepository` já limita o cache a **64 MiB / 600 entradas**, usa thumbnails por buckets e serializa cargas. O limite não significa ocupação real de 64 MiB.
- O baseline histórico de 27/09/2026 registrou RSS média de 118,20 MiB em Release. RSS não é diretamente comparável ao footprint nem ao indicador de memória do Xcode; esse resultado não comprova a meta de 50–70 MB.

## 1. Estabelecer baseline reproduzível — P0

### Implementação do diagnóstico

1. Construir Release e executar fora do Xcode, sem debugger e sem outras instâncias do Durvald. Registrar também se o core Rust está otimizado; não assumir que a configuração Release do cliente garante a do core.
2. Fixar hardware, macOS, biblioteca, dimensões da janela, tela aberta, escala e estado do player. Desativar operações de scan/enriquecimento durante a fase de referência, sem alterar configurações persistentes sem autorização.
3. Separar inicialização/aquecimento do idle estável: aguardar 60 segundos e medir pelo menos 5 minutos. Executar três rodadas por cenário e apresentar mediana, extremos e série temporal.
4. Usar **physical footprint** como métrica principal. Registrar RSS separadamente; declarar unidades. Para comparar com a meta em MB, converter MiB explicitamente: `1 MiB = 1.048576 MB`.
5. Medir CPU média, p95, máximo e periodicidade dos picos; complementar com wakeups e stacks no Instruments. Realizar também uma rodada sem profiler para avaliar interferência da ferramenta.
6. Estender o script existente `durvald-macos/scripts/measure-release-performance.sh` para registrar footprint e identificar a configuração/core usados. A medição atual usa RSS e não resolve sozinha a comparação com a captura do Xcode.
7. Guardar relatórios com commit, condições, timestamps e tamanho do catálogo. Evitar caminhos de arquivos pessoais, nomes de faixas e credenciais nos diagnósticos compartilhados.

### Cenários obrigatórios

| Cenário | Condição | O que verificar |
| --- | --- | --- |
| Idle inicial | Início, player pausado, sem navegação prévia | Custo mínimo da janela e inicialização |
| Idle de referência | Músicas, player pausado, mesma biblioteca do usuário | Meta de 50–70 MB e ausência da cadência de 2 s |
| Idle após uso | Visitar Álbuns/Artistas/Histórico, rolar capas e voltar | Retenção, caches e estabilização |
| Janela inativa/oculta | Mesmo catálogo, reprodução pausada | Trabalho de UI desnecessário |
| Reprodução | Mesma faixa e dispositivo | CPU, memória e continuidade do áudio |
| Catálogo grande | Biblioteca representativa maior | Crescimento e limites por componente |

**Entrega:** baseline por cenário, com artefatos brutos. Os valores de Debug da sessão ficam como diagnóstico auxiliar, nunca como comparação definitiva com Release.

## 2. Substituir polling de dispositivos por eventos — CPU, P1

### Arquivos principais

- `durvald-macos/Durvald/Durvald/CoreBridge/DurvaldCoreStore.swift`
- `durvald-core/src/application/settings.rs`
- `durvald-core/src/audio/player.rs`
- Novo coordenador macOS de observação de dispositivos, se necessário.

### Implementação

1. Adotar listeners nativos do Core Audio para mudanças na lista de dispositivos e na saída padrão. Verificar quais propriedades adicionais são necessárias para disponibilidade do dispositivo selecionado.
2. Preferir, inicialmente, um coordenador no cliente macOS que sinalize o core pelo contrato existente. Se a responsabilidade for movida ao Rust, definir primeiro o contrato de eventos e manter os outros clientes funcionais; não criar observadores duplicados.
3. Registrar listeners **antes** da leitura inicial; reconciliar eventos ocorridos durante essa leitura para não perder mudanças.
4. Encaminhar callbacks para uma fila apropriada e agrupar notificações próximas. Não consultar SQLite, reconstruir o player ou atualizar SwiftUI dentro do callback de áudio.
5. Manter no máximo uma reconciliação em andamento; se outro evento chegar, marcar uma atualização pendente e executar novamente ao término. Evitar perder o último evento por cancelamento/debounce.
6. Remover o timer permanente de 2 segundos após validar os listeners. Manter refresh explícito ao abrir os ajustes de áudio e ao retomar a aplicação após suspensão.
7. Caso o registro falhe, oferecer reconciliação sob demanda ou fallback de baixa frequência, com erro observável. O fallback não pode reintroduzir silenciosamente a cadência atual.
8. Publicar estado somente quando mudar. Remover listeners na troca do core e no encerramento; descartar callbacks de gerações anteriores.
9. No core, revisar a enumeração repetida entre `reconcile_output_device()` e `output_state()`. Reutilizar o snapshot da mesma reconciliação quando seguro, sem congelar a descoberta de dispositivos.

### Testes e aceite

- Testes determinísticos com fonte de eventos fake: inicialização, rajadas, evento durante refresh, cancelamento, troca de core e falha de registro.
- Contador de chamadas: depois da leitura inicial, **nenhuma consulta periódica de saídas** em 5 minutos de idle sem eventos.
- Integração: mudar saída padrão, conectar/desconectar USB/Bluetooth, remover dispositivo preferido, verificar fallback e reconectar; testar também durante reprodução e após sleep/wake.
- Não admitir perda de áudio, troca involuntária de preferência ou travamento da interface.
- Comparar CPU/wakeups antes/depois. A hipótese só é confirmada se a remoção do loop eliminar ou reduzir o padrão de picos observado.

## 3. Auditar trabalho restante em idle — CPU, P2

1. Inventariar timers, `Task.sleep`, callbacks recorrentes e tarefas de telas ocultas. Priorizar o que aparecer em stacks/signposts; não remover loops apenas por existirem.
2. Medir o polling de playback de 5 segundos separadamente. Preservar avanço automático, atualizações do histórico e ações externas. Se substituído por eventos, garantir um contrato completo antes de retirar a reconciliação.
3. Verificar que espectro/animações não continuam ativos com reprodução pausada ou sem consumidores visíveis. Preservar o compartilhamento já existente em `SpectrumPollingCoordinator`.
4. Evitar publicações Observation/SwiftUI para snapshots idênticos e reconstruções da tabela por mudanças não relacionadas.
5. Revisar tarefas canceladas que mantêm referências ao store durante espera; garantir encerramento sem ciclos de retenção ou loops duplicados.
6. Manter watcher de biblioteca baseado em eventos e suas proteções de debounce/reconexão. Não sacrificar atualizações externas para alcançar 0% visual.

**Testes:** fake clock/eventos para frequência e cancelamento, identidade da tabela, navegação repetida, progresso/seek/fila/histórico, janela oculta e reprodução. Aceitar apenas mudanças com redução medida e comportamento preservado.

## 4. Localizar retenção e composição da memória — RAM, P1

### Diagnóstico antes de reduzir limites

1. Usar Allocations, VM Tracker e Memory Graph em uma sessão separada do baseline de Release. Marcar gerações antes/depois de dez ciclos idênticos de navegação e rolagem.
2. Classificar memória de imagens decodificadas, arrays/índices de catálogo, hosts/células SwiftUI, superfícies gráficas, áudio, SQLite e buffers FFI. Separar objetos vivos de memória livre retida pelo allocator.
3. Adicionar contadores leves, sob diagnóstico, para ocupação real dos caches, entradas, cargas em andamento, consumidores e tarefas. O custo estimado do cache não substitui o footprint do processo.
4. Inspecionar retenções por singletons, closures, tasks, observers e views desmontadas. Um plateau após aquecimento é diferente de crescimento contínuo.
5. Medir o custo de cada tela e do fundo translúcido. Não atribuir o aumento à reordenação de colunas ou aos materiais sem comparação controlada.

**Entrega:** ranking dos maiores consumidores, relação com o fluxo de uso e orçamento proposto. Só priorizar uma correção depois de identificar seu custo e proprietário.

## 5. Ajustar cache e ciclo de vida das capas — RAM, P2

### Arquivos principais

- `Features/Player/ArtworkRepository.swift`
- `Features/Player/OrderedKeyedQueue.swift`
- `Features/Player/ArtworkView.swift`
- `CoreBridge/FileImportService.swift`

### Implementação

1. Comparar, experimentalmente, orçamentos de 64, 32 e 16 MiB com a mesma navegação. Escolher o menor que preserve fluidez e não aumente significativamente decodificação, CPU ou leituras de disco. Esses valores são candidatos, não ganhos garantidos.
2. Conferir contabilidade das representações decodificadas, buckets simultâneos e imagens retidas pelas views fora do cache. Diminuir o LRU não libera uma imagem ainda referenciada pela tela.
3. Manter ImageIO/downsampling no tamanho solicitado, deduplicação de requests, cancelamento por consumidor e uma carga de fonte completa por vez.
4. Liberar a imagem/request de views desmontadas ou reutilizadas quando necessário. Não apagar a capa visível do player nem introduzir flashes ao navegar.
5. Acrescentar trim explícito ao LRU, se o diagnóstico justificar, e resposta a pressão de memória do macOS. Reduzir entradas inativas primeiro; não esvaziar tudo a cada mudança de foco.
6. Não reter base64, bytes originais ou múltiplas representações maiores que a necessidade após a decodificação.

**Testes:** orçamento em bytes/quantidade, evicção e trim, pressão de memória simulada, cancelamento parcial/total, reutilização de células e requests concorrentes. Validar capas nítidas, ausência de flashes e quantidade de decodes em rolagem de ida/volta.

## 6. Reduzir retenção de catálogo e telas — RAM, P2

1. Mapear duplicação entre `DurvaldCoreStore`, `CatalogPageCache`, `MusicLibraryPresentation`, histórico e apresentações de artistas/álbuns.
2. Preservar caches compartilhados e deduplicação já implementados. Evitar trocar retenção limitada por consultas completas a cada visita.
3. Reduzir payloads e índices redundantes com ownership explícito, revisões escalares e índices por ID onde houver ganho comprovado.
4. Se snapshots completos forem o custo dominante em bibliotecas grandes, planejar busca/agregação paginadas no core. Preservar pesquisa global, totais, favoritos e ordenação; não restringir essas funções às páginas visíveis.
5. Cancelar workers sem consumidores quando seguro e liberar buffers temporários/objetos de importação ao terminar. Proteger consumidores concorrentes e rejeitar resultados de revisões antigas.
6. Corrigir ciclos de retenção comprovados antes de mudanças arquiteturais. Não forçar limpeza do allocator nem reiniciar o core para maquiar o consumo.

**Testes:** `CatalogRepositoryTests`, `MusicLibraryPerformanceTests`, histórico, pesquisa global, metadados, navegação/rolagem e liberação com referências fracas. Repetir o teste de dez ciclos e verificar estabilização, não apenas uma queda pontual.

## 7. Critérios finais de aprovação e sequência

Ordem proposta: **baseline → eventos de áudio → auditoria dos demais wakeups → perfil de memória → cache de capas → retenção de catálogo/telas → medição final**. As fases de CPU e diagnóstico de RAM podem ser investigadas em paralelo, mas medir uma mudança por vez.

- CPU: no cenário de referência, meta inicial de média ≤ 0,1% em 5 minutos de Release; ausência dos picos regulares atribuídos ao polling de áudio. Avaliar wakeups também. Esse limiar é um alvo de projeto, não garantia do sistema.
- RAM: buscar 50–70 MB de footprint no idle de referência, registrar mínimo/mediana/pico e confirmar nas três rodadas. Reportar idle inicial e após uso separadamente; não aplicar o mesmo limite ao playback/scan sem medir suas necessidades.
- Estabilidade: dez ciclos iguais de navegação não devem produzir crescimento progressivo de objetos vivos após aquecimento. Documentar variação de footprint e origem das retenções restantes.
- Regressões: sem falhas funcionais; comparar abertura, navegação, rolagem, CPU de playback, I/O e decodes. Definir margens de regressão a partir da variabilidade do baseline antes de escolher a configuração final.
- Executar testes Swift relevantes e testes Rust de áudio/settings, além de build Release. Testes funcionais aprovados não substituem perfil de performance.
- Para cada etapa, informar previamente os testes ao usuário. Solicitar vídeo para picos recorrentes/rolagem/piscadas e capturas antes/depois com versão, tela, tempo desde abertura e estado do player. Capturas são apoio, não substituem séries temporais e traces.
- Se um ajuste de RAM aumentar CPU ou produzir recargas visíveis, reverter/reduzir o ajuste e registrar o trade-off. Manter mudanças pequenas e recuperáveis.

## Referências

- [Baseline Release e protocolo existente](../durvald-core/docs/performance-release-baseline.md).
- [Mapeamento e otimizações já realizadas no cliente](mapeamento-implementacao-macos.md).
- [Apple — AudioObjectAddPropertyListenerBlock](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)): API nativa para observação das propriedades de áudio; verificar registro e remoção no SDK usado pelo projeto.
- [Apple — Reducing your app’s memory use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-memory-use): orientação para diagnóstico e redução de memória.
- [Apple — TN2434: Minimizing your app’s Memory Footprint](https://developer.apple.com/library/archive/technotes/tn2434/_index.html): referência de análise de alocações e footprint.
