# Ouvir depois — fase 2, item 5

Implementado em 22/10/2026 no cliente macOS e na API compartilhada do core.
O nome visível é **Ouvir depois**, uma expressão curta que descreve a intenção e
facilita a tradução. Identificadores internos usam `listenList`/`listen_list`.

## Uso

- Acesso na sidebar esquerda, imediatamente abaixo de Home, e por um cartão
  na Home com a quantidade de lançamentos pendentes.
- Adicionar ou remover pela página do álbum; adicionar pelo menu de contexto
  dos álbuns locais e dos lançamentos on-line na página do artista.
- A página oferece busca por título/artista, estados **Ouvir depois**, **Ouvidos**
  e **Todos**, e ordenação por data de adição, título ou artista.
- Cada item permite abrir o lançamento, reproduzir quando local, marcar como
  ouvido, desfazer essa marcação e remover da lista.
- Marcar como ouvido preserva o registro. Remover da lista não exclui o álbum
  nem seus arquivos. Adicionar novamente um item existente preserva data e estado.

A marcação é manual neste recorte. A reprodução não remove nem marca itens
automaticamente; a eventual confirmação após ouvir um lançamento completo fica
para uma etapa futura, junto da definição desse critério de conclusão.

## Persistência e identidade

Migração aditiva e idempotente cria `listen_list_entries`, com identificador
próprio, vínculo opcional ao lançamento local, identidade MusicBrainz externa,
snapshot de título/artista/capa e metadados externos, data de adição e data
opcional de marcação como ouvido. Índices impedem duplicidade por lançamento
local ou identificador externo.

Referências on-line podem ser salvas sem arquivos de áudio e sem consultar a
rede durante a gravação. A abertura reutiliza os metadados externos salvos.
Itens locais usam os metadados atuais do catálogo, mantendo um snapshot caso
o vínculo deixe de existir. Rescans preservam lançamentos referenciados na lista,
inclusive quando seus arquivos ficam ausentes.

A reconciliação entre uma referência externa e um lançamento local exige um
vínculo explícito por identificador; nomes parecidos não criam associações.
Quando reconciliados, os registros mantêm a data de adição mais antiga e a
marcação como ouvido existente. Alterações e reconciliações são transacionais.

## Verificação

- 3 testes específicos do banco cobrem estados manuais, duplicidade,
  snapshots e reconciliação por identidade comprovada.
- Os 30 testes de integração da biblioteca passaram, incluindo persistência
  da lista após rescan, reinicialização e ausência de arquivos locais.
- 49 testes Swift passaram, incluindo apresentação, ponte Swift/Rust e
  regressões de Home, menus, atalhos, tags e listagens.
- 2 testes de interface passaram: acesso pela Home/sidebar, salvar, marcar,
  desfazer, reabrir o aplicativo e remover; e referência on-line sem áudio local.
- Layout da página inspecionado em captura de tela. Bindings Swift/FFI e
  biblioteca embarcada foram atualizados juntos; compilação macOS aprovada.

O cliente GTK não recebeu uma página nesta implementação.
