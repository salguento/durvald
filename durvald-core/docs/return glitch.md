No estado atual de `main`, a causa está bem clara: **não existe mais nenhum mecanismo de restauração de scroll na `ArtistView`**.

A navegação do Durvald não usa uma `NavigationStack` preservando a view anterior. `ContentView.detail` faz um `switch` sobre `shell.navigationHistory.currentRoute`; quando você entra no álbum, a `ArtistView` sai completamente da árvore e é substituída por `AlbumView`. Ao voltar, uma **nova `ArtistView` é criada**.

Além disso, ela é criada assim:

```
ArtistView(...)
    .id(artist.id)
```

Esse `.id(artist.id)` só define a identidade da nova view; ele **não preserva o estado da instância antiga**. A própria `LibraryNavigationHistory` guarda somente a rota (`artist`, `album`, etc.), sem qualquer estado visual associado, como posição de scroll.

Na `ArtistView`, atualmente existe simplesmente:

```
GeometryReader { geometry in
    ScrollView {
        VStack(...)
    }
}
```

Não há `scrollPosition`, `ScrollViewReader`, `onScrollGeometryChange`, offset salvo ou callback para `ContentView`. Portanto, quando a nova `ArtistView` aparece, o comportamento esperado do SwiftUI é começar em `y = 0`.

Há ainda um segundo problema que provavelmente explica os **glitches das tentativas anteriores**: ao reaparecer, `ArtistView.task(id: artist.id)` zera vários estados e começa uma carga assíncrona:

```
isLoading = true
details = nil
identity = nil
...
discographyItems = []
...
async let loadedTracks = ...
async let loadedAlbums = ...
...
```

e só depois reconstrói a página.

Então uma implementação do tipo:

```
.onAppear {
    proxy.scrollTo(...)
}
```

ou mesmo um `DispatchQueue.main.async { scrollTo(...) }`

fica sujeita a esta sequência:

```
ArtistView aparece
↓
conteúdo ainda está vazio/parcial
↓
scroll é restaurado
↓
tracks/albums/details/discography chegam
↓
altura da página muda
↓
SwiftUI relayout
↓
posição pula ou volta para outro ponto
```

Isso bate exatamente com o comportamento que você descreveu antes de a funcionalidade deixar de funcionar.

### Eu corrigiria no nível de `ContentShellState`, não dentro da `ArtistView`

A posição precisa sobreviver à destruição da view. `ContentShellState` é uma boa localização porque já sobrevive às trocas de rota e contém todo o estado de navegação da janela. Hoje ele não guarda nenhum estado de scroll.

Algo conceitualmente assim:

```
struct ContentShellState {
    var navigationHistory = LibraryNavigationHistory()

    var artistScrollOffsets: [Int64: CGFloat] = [:]

    ...
}
```

E a `ArtistView` receberia bindings/callbacks:

```
ArtistView(
    artist: artist,
    ...
    initialScrollOffset: shell.artistScrollOffsets[artist.id],
    onScrollOffsetChange: { offset in
        shell.artistScrollOffsets[artist.id] = offset
    }
)
```

Mas eu faria uma pequena variação importante: **capturar continuamente a posição, porém só restaurá-la quando os dados necessários à geometria terminarem de carregar**.

O fluxo deveria ser:

```
ArtistView A
scroll y = 1837

↓ usuário abre album

ContentShellState
artistScrollOffsets[A] = 1837

↓ AlbumView

↓ Back

nova ArtistView A
offset desejado = 1837

↓
carrega albums/tracks/details/discography
↓
layout estabiliza
↓
restaura y = 1837 uma única vez
↓
volta a observar scroll normalmente
```

Também é importante ter um flag como:

```
@State private var didRestoreScrollPosition = false
```

porque sem isso o próprio evento gerado pela restauração pode alimentar novamente o estado e provocar feedback/reposicionamentos.

### Não usaria `scrollTo(album.id)` como solução principal

Pode parecer tentador salvar o álbum clicado e fazer:

```
proxy.scrollTo(album.id)
```

ao voltar.

Isso resolve parcialmente o caso, mas não reproduz a posição original. O álbum pode ter estado no meio, no topo ou quase fora da viewport. Além disso, `ArtistView` apresenta álbuns em vários lugares: grid da biblioteca, lançamento mais recente e carrossel de essenciais. Os próprios callbacks `onSelectAlbum` aparecem em múltiplas subseções.

Salvar o **offset vertical real da página** é mais correto para o comportamento “voltar exatamente para onde eu estava”.

### O ponto mais importante

Eu não tentaria mais resolver isso fazendo `ArtistView` preservar seu próprio `@State`.

Ela **não sobrevive à navegação** com a arquitetura atual:

```
switch shell.navigationHistory.currentRoute {
case .album:
    AlbumView(...)
case .artist:
    ArtistView(...)
}
```

Portanto qualquer solução cujo estado relevante viva exclusivamente dentro de `ArtistView` está estruturalmente vulnerável.

Também conferi o histórico recente disponível no GitHub. O commit de 3 de setembro menciona melhorias de scrolling/navigation, mas o `main` atual não contém restauração de posição na `ArtistView`. Ou seja, se as várias tentativas que você fez hoje estavam em mudanças locais ou numa branch ainda não enviada, eu não consigo vê-las pelo repositório remoto. O que está publicado hoje explica integralmente por que a navegação volta ao topo.

A correção mínima que eu aplicaria envolve **somente `ContentShellState.swift`, `ContentView.swift` e `ArtistView.swift`**, sem mexer em Rust/UniFFI nem na estrutura de `LibraryNavigationHistory`.