use gtk::{glib, prelude::*};

use crate::backend::Backend;

pub fn build(app: &gtk::Application, backend: Backend) {
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("Durvald")
        .default_width(960)
        .default_height(640)
        .build();
    window.set_titlebar(Some(&gtk::HeaderBar::new()));

    let content = gtk::Box::new(gtk::Orientation::Vertical, 16);
    content.set_valign(gtk::Align::Center);
    content.set_halign(gtk::Align::Center);
    content.set_margin_top(24);
    content.set_margin_bottom(24);
    content.set_margin_start(24);
    content.set_margin_end(24);
    let icon = gtk::Image::from_icon_name("audio-x-generic-symbolic");
    icon.set_pixel_size(64);
    content.append(&icon);
    let title = gtk::Label::new(Some("Biblioteca de música"));
    title.add_css_class("title-1");
    content.append(&title);
    let status = gtk::Label::new(Some("Iniciando o core…"));
    status.set_wrap(true);
    status.set_max_width_chars(70);
    status.set_selectable(true);
    content.append(&status);
    let refresh = gtk::Button::with_label("Atualizar biblioteca");
    refresh.set_sensitive(false);
    content.append(&refresh);
    window.set_child(Some(&content));
    window.present();

    glib::spawn_future_local(async move {
        match backend.open().await {
            Ok(core) => {
                let refresh_status = status.clone();
                refresh.connect_clicked(move |button| {
                    let button = button.clone();
                    let status = refresh_status.clone();
                    let backend = backend.clone();
                    let core = core.clone();
                    button.set_sensitive(false);
                    status.set_text("Carregando biblioteca…");
                    glib::spawn_future_local(async move {
                        match backend.run(async move { core.tracks().await }).await {
                            Ok(tracks) if tracks.is_empty() => status.set_text(
                                "Core pronto. A biblioteca está vazia.\nA interface de importação será implementada aqui.",
                            ),
                            Ok(tracks) => status.set_text(&format!(
                                "Core pronto. {} músicas na biblioteca.",
                                tracks.len()
                            )),
                            Err(error) => status.set_text(&format!(
                                "Não foi possível carregar a biblioteca:\n{error}"
                            )),
                        }
                        button.set_sensitive(true);
                    });
                });
                refresh.set_sensitive(true);
                refresh.emit_clicked();
            }
            Err(error) => status.set_text(&format!(
                "Não foi possível iniciar o core:\n{error}\nVerifique o dispositivo de áudio e as permissões do diretório de dados e reinicie o aplicativo."
            )),
        }
    });
}
