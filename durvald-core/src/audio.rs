//! Audio playback module using kira

mod analyzer;
mod decoder;
mod equalizer;
mod gapless;
pub mod player;

pub use player::AudioPlayer;

/// File extensions accepted by library scanning for this MVP. They map exactly
/// to the Kira/Symphonia decoder features enabled in `Cargo.toml`: MP3, WAV,
/// FLAC, and Ogg Vorbis (whose conventional extensions are `.ogg` and `.oga`).
/// Do not add an extension here without enabling and exercising its decoder.
pub(crate) const SUPPORTED_AUDIO_EXTENSIONS: &[&str] = &["mp3", "wav", "flac", "ogg", "oga"];

/// Decode a completed acquisition file without creating a player or emitting plays.
pub(crate) fn validate_acquired_audio(
    path: &str,
    cancel: &std::sync::atomic::AtomicBool,
) -> Result<(), String> {
    use kira::sound::streaming::Decoder;
    let mut decoder = decoder::GaplessDecoder::open(path)
        .map_err(|_| "O arquivo não contém áudio compatível.".to_string())?;
    let expected = decoder.num_frames();
    let mut frames = 0usize;
    loop {
        if cancel.load(std::sync::atomic::Ordering::SeqCst) {
            return Err("Importação cancelada.".into());
        }
        match decoder.decode() {
            Ok(chunk) => {
                if chunk.is_empty() {
                    break;
                }
                frames = frames.saturating_add(chunk.len());
            }
            Err(kira::sound::FromFileError::IoError(e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(kira::sound::FromFileError::SymphoniaError(
                symphonia::core::errors::Error::IoError(e),
            )) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(_) => return Err("Não foi possível validar todo o áudio do arquivo.".into()),
        }
    }
    if frames == 0 || expected == 0 || frames < expected {
        return Err("O áudio parece vazio ou incompleto.".into());
    }
    Ok(())
}
