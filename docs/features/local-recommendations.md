# Recomendações locais — fase 4, item 9

O core seleciona álbuns da biblioteca e devolve um motivo para cada sugestão.
Não usa IA, rede, serviços externos ou um catálogo de descoberta. Os pesos são
heurísticas iniciais para experimentar, sem afirmar qualidade preditiva.

## Candidatos e sinais

- A unidade é o lançamento local (`release_id`), sem repetir sua identidade no
  resultado. São excluídos álbuns ocultos, com `suggest_less`, avaliados abaixo
  de duas estrelas, ou sem faixas visíveis, não desaconselhadas e com caminho
  registrado. A disponibilidade acompanha o catálogo e a varredura existente;
  não há leitura adicional dos arquivos de áudio para montar a Home.
- Escutas válidas alimentam a afinidade por artista. Até 180 dias contribuem,
  com maior peso nos últimos 30 dias; duração excessiva não aumenta o peso além
  de uma escuta. O volume é reduzido por logaritmo e limitado por álbum.
- Favoritar um álbum, dar ao álbum pelo menos quatro estrelas, favoritar uma
  faixa ou avaliá-la bem fornece evidência adicional de interesse.
- Gêneros, estilos, tags de álbum e tags de faixa enriquecem a afinidade. As
  duas origens de tags têm espaços separados: uma tag de álbum não é herdada
  pela faixa. Classificação efetiva respeita decisões e herança, e faixas ocultas
  ou desaconselhadas não acrescentam classificação ao perfil.
- Cada característica contribui uma vez por álbum, independentemente da
  quantidade de suas faixas. Álbuns com muitos rótulos têm contribuição
  normalizada, e a própria evidência do candidato é subtraída: um favorito não
  pode supostamente compartilhar gêneros ou tags apenas consigo mesmo.

## Ordenação, diversidade e repetição

O score combina afinidade de artista (até 12 pontos), até três características
compartilhadas (até 6), pouca escuta (`8 / (1 + ln(1 + reproduções))`), seis
pontos para nunca reproduzidos, três para adicionados nos últimos 30 dias, seis
para favoritos, dois para álbuns com faixas favoritas e dois a quatro para
álbuns avaliados com quatro a cinco estrelas.

Álbuns ouvidos nas últimas 48 horas ficam fora da seleção, evitando repetir a
prateleira de escutas recentes. Exposições nos seis dias anteriores reduzem o
score em 20 pontos; é uma penalidade, não uma exclusão que esvazie bibliotecas
pequenas. O mesmo dia não sofre essa penalidade. Uma pequena rotação diária
determinística desempata candidatos sem embaralhar cards a cada atualização.

A API permite de um a 24 resultados; a Home pede 12. Cada artista aparece no
máximo duas vezes, mesmo que isso produza menos resultados. Diferentes edições
com identidades locais distintas permanecem unidades distintas. O ranking
considera todo o catálogo elegível no core e transfere somente o resultado
limitado ao cliente.

Os motivos descrevem evidência disponível: artista ouvido, gênero/estilo ou tag
em comum, favorito, avaliação pessoal, recência, pouca escuta ou revisita.
Sem histórico elegível, a Home usa **Explore sua biblioteca**, sem apresentar
uma personalização baseada em escutas que não existem. Favoritos e avaliações
ainda podem ajudar a ordenar essa exploração.

## Interface e atualização

O bloco da Home usa o mesmo contêiner de rolagem horizontal, margens e desenho
sob as barras laterais das outras prateleiras. Os cards abrem a AlbumView e
mantêm seus menus existentes; abaixo da capa aparece o motivo.

Dispensar um card o oculta por 30 dias, com persistência entre sessões. O menu
**Restaurar sugestões dispensadas** desfaz apenas essas dispensas, preservando
as preferências globais de ocultar e sugerir menos. A interface oferece estados
de carregamento, ausência de candidatos, erro e nova tentativa.

O cliente consulta uma revisão escalar de histórico durante a visita à Home.
Recalcula apenas quando histórico, catálogo, metadados, avaliações, favoritos,
classificações, tags ou dia mudam, ou quando o usuário pede atualização. Polling
não cancela atualizações forçadas, e resultados de um core antigo ou de uma
tarefa cancelada não substituem o estado atual.

## Medição local

`recommendation_impressions` registra uma exposição por álbum/dia quando o card
alcança 50% de visibilidade e a abertura feita pelo card. Eventos repetidos não
multiplicam contagens. Ao registrar histórico, um trigger atribui uma escuta à
última abertura desse álbum nas 24 horas anteriores quando houve pelo menos
30 segundos ou metade de uma faixa curta. Só abrir o álbum não conta como escuta.

`recommendation_metrics` retorna exposições, aberturas e escutas atribuídas nos
últimos 30 dias. Trata-se de associação temporal, não prova de causalidade;
reprodução iniciada por outros menus sem abertura pelo card não recebe essa
atribuição. Nada é enviado externamente. Eventos com mais de 90 dias são
removidos no próximo registro, e a exclusão de um álbum apaga sua identidade
dos eventos sem alterar as contagens históricas.

`recommendation_dismissals` mantém as dispensas com prazo. As duas tabelas e os
índices/triggers são migrações aditivas e idempotentes. As novas APIs são
compartilhadas; este incremento adiciona o bloco de interface ao macOS.
