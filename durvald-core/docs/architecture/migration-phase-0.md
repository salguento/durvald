# F0.01 — Congelar o escopo da Fase 0

A Fase 0 existe para caracterizar e proteger o comportamento atual do `durvald-core` antes da migração arquitetural. Ela deve responder quais comportamentos existentes são contratos que precisam ser preservados e como regressões serão detectadas durante as fases seguintes.

Esta etapa, **F0.01**, não implementa ainda a baseline de testes. Seu papel é estabelecer o contrato de execução da própria Fase 0: o que pode ser alterado, o que deve permanecer intocado e quais verificações formam a referência técnica enquanto a caracterização é construída.

## Objetivo

Congelar formalmente o escopo da Fase 0 para que todo trabalho subsequente de caracterização, testes e documentação seja feito sem introduzir mudanças arquiteturais ou comportamentais não intencionais.

Ao concluir a F0.01 deve existir uma regra explícita para distinguir:

- mudanças permitidas para observar, documentar e testar o comportamento atual;
- pequenas mudanças estritamente necessárias para tornar código existente testável;
- mudanças arquiteturais, funcionais ou de produto que pertencem a fases posteriores.

A referência é o comportamento existente do `durvald-core` e de suas fronteiras atuais com os clientes Rust/GTK e Swift/UniFFI.

## Escopo

A Fase 0 pode incluir exclusivamente trabalho de caracterização e proteção do sistema atual.

São permitidos:

- documentação do comportamento, contratos, invariantes, superfície pública e dependências atuais;
- testes unitários, de integração, caracterização e contrato;
- criação e organização de fixtures;
- helpers e infraestrutura exclusivos de teste;
- instrumentação estritamente necessária para tornar um comportamento observável em teste;
- scripts locais de validação que reproduzam verificações já existentes ou consolidem a baseline;
- fortalecimento dos gates de CI necessários para executar a baseline;
- pequenas mudanças de visibilidade ou estrutura local necessárias à testabilidade, desde que não alterem API pública consumida, comportamento, persistência ou regras de negócio;
- registro de bugs e comportamentos ambíguos encontrados durante a caracterização, sem corrigi-los dentro da migração arquitetural.

A Fase 0 cobre o `durvald-core` e, somente para validação das fronteiras já existentes, os consumidores atuais:

- API pública Rust usada pelo cliente GTK;
- superfície UniFFI usada pelo cliente macOS;
- geração dos bindings Swift;
- build/testes dos clientes necessários para detectar quebra de contrato do core.

O estado atual confirma a necessidade dessa proteção: `durvald-core/tests/` contém hoje apenas fixtures, enquanto a CI já valida Rust em Linux/macOS, build com UniFFI, geração dos bindings Swift, build/testes do cliente macOS e o workflow separado do cliente GTK.

### Regra para pequenas mudanças de testabilidade

Uma mudança em código de produção só é admissível nesta fase quando todas as condições abaixo forem verdadeiras:

1. é necessária para observar ou exercitar o comportamento já existente;
2. não muda o resultado funcional observável;
3. não altera schema ou formato persistido;
4. não introduz nova abstração arquitetural destinada à arquitetura futura;
5. permanece pequena, local e facilmente revisável.

Exemplo admissível: ampliar de forma controlada a visibilidade interna de um helper para permitir um teste.

Exemplos não admissíveis: trocar algoritmo, mover responsabilidades entre camadas, introduzir repository/port/application service ou corrigir silenciosamente um comportamento descoberto durante a caracterização.

## Não-objetivos

A Fase 0, incluindo a F0.01, **não** deve implementar:

- a nova arquitetura;
- novos `traits` arquiteturais ou ports;
- repositories;
- application services;
- novas crates para decomposição arquitetural;
- reorganização do core em `application/`, `domain/` e `infrastructure/`;
- integração com Soulseek;
- integração com Jellyfin ou outros serviços de homelab;
- novas funcionalidades de produto;
- mudança deliberada de comportamento existente;
- mudança de schema sem necessidade estritamente ligada à infraestrutura de teste;
- otimizações de performance;
- redução ou redesenho da superfície pública;
- correções de bugs descobertos durante a caracterização, salvo quando tratadas em trabalho separado e explicitamente fora da migração arquitetural.

Quando um comportamento parecer incorreto ou ambíguo, a ação padrão da Fase 0 é **documentá-lo e caracterizá-lo primeiro**. A decisão de corrigi-lo deve ocorrer separadamente.

## Comandos de validação

Os comandos abaixo correspondem aos gates existentes no repositório e formam a referência inicial de validação da Fase 0.

### Rust core

Executar a partir de `durvald-core/`:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo build --package durvald-core
cargo build --package durvald-core --features uniffi
cargo test --package durvald-core
cargo doc --locked --package durvald-core --no-deps --document-private-items
```

Os cinco primeiros comandos correspondem aos jobs de core usados atualmente em Linux e macOS. O comando de documentação corresponde ao job `Documentation` da CI.

### UniFFI e cliente macOS

Em macOS, a partir da raiz do repositório:

```bash
./durvald-core/scripts/generate-swift-bindings.sh

xcodebuild \
  -project durvald-macos/Durvald/Durvald.xcodeproj \
  -scheme Durvald \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DurvaldDerivedData \
  build

xcodebuild \
  -project durvald-macos/Durvald/Durvald.xcodeproj \
  -scheme Durvald \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/DurvaldDerivedData \
  -only-testing:DurvaldTests \
  test
```

Essas verificações protegem a fronteira UniFFI e detectam alterações Rust que ainda compilam no core, mas quebram a geração dos bindings ou o consumidor Swift.

### Cliente GTK

Executar a partir de `durvald-gtk/`:

```bash
cargo fmt -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo build --locked
```

Esses comandos correspondem ao workflow `Linux GTK` e protegem o consumidor Rust direto do `durvald-core`.

### Interpretação de falhas

Durante a Fase 0:

- uma regressão introduzida pelo trabalho da fase deve ser corrigida antes da integração;
- uma falha comprovadamente pré-existente deve ser registrada como parte da baseline, e não mascarada por uma alteração comportamental dentro da migração;
- um teste novo que revelar comportamento inesperado deve primeiro caracterizar e documentar esse comportamento quando não houver decisão explícita de produto para mudá-lo.

## Critério de conclusão

A F0.01 é considerada concluída quando todos os itens abaixo forem verdadeiros:

- [ ] este documento está versionado junto ao `durvald-core`;
- [ ] objetivo, escopo e não-objetivos da Fase 0 estão explícitos e sem sobreposição com a migração arquitetural das fases seguintes;
- [ ] mudanças permitidas para testabilidade estão limitadas por uma regra conservadora e verificável;
- [ ] Soulseek, Jellyfin, novas abstrações arquiteturais, mudanças de comportamento e otimizações estão explicitamente fora do escopo;
- [ ] os comandos oficiais de validação refletem os gates atualmente existentes para Rust core, UniFFI/macOS e GTK;
- [ ] bugs ou comportamentos ambíguos encontrados na Fase 0 devem ser documentados/preservados ou tratados separadamente, nunca corrigidos incidentalmente pela refatoração;
- [ ] nenhuma alteração necessária para concluir a F0.01 modifica comportamento de produto, schema persistido ou contrato público do core.

A conclusão da F0.01 **não** significa que a Fase 0 esteja concluída. Ela apenas congela as regras sob as quais as próximas etapas de inventário, caracterização, testes e criação da baseline serão executadas.
