# Checklist de funcionalidades e roteiro do Durvald

Análise atualizada em **29/09/2026**, sobre o `main` no commit `d2e7f45`.

## Escopo

Este documento avalia o Durvald como **player desktop de música local**, com foco no core em Rust e no cliente macOS. Conforme a decisão de produto, ficam fora desta análise e do roteiro:

- rádio e streaming online;
- Soulseek e download de música;
- reprodução ou gerenciamento de vídeos.

Legenda: **✅ implementado**, **🟡 parcial**, **❌ não implementado**.

## Estado atual

### Reprodução e áudio

| Funcionalidade | Estado | Evidência / limitação atual |
| --- | --- | --- |
| Reprodução de arquivos locais | ✅ | Engine própria sobre Kira/Symphonia. |
| Play, pause, resume e stop | ✅ | Core e cliente macOS. |
| Faixa anterior e próxima | ✅ | Inclui histórico interno de navegação. |
| Seek e barra de progresso | ✅ | Seek absoluto e UI com tratamento de atualização otimista. |
| Controle e persistência de volume | ✅ | Restaurado junto com a sessão. |
| Fila de reprodução | ✅ | Inserção, remoção, limpeza, reordenação, seleção direta e UI dedicada. |
| Shuffle | ✅ | Core, PlayerBar e atalhos. |
| Repeat Off / All / One | ✅ | Os três estados estão modelados e expostos na UI. |
| Retomar sessão | ✅ | Persiste faixa, posição, volume, shuffle, repeat e fila. |
| Crossfade configurável | ✅ | Configuração de ativação e duração. |
| Gapless playback | ✅ | Próxima faixa é pré-carregada e a troca ocorre no thread de áudio; metadados de delay/padding do encoder são respeitados quando disponíveis. |
| ReplayGain / normalização | ✅ | Lê `REPLAYGAIN_TRACK_GAIN` e oferece a opção “Normalizar volume”. |
| Equalizador | ❌ | Não há EQ gráfico ou paramétrico. |
| DSP / efeitos | ❌ | Não há cadeia de efeitos, compressor ou limiter. |
| Seleção de dispositivo de saída | ❌ | O backend de áudio usa o dispositivo padrão, sem seletor no domínio ou na UI. |
| Arquitetura de plugins de áudio | ❌ | Não há ABI/extensões para input, output, DSP ou visualizações. |
| Visualizações de áudio | ❌ | Não há spectrum analyzer ou oscilloscope. |

### Formatos locais

| Formato | Estado | Observação |
| --- | --- | --- |
| MP3 | ✅ | Indexação, metadados e reprodução. |
| FLAC | ✅ | Indexação, metadados e reprodução. |
| WAV | ✅ | Indexação, metadados e reprodução. |
| Ogg Vorbis / OGA | ✅ | Indexação, metadados e reprodução. |
| AAC / M4A | ❌ | Decoder não compilado. |
| ALAC | ❌ | Sem suporte de reprodução. |
| AIFF | ❌ | Sem suporte de reprodução. |
| Opus | ❌ | Sem suporte de reprodução. |
| WMA | ❌ | Sem suporte de reprodução. |

### Biblioteca e metadados

| Funcionalidade | Estado | Evidência / limitação atual |
| --- | --- | --- |
| Adicionar e remover pastas | ✅ | `NSOpenPanel`, bookmarks com security scope e tela de ajustes. Remover uma pasta não apaga automaticamente as faixas já indexadas. |
| Varredura recursiva | ✅ | Scan das pastas configuradas com fases e progresso. |
| Cancelar scan | ✅ | Cancelamento cooperativo no core e botão na UI. |
| Detectar arquivos apagados | ✅ | Scan completo reconcilia os registros; scan parcial ou cancelado não remove dados. |
| Rescan manual de todas as pastas | ✅ | “Atualizar biblioteca” está disponível nos Ajustes e no menu, reutilizando progresso, cancelamento e relatório de resultados. |
| Monitoramento automático das pastas | ✅ | FSEvents observa as raízes autorizadas; eventos são agrupados e atualizam apenas diretórios afetados, com reconexão e reconciliação periódica. |
| Leitura de metadados | ✅ | Título, artistas, álbum, gênero, ano, faixa/disco, bitrate, sample rate, bit depth e outros campos via Lofty. |
| Artwork embutido | ✅ | Extração, validação, deduplicação por hash, cache e thumbnails. |
| Editor de tags | ✅ | Tela “Info da faixa” edita título, artista, artista do álbum, álbum, gênero, ano, faixa, disco, compositor e comentário. Pode salvar só no banco ou gravar no arquivo. |
| Desfazer edição de tags | ✅ | Journal persistente, backup e ação de desfazer a última alteração. |
| Edição de tags em lote | ❌ | O editor opera em uma faixa por vez. |
| Renomear/organizar arquivos | ❌ | Não há regras de organização física por artista/álbum/faixa. |
| Detectar e mesclar duplicatas | ❌ | Não há fluxo dedicado de duplicatas. |
| Localizar/revincular arquivos movidos | ❌ | Não há reparo de caminhos quebrados. |
| Busca global | ✅ | Busca por faixas, álbuns, artistas e playlists, com UI dedicada. |
| Navegação por artista, álbum e faixa | ✅ | Telas completas no cliente macOS. |
| Paginação para bibliotecas grandes | ✅ | Faixas, álbuns e histórico são carregados em páginas; o core limita páginas a 200 itens. |
| Favoritos | ✅ | Faixas, álbuns e playlists. |
| Rating de 0 a 5 | ✅ | Faixas e álbuns podem receber ou limpar notas pela listagem, detalhes, tela de informações e menus; há ordenação, filtro mínimo e uma preferência para ocultar esses controles. |
| Play count | ✅ | Persistido no modelo de faixa. |
| Histórico de reprodução | ✅ | Persistente, paginado e com tela própria; permite remoção e limpeza. |
| Letras | ❌ | Não há leitura de letras locais nem interface de exibição. |
| MusicBrainz e enriquecimento | ✅ | Identidade de artista, discografia, perfis, artistas similares e capas com cache e políticas próprias. |

### Playlists

| Funcionalidade | Estado | Evidência / limitação atual |
| --- | --- | --- |
| Playlists manuais | ✅ | Criar, editar, excluir e adicionar/remover faixas; descrição e artwork próprios. |
| Busca dentro da playlist | ✅ | Filtro local por título, artista ou álbum. |
| Ordenação visual | ✅ | Ordem original, título, artista e duração. |
| Reordenação permanente por drag and drop | ✅ | A UI chama `movePlaylistTrack` e persiste a nova posição. |
| Importar/exportar M3U, M3U8 ou PLS | ❌ | Não há parser, exportador ou UI. |
| Smart playlists | ❌ | Não há modelo de regras ou atualização automática. |

### Integração desktop e clientes

| Funcionalidade | Estado | Evidência / limitação atual |
| --- | --- | --- |
| Atalhos de teclado do app | ✅ | Busca, play/pause, volume, shuffle, repeat, fila e navegação. |
| Menu de reprodução | ✅ | Comandos de anterior, próxima, volume, shuffle e repeat. |
| Teclas multimídia globais | ✅ | `MPRemoteCommandCenter` encaminha play, pause, toggle, anterior, próxima e seek ao store. |
| macOS Now Playing / Control Center | ✅ | `MPNowPlayingInfoCenter` publica metadados, artwork, duração, posição e estado. |
| Controles por headset e tela bloqueada | ✅ | Disponíveis pelos comandos remotos nativos do MediaPlayer. |
| Mini player em janela própria | ❌ | A PlayerBar se adapta a larguras menores, mas não existe janela compacta independente. |
| Testes automatizados do core | ✅ | Suíte Rust cobre biblioteca, reprodução, sessão, histórico e contratos públicos; CI roda em Linux e macOS. |
| Testes do cliente macOS | 🟡 | Há testes unitários e uma suíte de UI, mas a CI principal não executa explicitamente toda a suíte `DurvaldUITests`. |
| Cliente Linux | 🟡 inicial | Abre o core, mostra a quantidade de músicas e permite atualizar a leitura do banco; importação, listagem e reprodução ainda faltam. |

### Recursos clássicos de gerenciamento físico

| Funcionalidade | Estado | Prioridade sugerida |
| --- | --- | --- |
| CD ripping | ❌ | Baixa; só implementar se houver demanda comprovada. |
| Gravação de CD | ❌ | Fora do horizonte próximo. |
| Sincronização com dispositivo portátil | ❌ | Baixa; exige definição prévia de dispositivos e fluxo de arquivos. |

## Síntese de maturidade

O Durvald já é um player local funcional e tem uma base forte: reprodução completa, gapless, crossfade, ReplayGain, fila, sessão restaurável, biblioteca paginada, playlists reordenáveis, busca, histórico, edição segura de tags, Last.fm e enriquecimento externo.

Os principais gaps já não estão no playback básico. Eles se concentram em:

1. atualização automática e manutenção da biblioteca;
2. formatos comuns no ecossistema Apple;
3. ferramentas avançadas de organização e descoberta;
4. áudio avançado e escolha de hardware.

## Roteiro priorizado de features

### P0 — Fechar lacunas de uso cotidiano

Objetivo: remover atritos que aparecem diariamente e dar acabamento de aplicativo macOS.

1. **Now Playing e comandos remotos do macOS — concluído**
   - publicar título, artista, álbum, artwork, duração, posição e estado;
   - integrar play/pause, anterior, próxima e seek com `MPRemoteCommandCenter`;
   - validar teclas multimídia, headset, Control Center e tela bloqueada;
   - manter o estado sincronizado após avanço gapless, seek e restauração de sessão.

2. **Rescan manual explícito**
   - adicionar “Atualizar biblioteca” nos ajustes e/ou menu;
   - reutilizar progresso, cancelamento e tratamento de erros existentes;
   - informar resultado: novas, atualizadas, removidas e falhas;
   - impedir scans concorrentes e preservar o comportamento seguro de cancelamento.

3. **Monitoramento automático da biblioteca**
   - observar cada raiz autorizada com FSEvents;
   - agrupar eventos com debounce e disparar atualização incremental;
   - tratar criação, alteração, remoção e renomeação;
   - pausar/reconectar watchers quando bookmarks ou volumes ficarem indisponíveis;
   - manter um rescan completo periódico ou manual como mecanismo de reconciliação.

4. **Suporte a M4A/AAC e ALAC**
   - escolher e validar uma pipeline de decode compatível com a arquitetura gapless;
   - alinhar extensões aceitas, extração de metadados e playback;
   - criar fixtures para AAC-LC e ALAC, incluindo artwork e gapless metadata;
   - só anunciar o formato depois de indexação, playback, seek e transição estarem cobertos.

### P1 — Completar a gestão da biblioteca

Objetivo: transformar a boa indexação existente em uma biblioteca fácil de manter.

1. **Rating completo na UI**
   - editar e limpar notas de faixa e álbum;
   - expor rating em menus e na tela de informações;
   - permitir ordenação e filtros por nota.
   - **Concluído:** os controles podem ser ocultados nos Ajustes sem remover as notas persistidas.

2. **Edição de metadados em lote**
   - seleção múltipla com campos comuns e estado “valores diferentes”;
   - alteração parcial sem apagar tags não selecionadas;
   - journal e undo por operação em lote;
   - progresso e relatório de falhas por arquivo.

3. **Importação e exportação de playlists**
   - começar por M3U8 com caminhos relativos e absolutos;
   - resolver arquivos pelo caminho e oferecer relatório dos ausentes;
   - depois adicionar M3U legado e PLS se houver necessidade.

4. **Reparo de arquivos movidos e duplicatas**
   - identificar caminhos quebrados;
   - sugerir relink por metadados e fingerprint/hash adequado;
   - detectar duplicatas sem apagar automaticamente;
   - preservar playlists, histórico, favoritos e ratings ao mesclar registros.

5. **Smart playlists**
   - definir regras sobre rating, favorito, gênero, ano, play count, última reprodução e data de inclusão;
   - combinar regras com AND/OR e limite/ordenação;
   - atualizar resultados sem materializar cópias das faixas.

### P2 — Áudio e experiência avançada

Objetivo: aumentar controle e diferenciação sem comprometer a estabilidade do engine.

1. **Seleção de dispositivo de saída**
   - listar dispositivos e acompanhar conexão/desconexão;
   - persistir preferência com fallback seguro ao dispositivo padrão;
   - testar troca durante pause, playback, crossfade e gapless.

2. **Equalizador**
   - começar com EQ de 10 bandas, preamp, bypass e presets;
   - evitar clipping com headroom/limiter simples;
   - persistir configuração e manter custo de CPU mensurável.

3. **Letras locais**
   - ler tags embutidas e arquivos `.lrc`/texto ao lado da faixa;
   - começar com letras não sincronizadas;
   - adicionar sincronização temporal apenas depois de estabilizar leitura e UI.

4. **Mini player**
   - janela compacta independente com faixa, artwork e controles essenciais;
   - preservar fila e janela principal como uma única sessão;
   - suportar “sempre visível” como opção, sem duplicar lógica de playback.

5. **Visualização de áudio**
   - expor dados de análise do engine de forma limitada e segura;
   - começar com spectrum analyzer eficiente e desativável;
   - evitar que a renderização afete gapless ou o thread de áudio.

### P3 — Expansão e itens condicionais

Objetivo: ampliar cobertura depois que os fluxos principais estiverem maduros.

1. **AIFF e Opus**, priorizando conforme bibliotecas reais dos usuários.
2. **Organização física de arquivos**, sempre com preview, resolução de conflitos e undo.
3. **Cliente Linux funcional**, na ordem: importação, biblioteca, PlayerBar, fila e playlists.
4. **DSP adicional ou API de extensões**, somente após estabilizar uma cadeia interna de processamento.
5. **CD ripping, gravação e sincronização de dispositivos**, apenas com demanda e escopo de produto definidos.

## Ordem recomendada de execução

Para reduzir risco e entregar valor em incrementos pequenos:

1. botão de rescan manual;
2. watcher com reconciliação incremental;
3. M4A/AAC e ALAC;
4. rating completo na UI;
5. import/export M3U8;
6. edição de tags em lote;
7. seleção de saída;
8. smart playlists e reparo de biblioteca;
9. EQ, letras e mini player.

Cada etapa deve incluir testes do core quando houver regra de negócio, testes do cliente para os fluxos visíveis e atualização desta matriz quando a funcionalidade chegar ao `main`.
