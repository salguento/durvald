# Soulseek real: transferência, importação e reinício

Data: 28/10/2026. Implementação da primeira pendência da
[avaliação do roteiro](../avaliacao-roteiro-integracoes-musicais.md), no recorte
solicitado pelo usuário: **uma faixa para a prova**.

## Resultado

Uma oferta individual foi selecionada a partir do álbum indicado pelo usuário.
A busca do próprio core reencontrou o peer, nome e tamanho exatos antes do envio.
O slskd real **0.26.2.0** confirmou a transferência de **8.378.198 bytes**. O
arquivo MP3 foi localizado no mapeamento local, decodificado e importado mediante
revisão numa biblioteca isolada. Não houve alteração da biblioteca pessoal.

Três processos reais separados usaram as APIs públicas `DurvaldCore`:

1. **Transferência:** configurar a instância isolada, pesquisar, reencontrar a
   oferta selecionada, enfileirar só o arquivo confirmado e observar conclusão.
   A biblioteca permaneceu vazia até a ação de importação.
2. **Importação após reinício:** reabrir banco/diário, recuperar o lote concluído,
   localizar o arquivo somente dentro do destino daquele lote, validar o áudio,
   obter revisão e confirmar a cópia/importação. Marcar favorito de teste.
3. **Reimportação após novo reinício:** recuperar o recibo `Imported`, repetir a
   confirmação e verificar a mesma faixa, as mesmas origens e o favorito
   preservado. Permaneceu **uma única faixa canônica**.

As três fases confirmaram remoção da credencial isolada ao sair. Não foi iniciada
reprodução, scrobble, compartilhamento de biblioteca, instalação ou criação de
conta. O backend temporário de validação foi encerrado depois da prova. Os
arquivos de prova e o diário privado foram preservados, sem mover/apagar o
original recebido no slskd.

[Evidência positiva](../evidence/provider-probes/slskd-acquisition-live-retest-2026-10-28.json).
O [primeiro ensaio](../evidence/provider-probes/slskd-acquisition-live-2026-10-28.json)
ficou limitado antes de criar lote; a limpeza não encontrou downloads a cancelar.
O reteste usou consulta mais específica, conservando a seleção exata. Não se
atribui uma causa definitiva à primeira falha nem se substitui seu registro por
sucesso. Consultas, peer e caminhos permanecem privados.

## Executor reproduzível

- `durvald-core/examples/soulseek_acquisition_probe.rs`: mesmas APIs de produção
  usadas pelo aplicativo para busca, transferência, revisão e importação; não
  chama diretamente endpoints de transferência para contornar o core.
- `tools/provider-probes/live_acquisition.py`: valida seleção, verifica backend
  fixado/autenticado, prepara biblioteca privada e coordena três processos.
- Backend: instalação local de validação já existente, sem compartilhamentos;
  mapeamento derivado de sua própria configuração. Não administra montagem remota.

```sh
cargo build --locked --manifest-path durvald-core/Cargo.toml --example soulseek_acquisition_probe
python3 tools/provider-probes/live_acquisition.py \
  --selection /tmp/arquivo-escolhido.json \
  --timeout 120 --report /tmp/slskd-acquisition-live.json
```

A seleção privada exige `query`, `peer`, `filename` e `size_bytes`. Não inclui
chave. O executor admite um arquivo MP3/WAV/FLAC/Ogg de até 256 MiB; rejeita
entrada incompleta, formato não aceito, traversal e tamanho desconhecido.
Nenhum resultado é escolhido automaticamente pelo executor.

O workspace `.state/acquisition/<UUID>` é privado e ignorado pelo Git. Guarda
seleção, logs, banco, arquivo importado e checkpoint de recuperação. O relatório
exportado contém checks, bytes, versão e hashes; não exporta chaves, nomes do
peer/arquivo, consulta, tokens de revisão ou caminhos locais.

Falha/timeout conserva o diário e solicita limpeza apenas dos lotes dessa
biblioteca isolada. Ausência de confirmação permanece explícita. Cada processo
remove a credencial do seu serviço isolado; a fase de limpeza pode ser chamada
separadamente para recuperação. Não encerrar transferências de outros clientes
nem remover a pasta privada enquanto houver estado incerto.

## Escopo comprovado e pendências

Esta é uma prova real pela **fachada Rust de produção**, incluindo persistência,
backend e arquivos. Não é uma nova prova visual da interface SwiftUI/UniFFI;
essa apresentação continua com a cobertura automatizada anterior.

O sucesso fecha o caminho individual **pesquisar → transferir → revisar →
importar → reiniciar → reimportar sem duplicação**, com mapeamento nativo local.
Não comprova álbum completo, cancelamento de transferência real em andamento,
retomada de bytes parciais, lote com sucesso parcial ou montagem remota.
Esses cenários continuam com cobertura de simulador e precisam de casos reais
específicos para encerrar toda a pendência operacional da etapa 12. O usuário
escolheu um único arquivo para esta execução.

A preservação real foi verificada para identidade de faixa/origem e favorito.
Ratings, tags, histórico e duplicatas de playlist mantêm a cobertura offline
anterior; não são anunciados como novos testes reais desta coleta. O SHA-256 usado
pela importação é uma verificação da cópia local, não um checksum fornecido pelo peer.

## Validação

Executor Rust compilado e aprovado no Clippy com warnings como erros. **37 testes
Python aprovados**, incluindo seleção explícita, fases em processos separados,
permissões dos logs e interrupção antes de importar quando falta recibo ou limpeza.
Os demais testes de contratos/provas continuam aprovados. Não houve mudança do
runtime, schema ou bindings; a suíte ampla Rust/macOS não foi repetida para um
executor isolado. Os hashes do relatório positivo conferem com os executores.

[Recibo final de validação](../evidence/provider-probes/slskd-acquisition-live-validation-2026-10-28.json):
SHA-256 da cópia igual ao original, metadados consistentes com o alvo, uma faixa,
uma origem local e zero eventos de histórico. Backend temporário encerrado.
