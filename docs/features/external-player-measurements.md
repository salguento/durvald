# Medições reais dos players externos — 28/10/2026

Complemento da [estabilização das integrações](integration-stabilization.md).
O executor `tools/provider-probes/measure_external_players.py` mede os players
oficiais SoundCloud e YouTube em WKWebView visível, com áudio silencioso,
sem conta, cookies persistentes, banco ou biblioteca do Durvald.

## Protocolo e atribuição

O executor compila um aplicativo temporário com otimização Swift (`-O`) e o
inicia por LaunchServices. Isso fornece responsabilidade de processo própria,
independente do Terminal/Codex. A coleta verifica essa identidade usando a função
local do macOS `responsibility_get_pid_responsible_for_pid`; só inclui o processo
principal e novos processos WebKit cuja responsabilidade corresponde ao app.
Não usa a soma de todos os processos WebKit do computador. A função é usada
apenas pela ferramenta de desenvolvimento, pode ficar indisponível em outro
macOS e não integra o aplicativo distribuído. Se a atribuição falha, a medição
não é aprovada silenciosamente com números globais da máquina.

Cada rodada usa novo armazenamento WebKit não persistente: 5 s de janela vazia,
carregamento do SDK/item, 20 s de reprodução após observar avanço, 10 s de pausa,
retomada com avanço e seek para até 60 s. São os exemplos públicos usados nas
provas anteriores: SoundCloud `293` e YouTube `M7lc1UVf-VE`. Vídeo, controles e
links oficiais permanecem visíveis; não há extração de áudio ou download para a
biblioteca. As três rodadas por serviço são sequenciais, sem builds/testes
concorrentes. Caches de DNS, sistema, CDN e infraestrutura remota não são limpos;
não se chama esse estado de cache físico frio nem de rede dedicada.

Os recursos são amostrados a cada aproximadamente 500 ms. CPU é a diferença
de tempo de CPU dos processos atribuídos, dividida pelo intervalo; 100% equivale
a um core. RAM é soma de RSS, que pode contar páginas compartilhadas mais de uma
vez. Cada fase tem erro de fronteira de uma amostra e inclui o custo do polling
de diagnóstico. Pausa significa **player carregado e pausado**, não WebView
fechado nem idle do aplicativo completo.

`nettop` acompanha contadores externos TCP e UDP por processo a cada segundo.
São preservados somente totais dos processos atribuídos, sem nomes de outros
apps, endereços, cabeçalhos, payloads, URLs temporárias, tokens ou cookies. O
relatório contém os IDs públicos dos dois casos. Contadores observacionais podem
perder processos/conexões muito curtos entre amostras; não são captura de pacotes.
Bytes recebidos/enviados incluem SDK, metadados, mídia, pré-carregamento,
publicidade e controles. **Total da rodada não é bitrate de 20 s de áudio/vídeo**
nem a velocidade máxima da conexão; o SDK escolhe qualidade e pré-carregamento.

Ao encerrar, o executor espera cinco segundos e verifica processos atribuídos
remanescentes. Não encerra processos WebKit de outros aplicativos. Ausência de
processos remanescentes nessa janela não comprova estabilidade por horas.

## Latência e buffering

`page_to_ready_ms` começa quando o JavaScript da página de diagnóstico inicia.
`play_to_progress_ms` começa no pedido explícito de play e termina ao observar
avanço maior que 100 ms em relação à primeira posição. As leituras ocorrem a
cada 250 ms; isso inclui buffering/SDK e resolução de observação, sem medir
latência acústica. READY/PLAY sozinhos não aprovam avanço. Retomada e seek têm
medições próprias; seek confirma posição, não renderização acústica no destino.

Durante reprodução/retomada, uma janela sem avanço observado por mais de um
segundo conta como possível stall. Isso não detecta toda interrupção inferior a
um segundo, silêncio na gravação ou falha de decodificação que o SDK não reporte.
Eventos de buffering do YouTube são preservados; o SoundCloud não oferece aqui
uma medida equivalente de buffer decodificado.

As três repetições geram intervalos mínimo/máximo observados, **não um p95
estatisticamente representativo** nem um SLO de provedor. O objetivo é preencher
a ausência de medição real e fornecer um baseline reproduzível para comparações.
Não comprova integralidade da faixa, plano/autenticação, restrições de outros
itens, término/FINISH, áudio nativo direto ou distribuição notarizada.

## Reproduzir

macOS, Xcode/Swift, Python 3.10+ e acesso aos SDKs/CDNs dos serviços:

```sh
python3 tools/provider-probes/measure_external_players.py \
  --runs 3 --network-label 'rede de referência identificada pelo operador' \
  --report /tmp/durvald-external-player-metrics.json
python3 -m unittest discover -s tools/provider-probes/tests -v
```

`--provider soundcloud` ou `--provider youtube` restringe a execução.
O relatório exige destino novo e registra OS/hardware, hashes dos executores,
checks funcionais, intervalos, amostras de CPU/RSS, bytes e limpeza. Se houver
rede bloqueada, credencial/restrição do serviço, ausência de avanço, falha de
atribuição ou coleta, o resultado fica `limited`/`blocked`; HTTP 200 do SDK não
substitui reprodução observada. Nenhuma integração é habilitada por essa prova.

## Evidência

[Evidência com três rodadas por serviço](../evidence/provider-probes/external-player-metrics-2026-10-28.json).
O snapshot anterior da etapa 15 continua preservado com as pendências que
existiam naquele momento; este relatório é a evidência posterior, por modo/item.

## Resultado desta coleta

**Seis rodadas medidas: três SoundCloud e três YouTube, sem timeout.**
Mac17,3 ARM64, macOS 27.2. Wi-Fi conferido ao final, sem registrar SSID/IP.
A rede atual permitiu SDKs e mídia; não foi medida a
capacidade máxima do link nem identificada a causa das restrições históricas.
Qualidade/resolução de mídia permaneceu na seleção adaptativa do SDK.

| Medida observada (mínimo–máximo entre rodadas) | SoundCloud | YouTube |
| --- | ---: | ---: |
| Página JS até READY | 585–766 ms | 703–752 ms |
| Pedido de play até avanço observado | 894–1.002 ms | 1.022–1.053 ms |
| Retomada até avanço observado | 225–230 ms | 484–500 ms |
| Seek até posição observada | 14–16 ms | 12–268 ms |
| Bytes recebidos por rodada | 3,685–3,691 MiB | 4,086–4,433 MiB |
| Bytes enviados por rodada | 77,3–79,0 KiB | 149,7–158,9 KiB |
| CPU média em reprodução, em % de um core | 21,55–31,03% | 11,32–13,54% |
| CPU média com player pausado | 2,98–4,19% | 1,60–1,80% |
| RSS máxima durante reprodução | 348,00–384,92 MiB | 398,72–424,80 MiB |

Cada rodada atribuiu um processo principal e três auxiliares WebKit. Os
contadores de rede vieram do processo WebKit atribuído. Todos os checks de
READY/play/avanço/pausa/retomada/seek passaram. Foram observadas **zero janelas
sem avanço acima de um segundo**, e **zero processos atribuídos remanescentes
cinco segundos após a saída**, em todas as seis rodadas.

O modo incorporado tem custo substancialmente maior que o core nativo medido
separadamente. Os budgets do áudio local não são aplicados silenciosamente ao
WebKit. Esta coleta estabelece os intervalos observados de cada modo e permite
comparações posteriores com o mesmo executor/item; não aprova um orçamento de
banda universal nem promove recursos adicionais por padrão.

A pendência de medir banda/recursos/avanço dos **dois players nestes casos** está
coberta. Continuam fora desta prova: p95 representativo em múltiplas redes/itens,
primeira página de catálogo remoto, execução prolongada, término SoundCloud
FINISH e notarização/distribuição. A observação anterior de FINISH ausente
continua válida para aquele teste; o executor de custos não procura o fim da
faixa.

## Validação do executor

34 testes Python aprovados, incluindo parsing dos contadores sem persistir
nomes de processos, tempos sem fabricar eventos ausentes, média de CPU por
intervalo e rejeição de rodadas sem evidência. JavaScript passou em `node --check`;
Swift foi compilado com `-O` e executou os seis casos reais. Os hashes dos quatro
executores conferem com o relatório. Não houve alteração do runtime, bindings ou
biblioteca do aplicativo; a suíte Rust/macOS de produção não foi repetida para
esta coleta isolada.

[Recibo de validação e contexto de rede](../evidence/provider-probes/external-player-metrics-validation-2026-10-28.json).
