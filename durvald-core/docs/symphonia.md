O roteiro cobre **AAC-LC/M4A, ALAC e AIFF**, aproveitando o Symphonia já integrado ao `durvald-core`.

|Etapa|Implementação|Critério de conclusão|
|---|---|---|
|**1. Preparar arquivos de teste**|Reunir AAC-LC e ALAC em `.m4a`, além de AIFF em `.aif`/`.aiff`. Incluir mono, estéreo, diferentes taxas de amostragem e arquivos com metadados/capas.|Ter exemplos reproduzíveis para validar cada formato.|
|**2. Habilitar os decoders**|Adicionar `aac`, `alac`, `isomp4` e `aiff` às features do Symphonia. Manter a versão atual inicialmente.|O decoder atual consegue abrir e decodificar os arquivos de teste.|
|**3. Integrar à biblioteca**|Atualizar as extensões aceitas pelo scanner e os testes que hoje rejeitam esses formatos. Conferir filtros de importação no macOS.|As faixas aparecem na biblioteca com duração, tags e capas corretas.|
|**4. Validar reprodução e seek**|Testar início, pausa, retomada, avanço manual e seek próximo ao começo/fim. Revisar a exigência de duração conhecida e a leitura da cauda usada no pré-carregamento.|Reprodução e pré-carregamento funcionam sem travamentos ou posicionamento incorreto.|
|**5. Validar gapless por formato**|Comparar transições ALAC/AIFF com uma gravação contínua. Para AAC/M4A, investigar o atraso e o padding informados pelo arquivo e implementar o recorte quando necessário.|Continuidade comprovada nas amostras suportadas, sem prometer gapless AAC apenas por habilitar o codec.|
|**6. Tratar arquivos incompatíveis**|Exibir erro claro para HE-AAC, arquivos corrompidos e configurações de canais não suportadas. Garantir que uma falha não interrompa a importação das demais faixas.|Falhas previsíveis e recuperáveis.|
|**7. Entregar no macOS**|Executar regressões Rust, Clippy e testes de integração; reconstruir a biblioteca embarcada e validar UniFFI e reprodução no app.|App distribuído com os novos formatos funcionando.|

Eu dividiria em três commits revisáveis:

1. **Habilitar formatos e importação**, com testes de identificação e metadados.
2. **Ajustar reprodução, seek e gapless**, com regressões de áudio.
3. **Atualizar a biblioteca macOS e documentar o suporte**.

A estimativa de **2–4 dias** cobre o suporte básico e a validação. O tratamento completo de gapless em AAC/M4A fica como a principal incerteza e pode ampliar esse prazo.