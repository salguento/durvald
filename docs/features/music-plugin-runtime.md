# Registro mínimo de plugins e infraestrutura comum

Data: 27/10/2026. Etapa 2 do [roteiro unificado](../roteiro-integracoes-musicais.md).

## Entrega

O core passa a possuir um `PluginRuntime` interno desde a composição. O registro
aceita adapters Rust compilados com o projeto e começa vazio: nenhum serviço,
worker permanente ou requisição remota é iniciado ao abrir a biblioteca.

O ciclo disponível é registrar/instalar, configurar, habilitar, desabilitar e
remover. Não há marketplace, carregamento de bibliotecas de terceiros, processo
extrator, UI de plugins ou integração musical real nesta etapa. Os primeiros
adapters de catálogo pertencem à etapa 3.

## Manifesto e configuração

`domain/music/plugins.rs` define o manifesto de revisão/API `1`:

- ID estável por provedor e versão do plugin em major/minor/patch.
- Capacidades independentes de busca, detalhes/metadados, fontes e resolução
  para reprodução. O registro confere se existem os ports declarados.
- Capacidades de download, novidades e comandos extras estão reservadas;
  declará-las sem port implementado é rejeitado nesta revisão.
- Permissões de rede e credenciais. Rede declara host primário canônico para
  compartilhar cooldown; credenciais têm slots nomeados obrigatórios/opcionais.
- Campos de configuração com defaults e obrigatoriedade, além de flags booleanas
  explicitamente permitidas. Não aceitar campos, flags ou slots desconhecidos.
- Até 64 declarações de configuração/flags/credenciais; valores de configuração
  têm limite de 4 KiB. Slots de credenciais não podem ser campos de configuração.

Uma versão de API incompatível ou capacidade sem implementação é recusada antes
de registrar o adapter. Instalação nova começa desabilitada. Habilitar verifica
configuração obrigatória e credenciais. Estado habilitado não garante acesso ao
serviço: autenticação, disponibilidade e erros reais continuam sendo observados
na execução.

As permissões são contratos para adapters internos confiáveis, não um sandbox
para código arbitrário. Implementações devem usar os transportes compartilhados,
validar endpoints por serviço e manter todo trabalho dentro da future gerida.

## Persistência e plataforma

As preferências ficam em `app_support_dir/music-plugins.json`, com envelope de
versão `1`, limite de 1 MiB e até 256 registros, incluindo tombstones. O arquivo
contém habilitação, configuração não sensível e flags. O adapter usa o helper de
gravação do armazenamento existente, com substituição atômica/permissão `0600`
no macOS/Linux; não altera schema nem conteúdo da biblioteca SQLite.

Remover grava um tombstone: o registro automático do mesmo adapter no próximo
início não reinstala o plugin. Instalação explícita pode substituí-lo, voltando
aos defaults desabilitados. Os demais plugins e dados pessoais são preservados.

Credenciais usam `PlatformPluginCredentials` e o `SecureStore` existente, com
serviço `<keychain_service>.music-plugins` e nomes `music-plugin:<id>:<slot>`.
O backend é Keychain no macOS, Credential Manager no Windows e Secret Service
no Linux, conforme o armazenamento já implementado. A abertura desse armazenamento
é adiada até uma operação de credenciais; a inicialização de um registro vazio
não consulta o serviço de segredos.

Os valores passam por `PluginSecret`, com limpeza de memória ao descartar e
diagnósticos redigidos. Não são serializados em preferências ou contextos.
Alterar credenciais de um plugin ativo primeiro o desabilita e cancela tarefas
antigas; uma falha de armazenamento o mantém desabilitado. Remover limpa seus
slots. Se essa limpeza falhar, o registro permanece desabilitado para permitir
nova tentativa de remoção.

Preferências ilegíveis, excessivas ou de versão futura bloqueiam o subsistema
de plugins com erro explícito; não são sobrescritas por defaults. A composição
mantém a biblioteca local utilizável e reabrível. Já uma falha de salvar uma
configuração preserva o estado anterior, sem anunciar sucesso.

Alterações administrativas executam de forma serializada até concluir a gravação
e a atualização em memória, mesmo que o chamador descarte a future aguardada.
Isso evita commits parciais e inversão de gravações durante cancelamento. Há um
orçamento separado de até 32 comandos administrativos admitidos, para que a fila
de consultas não impeça desabilitar uma integração. O descarte de uma consulta
continua cancelando sua execução; não há worker permanente de administração.

## Tarefas, gerações e limites

Cada plugin tem geração monotônica e cancelamento próprios. Alterar configuração,
desabilitar, remover ou trocar credenciais invalida as tarefas da geração anterior.
Uma atualização com os mesmos valores ou habilitação igual é um no-op.

`RequestScope::begin()` supersede a consulta anterior daquele escopo; seu ticket
pode ser compartilhado por vários provedores da mesma pesquisa. Detalhes e
outras páginas usam escopos independentes. Tickets também permitem cancelamento
explícito; descartar o escopo cancela seu trabalho pendente.

Limites padrão:

| Recurso | Limite |
| --- | --- |
| Operações de plugins executando no core | 4 |
| Operações por plugin | 2 |
| Total admitido, incluindo espera | 32 |
| Comandos administrativos admitidos, em fila independente | 32 |
| Prazo por operação, incluindo espera e preparação | 30 segundos |
| Plugins registrados na instância | 128 |

Sobrecarga retorna `Busy`. Cancelamento ou timeout descarta a future gerida,
aborta a tarefa e libera permissões. Ao concluir, o runtime verifica novamente
geração, habilitação e ticket antes de retornar o resultado. Resultados antigos
não são promovidos a resultados da consulta/configuração atual. A UI futura
também deve respeitar o ticket ao publicar snapshots já recebidos.

O runtime encaminha busca, detalhes, fontes e resolução aos ports da etapa 1.
`PluginContext` carrega configuração imutável, geração, credenciais declaradas e
sinal de cancelamento cooperativo. Erros tipados de um adapter não afetam os
demais. O registro não possui dependência de biblioteca pessoal ou player.

## Infraestrutura compartilhada

`RemoteRequestScope` é usado tanto pelo runtime como pelo `EnrichmentService`:

- Mesma base `covers_dir/enrichment-http.sqlite`, formato de representações e
  políticas de TTL/evicção já existentes.
- Locks de requisição compartilhados por caminho canônico da base, inclusive
  entre instâncias do core, para evitar baixar a mesma representação em paralelo.
- Cooldown persistido por host; um rate limit informado pelo adapter também
  alimenta esse estado, sem ser apagado ao habilitar novamente o plugin.
- Os clientes HTTP existentes continuam usando os gates globais de provedor,
  intervalos, limites de corpo, validação de URLs, timeouts e retries já existentes.
  O runtime não adquire novamente esses mesmos gates ao redor de uma operação,
  evitando deadlock quando o adapter usa o transporte compartilhado.

O orçamento de tarefas do runtime é separado do limite de requisições HTTP:
uma tarefa pode precisar de várias chamadas, todas sujeitas ao gate do provedor.
O cache de resultados tipados de busca/paginação será construído na etapa 3;
esta entrega reaproveita as representações HTTP, sem serializar os tipos internos
de catálogo nem armazenar mídia resolvida.

## Código e compatibilidade

- `domain/music/plugins.rs`: manifesto, configuração, permissões e erros.
- `application/music_plugins/`: registro, ciclo de vida, contexto e despacho.
- `infrastructure/music_plugins.rs`: preferências, credenciais e request scope.
- `composition.rs` e `core.rs`: propriedade do runtime durante a vida do core.
- `application/music_catalog.rs`: ports recebem agora o contexto da operação.

Não foram alterados `api.rs`, UDL, DTOs nativos, bindings, fila local ou o banco
da biblioteca. A gestão permanece interna ao Rust, pronta para os consumidores
das próximas etapas. Capacidades reservadas não são anunciadas como disponíveis.
Os `allow(dead_code)` transitórios ficam limitados aos módulos de contratos/runtime
internos e ao campo ainda sem comando nativo; não mascaram lints de outras áreas.

## Validação

Os testes usam adapters falsos, relógio pausado e armazenamento temporário. Não
consultam serviços musicais nem o Keychain real. Cobrem ciclo de vida, validação
de manifesto, campos e permissões, credenciais, reinício/tombstones, filas,
cancelamento, resultados supersedidos, timeouts, falhas de armazenamento,
deduplicação de cache entre instâncias e cooldown compartilhado.

Testes pela fachada comprovam que um registro vazio não inicia credenciais e que
preferências de plugins inválidas não bloqueiam scan, leitura ou reabertura local.
O guard de arquitetura também impede dependências do runtime em biblioteca
pessoal/player. Os resultados finais dos comandos estão registrados no roteiro.

Validação executada em 27/10/2026:

- `cargo test --locked --offline --all-features --no-fail-fast`: 434 testes
  aprovados, sem falhas e sem exclusões; três testes já ignorados foram mantidos.
  São 314 unitários e 120 de integração, incluindo 17 novos testes do runtime,
  os dois novos de ciclo de vida e os seis guards arquiteturais.
- `cargo clippy --locked --offline --all-targets --all-features -- -D warnings`:
  passou sem diagnósticos.
- Formatação dos arquivos alterados, links locais e `git diff --check`: passaram.
- UniFFI foi compilado pela rodada com todas as features; não houve alteração
  de assinatura pública da fachada ou geração de bindings.

Os backends de credenciais do sistema foram integrados via o port existente;
os testes desta etapa usam substituto em memória, sem criar credenciais reais.
Não foram executados builds completos dos clientes Swift/GTK nesta entrega.
