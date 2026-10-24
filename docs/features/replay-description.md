# Descrição musical do Replay — fase 3, item 7

O core gera a descrição ao salvar um Replay com descrição vazia. Clientes que
enviam um texto personalizado mantêm esse texto. A geração funciona offline,
sem IA ou serviços externos, sobre a seleção efetiva e limitada do Replay.

## Agregação

- Cada faixa distinta dá um voto por nome de classificação. Repetições no
  histórico, duplicatas na seleção e um mesmo nome em gêneros e estilos não
  multiplicam votos. Tags pessoais e relações entre estilos e gêneros não entram.
- Usa a projeção efetiva de gêneros e estilos, respeitando decisões manuais,
  exclusões explícitas e herança. Quando um dos nomes destacados recebe votos
  herdados, o texto informa: “Inclui classificações herdadas dos álbuns.”
- Ordena por quantidade de faixas; empates usam o nome normalizado em Unicode
  NFC e minúsculas. Destaca no máximo três nomes, conservando sua grafia.
- Exige pelo menos duas faixas classificadas e cobertura de 25% da seleção.
  Abaixo disso, preserva o texto genérico anterior, sem inventar características.
- O início acompanha o período: “Seu dia”, “Sua semana”, “Seu mês” ou “Seu ano”.
  Exemplo: “Seu mês entre Jazz e Soul, com passagens por Funk.”

## Atualização e preservação

A tabela aditiva `replay_descriptions` registra o último texto automático, a
seleção que o originou e quem controla a descrição. Um trigger desativa a gestão
automática quando o texto é alterado, inclusive quando o usuário o esvazia.
Renomear a playlist ou mudar sua capa preserva essa gestão.

Replays dinâmicos recalculam a descrição quando muda o conjunto de faixas
selecionadas, inclusive na atualização final antes do fechamento automático.
Snapshots preservam sua descrição. Alterar somente os metadados sem mudar a
seleção não reescreve o resumo. As gravações ocorrem na mesma transação das
operações de Replay; a exclusão da playlist remove o registro auxiliar.

Replays antigos identificados pela origem existente adotam a geração apenas se
a descrição ainda for exatamente o antigo texto padrão do aplicativo. Textos
personalizados e descrições vazias existentes são preservados. Essa adoção é
feita uma vez, inclusive para snapshots antigos; nenhuma identidade é inferida
pelo nome editável da playlist.
