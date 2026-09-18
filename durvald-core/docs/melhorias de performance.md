Sim, mas o ganho agora seria principalmente em abertura e navegação — o idle em 0% já está saudável.

As próximas otimizações, por prioridade, seriam:

1. **Medir fora do Xcode em Release.** A medição atual veio de um binário `Debug` conectado ao `debugserver`, que aumenta bastante picos curtos. Um pico de 40% por 0,5 s representa apenas cerca de 0,2 segundo de CPU.
    
2. **Adiar o enrichment automático da `ArtistView`.** É a principal candidata para reduzir os picos durante navegação. Hoje perfil, retrato, discografia e capas podem começar ao abrir o artista.
    
3. **Inicialização progressiva.** A abertura dispara várias consultas da biblioteca, histórico, configurações, playback e caminhos. Carregar primeiro o necessário para desenhar a janela e postergar histórico/enrichment reduziria o pico inicial.
    
4. **Inicializar o motor de áudio sob demanda.** Se possível, criar o backend CoreAudio apenas na primeira reprodução, não na abertura do aplicativo.
    
5. **Otimizar playback ativo.** Enquanto toca, ainda há polling a 4 Hz e consulta SQLite repetida da faixa atual. Manter os metadados da faixa em memória eliminaria esse trabalho.
    
6. **Substituir ou reduzir o marquee.** Ele agora usa 30 fps durante reprodução; uma animação baseada no compositor ou 15 fps consumiria menos CPU.
    

Minha recomendação é atacar primeiro o enrichment automático da `ArtistView`, pois deve reduzir os picos perceptíveis de navegação. O pico isolado de abertura só merece prioridade se estiver causando atraso visual.