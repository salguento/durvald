# Baseline de performance em Release

Esta medição executa o aplicativo Release diretamente, fora do Xcode e sem
`debugserver`. O resultado registra tempo até a primeira janela visível,
amostras de CPU e memória residente, crescimento do SQLite WAL e uma fase de
reprodução real.

## Preparação

Construa em um diretório descartável, sem iniciar testes:

```bash
xcodebuild \
  -project /Users/salguento/Developer/durvald/durvald-macos/Durvald/Durvald.xcodeproj \
  -scheme Durvald \
  -configuration Release \
  -derivedDataPath /tmp/DurvaldReleaseDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Feche outras instâncias do Durvald. O acesso do Terminal a Automação deve estar
habilitado para medir a primeira janela por `System Events`; sem essa permissão,
as demais métricas continuam válidas e `startup_seconds` fica indisponível.

## Execução

```bash
/Users/salguento/Developer/durvald/durvald-macos/scripts/measure-release-performance.sh \
  --app /tmp/DurvaldReleaseDerivedData/Build/Products/Release/Durvald.app \
  --database "$HOME/Library/Application Support/Durvald/music.db3" \
  --idle-seconds 30 \
  --play-seconds 60
```

Após a fase idle, inicie uma faixa local representativa e pressione Enter. O
script mede a reprodução sem fixtures Debug. Para medir somente abertura e
idle, acrescente `--skip-playback`.

Cada execução cria um diretório `/tmp/durvald-perf-AAAAMMDD-HHMMSS` contendo:

- `samples.csv`: CPU, RSS e WAL por amostra e por fase;
- `summary.txt`: tempo de inicialização, médias e máximos;
- `app.stdout.log` e `app.stderr.log`: diagnóstico do processo Release.

## Protocolo de referência

Execute três vezes com a mesma biblioteca e descarte a primeira execução se ela
incluir aquecimento de caches do sistema. Registre a mediana das duas execuções
restantes. Use a mesma faixa, volume, tamanho da janela e duração em comparações
antes/depois. Não execute scan ou enriquecimento durante o baseline de idle; se
essas operações forem avaliadas, registre-as como fases separadas.

Uma comparação só deve ser considerada melhoria quando reduzir uma métrica sem
regressão observável nas demais. CPU máxima isolada é secundária; priorize CPU
média por fase, RSS máxima, tempo até a janela e crescimento do WAL.

## Baseline preliminar — 27/09/2026

Primeira execução no commit `c02224e`, macOS 27.0 em arm64, com 30 segundos de
idle e 60 segundos de reprodução:

| Métrica | Idle | Reprodução |
| --- | ---: | ---: |
| CPU média | 1,05% | 13,98% |
| CPU máxima | 13,00% | 16,20% |
| CPU média nas últimas 10 amostras | 0,10% | 13,95% |
| RSS média | 118,20 MiB | 174,47 MiB |
| RSS máxima | 124,11 MiB | 177,70 MiB |
| RSS na primeira/última amostra | 120,94 / 116,59 MiB | 177,67 / 165,19 MiB |
| WAL ao final | 0 bytes | 477.952 bytes |

O tempo até a primeira janela visível foi 11,880 segundos. Esse valor deve ser
confirmado nas execuções seguintes porque inclui abertura do processo, carga do
sistema e eventual aquecimento de caches. A CPU idle caiu para 0,10% nas dez
amostras finais, indicando que o pico de 13% pertence à inicialização e não a
trabalho permanente. Durante reprodução, a CPU permaneceu próxima de 14%; esse
é o principal custo sustentado ainda mensurável. RSS e WAL diminuíram ou ficaram
estáveis dentro de cada fase, sem evidência de crescimento contínuo nesta janela.

Resultado bruto: `/tmp/durvald-perf-20260927-181532`.
