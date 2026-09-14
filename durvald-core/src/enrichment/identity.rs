/// Strict canonical MBID validation before interpolation into an endpoint path.
pub fn normalize_mbid(value: &str) -> Option<String> {
    let value = value.trim();
    (value.len() == 36
        && value.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
        && value.bytes().any(|c| c != b'0' && c != b'-'))
    .then(|| value.to_ascii_lowercase())
}

/// Canonicalizes human-readable names and titles before matching local tags
/// with MusicBrainz data. MusicBrainz commonly uses typographic punctuation
/// where file tags use their ASCII equivalents.
pub fn normalized_match_text(value: &str) -> String {
    value
        .chars()
        .map(|character| match character {
            '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2212}' => '-',
            '\u{2018}' | '\u{2019}' => '\'',
            _ => character,
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::normalized_match_text;

    #[test]
    fn match_text_normalizes_spacing_and_typographic_punctuation() {
        assert_eq!(
            normalized_match_text("  Switched\u{2010}On   Bach "),
            normalized_match_text("Switched-On Bach")
        );
        assert_eq!(
            normalized_match_text("Walter Carlos\u{2019} Clockwork Orange"),
            normalized_match_text("Walter Carlos' Clockwork Orange")
        );
    }
}
