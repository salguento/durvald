# Provas técnicas de provedores — etapa 5

Executores isolados para testar viabilidade antes de implementar plugins de
produção. Não abrem o banco, a biblioteca, as preferências ou o Keychain do
Durvald. Não habilitam provedores. O helper opcional `slskd_backend.py` instala somente
o backend oficial isolado quando solicitado explicitamente.

A decisão e as limitações estão em [provas dos provedores](../../docs/features/provider-proofs.md).
Os resultados desta entrega ficam em [evidências](../../docs/evidence/provider-probes).

## Requisitos

- Python 3.10+ e biblioteca padrão para HTTP, contratos e relatórios.
- macOS com Swift/AppKit/WebKit para os players reais.
- Internet para os casos reais. Os testes de contrato usam apenas loopback.

Os players abrem janelas temporárias sem som e usam armazenamento WebKit não
persistente. SDKs e controles oficiais permanecem visíveis. Os testes executam
play, pause, resume, seek e avanço para o final; não tocam a mídia inteira em
sequência. Um teste positivo não garante acesso completo a qualquer outro item.

## Reproduzir

A partir da raiz do repositório:

```sh
python3 -m unittest discover -s tools/provider-probes/tests -v

python3 tools/provider-probes/probe.py browser soundcloud --item 293 --report /tmp/durvald-proofs/soundcloud-widget.json
python3 tools/provider-probes/probe.py browser soundcloud --item 999999999999999999 --case unavailable --report /tmp/durvald-proofs/soundcloud-unavailable.json

python3 tools/provider-probes/probe.py browser youtube --item M7lc1UVf-VE --report /tmp/durvald-proofs/youtube-playback.json
python3 tools/provider-probes/probe.py browser youtube --item 00000000000 --case unavailable --report /tmp/durvald-proofs/youtube-unavailable.json

python3 tools/provider-probes/probe.py bandcamp --url https://benprunty.bandcamp.com/track/civil-explore --report /tmp/durvald-proofs/bandcamp-public.json
python3 tools/provider-probes/probe.py slskd-fixture --report /tmp/durvald-proofs/slskd-contract-fixture.json
python3 tools/provider-probes/probe.py slskd --report /tmp/durvald-proofs/slskd-live.json
python3 tools/provider-probes/probe.py soundcloud-api --track-id 293 --report /tmp/durvald-proofs/soundcloud-api.json

python3 tools/provider-probes/matrix.py --evidence-dir /tmp/durvald-proofs --report /tmp/durvald-proofs/matrix.json
```

O caso de indisponibilidade SoundCloud observa o evento genérico `ERROR` do
widget para um ID inexistente; não atribui um código HTTP ou motivo que o SDK não
expõe. O YouTube registra seu código de erro. Falha em carregar SDK, ausência de
eventos, autoplay bloqueado e tempo esgotado não contam como reprodução aprovada.

O campo `status` do JSON é o resultado da prova; a conclusão do processo, por si
só, não indica que uma capacidade foi validada. `limited` mantém evidência parcial.
Os relatórios registram data UTC, ambiente, hashes dos executores e eventos;
SDKs remotos sem versão pública são identificados como tal. A matriz rejeita
resultados de código diferente, identidade de provedor incorreta, controles
incompletos e simulações como substitutos de execução real.

## Credenciais e backend real

As variáveis `SLSKD_URL` e `SLSKD_API_KEY` configuram o backend. `SLSKD_URL` pode
conter o prefixo da instalação; `/api/v0` é acrescentado se necessário.
`SOUNDCLOUD_ACCESS_TOKEN` configura a prova da API OAuth. Forneça as variáveis ao
processo no ambiente local. As ferramentas não solicitam nem persistem esses
valores. Credenciais ausentes produzem `blocked`, sem chamada HTTP.

A prova slskd faz uma busca curta identificada por UUID próprio, acompanha
respostas e cancela/remove somente essa busca. Consultas podem ser escolhidas
com `--query`. O contrato de referência é slskd 0.26.2; a versão do backend real
é lida e registrada quando há configuração.

A transferência real exige alvo individual explícito e mapeamento do destino:

```sh
python3 tools/provider-probes/probe.py slskd-transfer \
  --username 'PEER_ESCOLHIDO' --filename 'pasta\arquivo.flac' --size 123456 \
  --completed-remote-path /downloads/pasta/arquivo.flac \
  --remote-root /downloads --local-root /Volumes/downloads \
  --polls 20 --interval 2 --report /tmp/durvald-proofs/slskd-transfer.json
```

Use dados reais do arquivo escolhido, incluindo tamanho e destino configurado
no backend. Não há download automático dos resultados de busca. Um arquivo já
em transferência não é reutilizado/cancelado pelo teste. A identidade vem do lote
criado pela prova, e somente sua transferência pode ser cancelada ao esgotar o
prazo. Se o cancelamento falhar, o relatório preserva os UUIDs necessários para
verificação no backend, sem credenciais ou nome do peer.

A API de transferências não fornece um caminho de destino local resolvido.
`filename` representa o nome no peer; não é tratado como destino no computador.
Depois da conclusão, a ferramenta verifica o mapeamento explícito, arquivo
regular, tamanho e hash observado. O hash não é uma comparação com um checksum
fornecido pela origem. Traversal, symlinks fora da raiz e arquivos incompletos
falham. O mapeamento atual aceita caminhos POSIX do backend; caminhos Windows
não são reinterpretados silenciosamente.

## Limites e interpretação

- O fixture slskd é um servidor HTTP local que simula o protocolo e produz um
  arquivo sintético de 64 bytes. Não comprova rede Soulseek, codecs ou um backend
  slskd real. `full_backend_validation` permanece falso.
- O widget SoundCloud não comprova a API OAuth, AAC/HLS no player Rust, acesso
  completo em vez de prévia ou disponibilidade de outro item.
- Vídeo YouTube incorporado não equivale a áudio isolado nem a download.
- Bandcamp verifica página individual e referência de embed; não extrai mídia
  temporária nem transforma a API de contas em uma API de catálogo geral.
- Relatórios não contêm tokens, headers de autorização, corpos de erro do
  serviço ou URLs assinadas de mídia. As URLs públicas dos casos são registradas.
- Não há validação de distribuição assinada, App Sandbox ou notarização. O
  executor Swift é uma prova de desenvolvimento, não um componente distribuído.
- yt-dlp e FFmpeg não foram adotados. Não há download/execução ou atualizador de
  binários externos nesta entrega.

## Backend nativo slskd preparado

`slskd_backend.py` instala a versão 0.26.2 para macOS ARM64, confere o checksum
publicado e mantém o estado em `.state/slskd/`, ignorado pelo Git. A conta de
validação e as chaves são preservadas em arquivos privados (0600), dentro de
uma pasta 0700. A API fica em loopback; nenhum diretório de música é compartilhado.
A chave local usa a função Administrator porque o GET de estado do servidor
exige essa função na versão verificada. A configuração remota fica desabilitada.

```sh
python3 tools/provider-probes/slskd_backend.py install
python3 tools/provider-probes/slskd_backend.py configure --new-test-account
python3 tools/provider-probes/slskd_backend.py start
python3 tools/provider-probes/slskd_backend.py status
python3 tools/provider-probes/slskd_backend.py probe --query 'debussy arabesque' --report /tmp/durvald-proofs/slskd-live.json
python3 tools/provider-probes/slskd_backend.py stop
```

`--new-test-account` gera credenciais apenas se ainda não houver uma conta local;
a primeira conexão estabelece a conta na rede. Não execute essa opção para criar
contas sem autorização. As provas pelo helper leem a chave privada internamente,
sem exigir que ela seja colada em comandos ou no chat. O painel local usa as
credenciais web do arquivo privado `.state/slskd/credentials.json`.

O comando `configure` também aceita `--server-address` e `--server-port`.
Alterações devem ser feitas com o backend parado. `stop` verifica a identidade
do processo antes de encerrá-lo. Não foi registrado serviço de inicialização.

Nesta entrega, a API e o login foram comprovados, mas houve timeouts e buscas
sem respostas. A investigação foi cancelada pelo usuário, e o backend está
parado. A configuração permanece disponível para retomar em outra rede.

## Estabilização — etapa 15

`measure_integrations.py` mede o core Release com biblioteca sintética e áudio
nativo silencioso; não consulta provedores. Compile o exemplo `integration_baseline`
antes de executar. `--report` exige caminho novo. Budgets, interpretação e
limitações: [estabilização](../../docs/features/integration-stabilization.md).
`slskd_backend.py verify` verifica a instalação fixada sem rede nem execução.
Instalações incompatíveis/modificadas não são substituídas automaticamente;
falha de prontidão encerra apenas o processo iniciado pela própria chamada.
