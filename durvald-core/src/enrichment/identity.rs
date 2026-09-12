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
