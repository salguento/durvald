# Tags pessoais — fase 2, item 4

Implementação no cliente macOS e na API compartilhada do core, em 21/10/2026.
Tags são categorias livres do usuário, independentes de gêneros, estilos e
metadados embutidos nos arquivos. Esta funcionalidade não grava nos arquivos de áudio.

## Uso

- Faixas: menu de contexto **Tags pessoais…**, aba **Tags** em Info ou
  **Editar tags de N itens** no submenu **Tags pessoais** das opções de
  visualização da topbar, após selecionar faixas na biblioteca.
- Lançamentos/álbuns: tags existentes aparecem abaixo da avaliação no cabeçalho
  de AlbumView, sem seção sob a capa. A edição fica no menu de contexto dos
  cartões ou na edição em lote dos resultados da listagem de álbuns.
- O editor procura tags existentes enquanto o usuário digita e permite criar e
  associar uma tag pelo nome. Aplicar ou remover uma tag na seleção preserva as
  outras tags. Em seleção mista, informa quantos itens já usam a tag e oferece
  remoção apenas dessa associação na seleção.
- **Gerenciar tags…** permite criar tags sem associação, renomear globalmente e
  excluir com confirmação. Excluir apaga todas as associações daquela tag;
  remover uma associação preserva a definição e os demais usos.
- As listagens de músicas e álbuns combinam o filtro de tags com a busca e os
  filtros já existentes. É possível exigir **Todas as tags** ou **Qualquer tag**.
  Filtrar, limpar o filtro, gerenciar e editar em lote ficam no submenu
  **Tags pessoais** das opções de visualização na topbar, sem botões no conteúdo.
- Playlists inteligentes oferecem **Tag pessoal da faixa** e **Tag pessoal do
  álbum**, com igualdade, diferença, presença e ausência. As regras persistem o
  ID da tag, por isso continuam funcionando após renomeá-la. Uma tag excluída é
  identificada como tal ao editar uma regra existente.

## Escopo e persistência

Álbum usa a identidade de `Release` do catálogo local; não existe uma associação
redundante específica para álbuns. Uma tag de lançamento não é herdada pelas
faixas e vice-versa. Grupos externos ainda não incorporados ao catálogo local não
recebem associações locais nem propagação implícita entre edições.

Migração aditiva e idempotente cria `user_tags`, `track_user_tags` e
`release_user_tags`, com FKs, unicidade de associação e índices nos dois sentidos.
Nomes têm de 1 a 80 caracteres, rejeitam caracteres de controle, condensam espaços
e são únicos após conversão Unicode para minúsculas. Criar um nome já existente
seleciona a definição existente; renomear para outro nome já cadastrado falha.

Operações em lote são transacionais: um alvo inválido desfaz todo o lote. O core
limita cada lote a 10.000 itens e a consulta por tags a 100 tags. A API oferece
snapshot consistente e consulta de IDs por qualquer/todas as tags, reutilizáveis
por outros clientes e futuras recomendações. O cliente GTK não recebeu nova UI.

Rescans preservam associações de itens existentes. Tags de faixas que ficam
ausentes são guardadas em `missing_track_user_tags` e restauradas no reparo
explícito; a união de registros duplicados preserva as tags das duas faixas.
Lançamentos com tags não são apagados na limpeza de órfãos do scan, preservando
sua identidade para reimportação. Excluir uma tag também remove seus usos nos
registros de arquivos ausentes. Nenhuma associação é inventada por semelhança.

## Verificação

- Testes do core cobrem normalização, duplicidade, limites de nomes, transações,
  filtros qualquer/todas, renomeação, desassociação, exclusão e cascatas.
- Regras inteligentes mantêm identidade após renomeação e distinguem faixa de álbum.
- Integração com banco e arquivos reais cobre rescan, reinicialização, arquivo
  temporariamente ausente e reparo explícito sem perder a tag do lançamento.
- Testes Swift cobrem o filtro e a ponte Swift/Rust, preservação de outras tags
  e persistência após reabrir o banco.
- Testes de interface cobrem edição em lote, filtros, renomeação global sem
  perder o filtro, confirmação de exclusão, chips e reinicialização.

A regressão ampla do core encontrou duas falhas também reproduzidas numa cópia
intacta do commit anterior: `legacy_rows_survive_migration_and_reopening` espera
18 migrações de enriquecimento, mas o projeto já possui 19; e
`similar_artist_snapshot_materializes_targets_and_their_identities_atomically`
falha ao armazenar um asset de artista similar. As tags não alteram esse subsistema.

Resultado final da validação: 45 testes unitários/integração Swift, 2 testes de
interface, 4 testes específicos de tags no Rust, 2 testes de reparo e os 29
testes de integração da biblioteca passaram. Compilação macOS e verificação de
whitespace aprovadas; bindings Swift/FFI e biblioteca embarcada atualizados juntos.
