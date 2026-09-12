# Roteiro de melhorias do enriquecimento

## Objetivo

Melhorar a atualização de perfis, discografias e capas, mantendo conformidade com as APIs externas e segurança diante de falhas de rede, conteúdo inválido e contenção no SQLite.

## Prioridades

### 1. Eliminar contenção desnecessária no SQLite — prioridade máxima

- Substituir transações `Immediate` por `Deferred` nas operações somente de leitura, especialmente no plano de capas e na leitura da discografia.
- Manter transações de escrita curtas e sem chamadas de rede ou outros `await` durante sua execução.
- Serializar publicações do enriquecimento por uma fila de escrita única ou coordenador equivalente.
- Manter WAL e `busy_timeout` como proteções, sem depender do aumento do timeout para resolver contenção estrutural.
- Implementar retry limitado com jitter apenas para operações idempotentes que retornem `SQLITE_BUSY` ou `SQLITE_LOCKED`.
- Registrar o código SQLite estendido, a operação e o tempo de espera sem incluir dados sensíveis.

Referência: [SQLite — Set a Busy Timeout](https://sqlite.org/c3ref/busy_timeout.html).

### 2. Persistir resultados negativos de capas

- Registrar separadamente `NotFound`, imagem inválida e falha temporária.
- Aplicar TTL maior para ausência confirmada e TTL curto para falhas transitórias.
- Impedir que os mesmos lançamentos sem capa ocupem continuamente o início de cada lote.
- Invalidar o resultado negativo quando a identidade, o MBID ou a geração do catálogo mudar.

O Cover Art Archive usa `404` como resposta normal quando um release ou release-group não possui uma capa apropriada.

Referência: [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API).

### 3. Transformar a atualização de capas em uma fila persistente

- Salvar cursor, estado, número de tentativas, próxima tentativa e último erro por lançamento.
- Processar lotes limitados em ordem rotativa e retomá-los após reiniciar o aplicativo.
- Permitir que um lançamento problemático seja adiado sem impedir o processamento dos seguintes.
- Expor contadores de capas concluídas, pendentes, ausentes e temporariamente bloqueadas.

### 4. Aplicar políticas específicas por erro e provedor

- Diferenciar `404`, `429/503`, timeout, falha de conexão, JSON inválido, imagem inválida e erros do SQLite.
- Usar backoff exponencial com jitter somente em erros transitórios.
- Respeitar `Retry-After` e manter cooldown compartilhado por provedor.
- Limitar o MusicBrainz a uma requisição por segundo em todo o aplicativo.
- Enviar um `User-Agent` com nome, versão e contato do projeto.
- Não repetir automaticamente erros permanentes sem mudança do identificador ou expiração do TTL.

Referências: [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API) e [MusicBrainz Rate Limiting](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting).

### 5. Exibir diagnóstico por seção no cliente

- Substituir o aviso genérico por resultados separados para perfil, retrato, discografia e capas.
- Informar o último sucesso e as quantidades concluídas e pendentes.
- Apresentar mensagens específicas, como “banco ocupado; nova tentativa agendada” ou “Cover Art Archive indisponível”.
- Fazer o botão de retry atualizar apenas as seções que falharam.
- Preservar e identificar claramente o conteúdo proveniente do cache local.

### 6. Reforçar segurança e testes de falha

- Aceitar redirects somente por HTTPS e para hosts explicitamente permitidos.
- Não encaminhar query privada, credenciais ou validadores condicionais ao trocar de origem.
- Limitar tamanho, MIME e dimensões de imagens antes de persistir os arquivos.
- Usar gravação atômica e limpeza conservadora de arquivos não referenciados.
- Testar concorrência entre scan, leitura da interface e publicação de snapshots.
- Cobrir locks do SQLite, cancelamento, reinício, redirects, rate limit, respostas malformadas e imagens excessivas.
- Manter smokes públicos opt-in para MusicBrainz, Wikimedia e Cover Art Archive.

## Ordem sugerida de implementação

1. Corrigir as transações de leitura e introduzir coordenação das escritas.
2. Adicionar testes concorrentes que reproduzam `enrichment storage database is locked`.
3. Criar o modelo persistente de resultado negativo e da fila de capas.
4. Atualizar o planejador para garantir progresso entre lotes.
5. Refinar retry, cooldown e telemetria por provedor.
6. Expor resultados detalhados no contrato UniFFI e no cliente macOS.
7. Executar a suíte completa, testes de interrupção e smokes públicos opt-in.

## Critérios de conclusão

- Leituras da discografia não disputam o lock de escrita.
- Atualizações concorrentes não apresentam `database is locked` em condições normais.
- Todo lote de capas progride mesmo quando os primeiros lançamentos não possuem imagem.
- Falhas permanentes e transitórias possuem políticas distintas e observáveis.
- O cliente identifica qual seção falhou sem descartar o cache válido.
- Limites, redirects e identificação dos provedores seguem suas APIs oficiais.
