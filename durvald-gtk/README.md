# Durvald para Linux

Base mínima em Rust + GTK4. Usa `durvald-core` como dependência local pela API
pública Rust, sem gerar bindings UniFFI. O projeto Cargo é independente do cliente
macOS e do manifesto do core.

## Preparação

Instale Rust estável (via rustup), um compilador C e os pacotes de desenvolvimento:

```sh
# Ubuntu / Debian
sudo apt install build-essential pkg-config libgtk-4-dev libasound2-dev libudev-dev libssl-dev

# Fedora
sudo dnf install gcc gcc-c++ pkgconf-pkg-config gtk4-devel alsa-lib-devel systemd-devel openssl-devel
```

É necessário GTK 4.0 ou posterior e uma sessão gráfica Wayland ou X11.
O core inicializa o backend de áudio na abertura; mantenha um dispositivo de
áudio disponível. A integração de credenciais do core usa Secret Service no Linux.

## Executar e verificar

Na raiz do repositório:

```sh
cargo run --locked --manifest-path durvald-gtk/Cargo.toml
cargo fmt --manifest-path durvald-gtk/Cargo.toml -- --check
cargo clippy --locked --manifest-path durvald-gtk/Cargo.toml --all-targets -- -D warnings
cargo build --locked --manifest-path durvald-gtk/Cargo.toml
```

O aplicativo abre uma janela, inicializa o core e mostra a quantidade de músicas
persistidas. “Atualizar biblioteca” relê o banco; não inicia uma varredura.
Importação, listas de faixas e controles de reprodução são os próximos passos,
ainda não implementados. `Ctrl+Q` encerra o aplicativo.

## Organização

- `src/main.rs`: ciclo de vida GTK, runtime Tokio e ação de sair.
- `src/backend.rs`: ponte assíncrona para a API pública do core.
- `src/window.rs`: janela inicial e estados de carregamento, vazio e erro.

Widgets vivem exclusivamente na thread GTK/GLib. Envie operações do core para
`Backend::run` e aguarde os resultados com `glib::spawn_future_local`; não use
`block_on` na thread da interface. O runtime permanece ativo enquanto o
aplicativo está aberto.

Os dados ficam em `$XDG_DATA_HOME/durvald`, com fallback para
`~/.local/share/durvald`: banco `music.db3` e capas em `covers/`. Para desenvolver
com dados separados:

```sh
XDG_DATA_HOME=/tmp/durvald-dev cargo run --locked --manifest-path durvald-gtk/Cargo.toml
```

Verificação manual: abrir em uma sessão gráfica, conferir o estado da biblioteca,
atualizar e fechar com `Ctrl+Q`. Erros de inicialização aparecem na janela.
