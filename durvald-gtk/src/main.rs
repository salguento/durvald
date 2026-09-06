mod backend;
mod window;

use gtk::{gio, glib, prelude::*};

const APP_ID: &str = "io.github.durvald.Durvald";

fn main() -> glib::ExitCode {
    let runtime = match tokio::runtime::Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("Não foi possível iniciar o runtime: {error}");
            return glib::ExitCode::FAILURE;
        }
    };
    let app = gtk::Application::builder().application_id(APP_ID).build();
    let backend = backend::Backend::new(runtime.handle().clone());
    app.connect_activate(move |app| {
        if let Some(window) = app.active_window() {
            window.present();
        } else {
            window::build(app, backend.clone());
        }
    });

    let quit = gio::SimpleAction::new("quit", None);
    let weak_app = app.downgrade();
    quit.connect_activate(move |_, _| {
        if let Some(app) = weak_app.upgrade() {
            app.quit();
        }
    });
    app.add_action(&quit);
    app.set_accels_for_action("app.quit", &["<Primary>q"]);

    let result = app.run();
    runtime.shutdown_timeout(std::time::Duration::from_secs(2));
    result
}
