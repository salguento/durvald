# F0.07 — Infraestrutura de fixtures temporárias

Esta etapa define a infraestrutura comum de testes que sustentará os characterization, integration e contract tests da Fase 0.

O objetivo é permitir que cada teste construa um ambiente pequeno, determinístico e completamente isolado, sem depender da máquina do desenvolvedor, de dados pessoais, de serviços externos ou de estado deixado por outro teste.

A F0.07 não implementa ainda os baselines funcionais de database, library, playback, metadata ou enrichment. Ela cria a fundação reutilizável sobre a qual esses testes serão escritos.

## Snapshot analisado

A etapa parte do estado de `main` após a F0.06:

```text
b83e5f5bca94a3e3e44c7beb86919c78c1a969c4
```

O repositório já possui `durvald-core/tests/fixtures`, mas a infraestrutura ainda precisa ser padronizada para suportar os cenários definidos na matriz de cobertura.

## Objetivo

Ao concluir a F0.07, os testes de integração devem poder criar ambientes descartáveis com:

```text
temp root
├── app-support/
├── covers/
├── library/
└── durvald.sqlite
```

e popular esse ambiente a partir de fixtures versionadas no repositório sem modificar os arquivos originais.

As garantias principais são:

- um ambiente temporário independente por teste;
- caminhos de banco, biblioteca, covers e app support controlados pelo teste;
- fixtures estáticas tratadas como somente leitura;
- qualquer fixture que precise ser modificada é copiada antes para o ambiente temporário;
- nenhuma dependência de `~/Music`, banco real do desenvolvedor ou diretórios reais de configuração;
- nenhuma dependência de rede real para testes determinísticos;
- nenhuma dependência de Keychain/Secret Service para a infraestrutura básica;
- execução paralela segura;
- limpeza automática ao final do teste;
- infraestrutura simples o suficiente para ser reutilizada pela F0.08 sem virar abstração de produção.

## Escopo

A F0.07 pode criar exclusivamente infraestrutura de teste:

- módulos compartilhados em `tests/common/`;
- organização e convenções de `tests/fixtures/`;
- helpers de filesystem;
- helpers de resolução e cópia de fixtures;
- helpers mínimos para caminhos de database;
- fixtures pequenas de áudio, metadata, rede e banco quando necessárias;
- testes da própria infraestrutura de fixtures;
- dev-dependencies estritamente necessárias a essa infraestrutura.

Ela não deve:

- alterar comportamento de produção;
- introduzir repositories, ports ou application services;
- antecipar o `TestCore` da F0.08;
- criar mocks arquiteturais que pertencem a fases futuras;
- implementar os baselines funcionais das etapas seguintes;
- acessar dados reais do usuário;
- depender de serviços externos para passar no CI.

## Estrutura alvo

A infraestrutura deve convergir para uma organização equivalente a:

```text
durvald-core/tests/
├── common/
│   ├── mod.rs
│   ├── database.rs
│   ├── filesystem.rs
│   ├── audio.rs
│   └── fixtures.rs
│
├── fixtures/
│   ├── audio/
│   ├── metadata/
│   ├── database/
│   └── network/
│       ├── musicbrainz/
│       ├── wikidata/
│       ├── wikipedia/
│       └── lastfm/
│
├── core_lifecycle.rs
├── library.rs
├── playback.rs
├── playlists.rs
├── history.rs
├── metadata.rs
├── enrichment.rs
└── public_api.rs
```

Os arquivos de teste por domínio podem ser adicionados nas etapas correspondentes. A obrigação da F0.07 é preparar `common/` e as convenções de `fixtures/`.

## Ambiente temporário por teste

Cada teste de integração deve possuir seu próprio root temporário.

Conceitualmente:

```rust
pub struct TestFs {
    root: TempDir,
    app_support_dir: PathBuf,
    covers_dir: PathBuf,
    library_dir: PathBuf,
    database_path: PathBuf,
}
```

A implementação concreta pode variar, mas deve preservar estas propriedades:

1. o root é criado exclusivamente para aquele teste;
2. `app-support/`, `covers/` e `library/` são criados sob o root;
3. `durvald.sqlite` aponta para o mesmo root;
4. todos os paths expostos são absolutos ou resolvidos de forma inequívoca;
5. o lifetime do diretório temporário cobre todo o teste;
6. o cleanup ocorre automaticamente quando o ambiente é destruído;
7. nenhuma rotina de cleanup pode operar fora do root criado pela infraestrutura.

O arquivo SQLite não deve ser criado manualmente quando o cenário precisa validar a criação normal do banco. Nesses casos, o helper fornece apenas o path e deixa o código de produção criar o arquivo e executar migrations.

## Responsabilidades de `tests/common`

### `common/mod.rs`

Ponto único de exposição dos helpers compartilhados pelos integration tests.

Não deve conter lógica relevante além da organização dos módulos.

### `common/filesystem.rs`

Responsável pelo ambiente físico descartável.

Deve oferecer operações equivalentes a:

```rust
TestFs::new()

fs.root()
fs.app_support_dir()
fs.covers_dir()
fs.library_dir()
fs.database_path()
```

Também deve fornecer helpers pequenos para cenários recorrentes, como:

```rust
fs.create_library_dir("Artist A/Album A");
fs.write_library_file("invalid.txt", b"...");

fs.remove_library_file("Artist A/Album A/01.flac");
```

Esses helpers devem operar apenas dentro do root temporário.

### `common/fixtures.rs`

Responsável por localizar fixtures versionadas e copiá-las para ambientes mutáveis.

A resolução deve ser centralizada. Testes não devem espalhar construções frágeis como:

```rust
PathBuf::from("tests/fixtures/...")
```

A API deve permitir algo equivalente a:

```rust
fixture_path("audio/example.flac");

fs.copy_fixture(
    "audio/example.flac",
    "library/Artist A/Album A/01.flac",
);
```

O helper de cópia deve:

- falhar claramente quando a fixture de origem não existir;
- criar diretórios intermediários quando necessário;
- copiar o arquivo sem alterar o original;
- retornar o path final criado;
- rejeitar destinos que escapem do root temporário.

### `common/database.rs`

Deve concentrar somente utilidades de teste relacionadas ao arquivo SQLite.

Responsabilidades iniciais:

- expor o path do DB temporário;
- facilitar reabertura do mesmo DB dentro do mesmo cenário;
- copiar uma fixture de banco versionada para o root temporário;
- preservar a regra de que migrations e criação de schema devem ser exercidas pela API real quando esse for o comportamento em teste.

A infraestrutura não deve recriar manualmente tabelas que o código de produção é responsável por criar.

### `common/audio.rs`

Deve reunir convenções e helpers específicos para fixtures de áudio quando houver repetição real.

Exemplos aceitáveis:

- copiar uma fixture de áudio para a library temporária;
- retornar paths para formatos conhecidos;
- montar rapidamente uma pequena biblioteca de teste.

Esse módulo não deve implementar lógica de playback nem abstrações de produção.

## Fixtures estáticas e temporárias

A suíte deve distinguir explicitamente dois conceitos.

### Fixture estática

Arquivo versionado em:

```text
tests/fixtures/**
```

Regra:

> Fixtures estáticas são somente leitura durante os testes.

Elas representam entradas conhecidas e reproduzíveis.

### Fixture temporária

Cópia criada sob o root do teste.

Fluxo obrigatório quando houver mutação:

```text
fixture versionada
        │
        ▼
cópia para TempDir
        │
        ▼
mutação pelo teste
        │
        ▼
verificação
```

Isso é especialmente importante para metadata: testes de edição nunca devem escrever diretamente sobre o arquivo versionado.

## Convenções por tipo de fixture

### Áudio

`fixtures/audio/` deve conter apenas arquivos pequenos necessários para cenários determinísticos.

A coleção deve crescer conforme a matriz exigir, por exemplo:

- formato de áudio válido suportado;
- mais de um formato suportado quando necessário;
- arquivo inválido;
- casos específicos exigidos por scan ou playback.

Não é objetivo manter uma biblioteca musical de desenvolvimento dentro do repositório.

### Metadata

`fixtures/metadata/` deve conter arquivos cujo conteúdo esperado seja conhecido.

Quando relevante, a fixture deve ter valores controlados para campos como:

```text
title
artist
album
track
disc
year
artwork
```

Os nomes devem descrever o cenário em vez de detalhes arbitrários, por exemplo:

```text
basic-tags.flac
missing-album.flac
multi-disc.flac
embedded-artwork.flac
```

Esses nomes são convenções; somente fixtures realmente necessárias aos testes devem ser adicionadas.

### Database

`fixtures/database/` deve ser reservado a snapshots SQLite reais necessários para migration/recovery tests.

Uma fixture de banco só deve ser adicionada quando representar uma versão conhecida e verificável do schema.

Não criar schemas históricos artificiais apenas para preencher a pasta.

O fluxo esperado para migrations é:

```text
DB versionado
     │
     ▼
cópia para TempDir
     │
     ▼
open pela API real
     │
     ▼
migrations
     │
     ▼
verificação do estado atual
```

### Rede

Respostas remotas determinísticas devem ser armazenadas sob:

```text
fixtures/network/
├── musicbrainz/
├── wikidata/
├── wikipedia/
└── lastfm/
```

Esses arquivos serão consumidos posteriormente por doubles de transporte nos testes de enrichment e Last.fm.

A F0.07 define a organização e a forma de acesso. Ela não precisa implementar nesta etapa todos os cenários de rede da matriz.

## Montagem de bibliotecas temporárias

Os helpers devem permitir construir árvores pequenas de biblioteca sem duplicar boilerplate.

Exemplo:

```text
library/
├── Artist A/
│   └── Album A/
│       ├── 01.flac
│       └── 02.mp3
└── Artist B/
    └── song.ogg
```

A API pode oferecer uma operação equivalente a:

```rust
fs.copy_to_library(
    "audio/example.flac",
    "Artist A/Album A/01.flac",
);
```

Com isso os testes de library podem descrever diretamente o cenário que querem caracterizar:

- scan inicial;
- rescan sem mudanças;
- arquivo adicionado;
- arquivo removido;
- arquivo modificado;
- diretório removido;
- arquivo inválido;
- extensão não suportada;
- cancelamento.

A F0.07 fornece os meios de montar esses estados, mas as assertions funcionais pertencem às etapas de baseline correspondentes.

## Independência do ambiente local

Os testes determinísticos construídos sobre esta infraestrutura não podem depender implicitamente de:

```text
~/Music
DB da instalação local do Durvald
~/Library/Application Support/...
~/.config/...
Keychain real
Secret Service real
MusicBrainz real
Wikidata real
Wikipedia real
Last.fm real
```

Recursos específicos de plataforma que precisem de smoke tests reais devem continuar separados da infraestrutura básica.

Em particular:

- secure storage real pertence aos testes específicos de adapter/plataforma;
- HTTP real não é requisito para enrichment/Last.fm determinísticos;
- áudio físico não é requisito da infraestrutura de fixtures.

## Paralelismo

A infraestrutura deve ser segura para a execução padrão do `cargo test`.

Dois testes concorrentes devem receber roots distintos e não compartilhar:

- database;
- library;
- covers;
- app support;
- arquivos mutáveis.

A suíte não deve precisar de `--test-threads=1` apenas para evitar colisões criadas pela própria infraestrutura de teste.

Quando um recurso global inevitável aparecer em uma etapa posterior, ele deve ser tratado explicitamente naquele teste, e não escondido dentro da F0.07.

## Imutabilidade e segurança dos paths

A infraestrutura deve tratar `tests/fixtures/**` como fonte imutável.

Também deve impedir que helpers aceitem paths de destino que escapem do root temporário por acidente.

Operações de criação, escrita, remoção e cleanup devem ficar confinadas ao ambiente pertencente ao teste.

Essa restrição protege tanto a independência dos testes quanto o ambiente do desenvolvedor.

## Testes da própria infraestrutura

Os helpers compartilhados devem possuir uma cobertura mínima que valide sua confiabilidade antes que dezenas de characterization tests dependam deles.

Cobertura mínima:

- `TestFs` cria a árvore esperada;
- dois ambientes recebem roots diferentes;
- `fixture_path` localiza uma fixture existente;
- fixture inexistente produz falha clara;
- cópia de fixture cria diretórios intermediários;
- a cópia preserva a fixture original;
- escrita e remoção atuam apenas no root temporário;
- destino com tentativa de escape do root é rejeitado;
- cleanup automático não exige código manual por teste.

Esses testes não precisam formar uma suíte extensa. Eles apenas protegem os invariantes da infraestrutura compartilhada.

## Relação com a F0.08 — `TestCore`

A F0.07 e a F0.08 devem permanecer separadas.

A F0.07 entrega:

```text
filesystem temporário
+
paths controlados
+
database path
+
resolução de fixtures
+
cópia de fixtures
+
convenções de áudio/metadata/database/rede
```

A F0.08 compõe essa infraestrutura com a fachada real:

```rust
struct TestCore {
    core: Arc<DurvaldCore>,
    root: TempDir,
    library_dir: PathBuf,
}
```

Assim, `TestFs` e os helpers de fixtures continuam sendo infraestrutura física genérica de teste, enquanto `TestCore` passa a responder pelo bootstrap do `DurvaldCore`.

Nenhuma dessas estruturas deve migrar para código de produção.

## Exemplo de uso esperado

Ao final da F0.07 deve ser possível escrever um teste de infraestrutura aproximadamente assim:

```rust
#[test]
fn fixture_environment_is_isolated() {
    let env = TestFs::new();

    let track = env.copy_to_library(
        "audio/example.flac",
        "Artist/Album/01.flac",
    );

    assert!(track.exists());
    assert!(env.library_dir().exists());
    assert!(!env.database_path().exists());
}
```

O exemplo é ilustrativo. Os nomes finais dos helpers podem ser ajustados durante a implementação, desde que as garantias deste documento sejam preservadas.

## Critério de conclusão da F0.07

A etapa é considerada concluída quando:

- [ ] `tests/common/` possui a infraestrutura compartilhada mínima;
- [ ] cada teste pode criar um root temporário próprio;
- [ ] app support, covers, library e database possuem paths controlados pelo ambiente;
- [ ] a resolução de fixtures está centralizada;
- [ ] fixtures mutáveis são sempre cópias temporárias;
- [ ] a fixture original permanece intacta;
- [ ] árvores de biblioteca podem ser construídas sem boilerplate repetitivo;
- [ ] existe convenção explícita para fixtures de áudio, metadata, database e rede;
- [ ] nenhum helper básico depende de `~/Music`, banco real, Keychain/Secret Service ou rede real;
- [ ] testes podem executar em paralelo sem compartilhar estado mutável;
- [ ] cleanup ocorre automaticamente;
- [ ] helpers impedem escrita/remoção fora do root temporário;
- [ ] a infraestrutura possui testes mínimos próprios;
- [ ] nenhuma alteração de comportamento de produção foi introduzida;
- [ ] o resultado está pronto para ser composto pelo `TestCore` da F0.08.

## Resultado da etapa

A F0.07 não aumenta diretamente a cobertura funcional da matriz. Ela estabelece o ambiente determinístico necessário para fechar os itens seguintes.

Depois dela, os testes de database, library, playback, metadata, enrichment e recovery podem operar sobre a mesma base:

```text
fixture versionada
       │
       ▼
ambiente temporário isolado
       │
       ▼
código real do Durvald
       │
       ▼
assertions de comportamento
```

Isso mantém a Fase 0 reproduzível e reduz o risco de testes que passam apenas por dependerem do estado particular de uma máquina.
