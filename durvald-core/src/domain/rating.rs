//! Exact rating value. Zero is rated zero; None means unrated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RatingHalfSteps(u8);

impl RatingHalfSteps {
    pub(crate) fn new(value: u8) -> Result<Self, &'static str> {
        if value <= 10 {
            Ok(Self(value))
        } else {
            Err("Rating half steps must be between 0 and 10")
        }
    }
    pub(crate) fn from_whole_stars(value: u8) -> Result<Self, &'static str> {
        if value <= 5 {
            Ok(Self(value * 2))
        } else {
            Err("Whole-star rating must be between 0 and 5")
        }
    }
    pub(crate) fn get(self) -> u8 {
        self.0
    }
    pub(crate) fn is_fractional(self) -> bool {
        self.0 % 2 != 0
    }
    pub(crate) fn parse_stars(text: &str) -> Result<Self, &'static str> {
        let text = text.trim();
        let (whole, fraction) = text.split_once('.').unwrap_or((text, "0"));
        let whole = whole.parse::<u8>().map_err(|_| "Invalid star rating")?;
        let base = Self::from_whole_stars(whole)?.get();
        let fraction = match fraction.trim_end_matches('0') {
            "" => 0,
            "5" => 1,
            _ => return Err("Ratings require half-star increments"),
        };
        Self::new(base + fraction)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rating_units_and_star_thresholds_are_exact_and_reject_invalid_values() {
        for value in 0..=10 {
            assert_eq!(RatingHalfSteps::new(value).unwrap().get(), value);
        }
        assert!(RatingHalfSteps::new(11).is_err());
        for value in 0..=5 {
            assert_eq!(
                RatingHalfSteps::from_whole_stars(value).unwrap().get(),
                value * 2
            );
        }
        assert!(RatingHalfSteps::from_whole_stars(6).is_err());
        for (text, expected) in [
            ("0", 0),
            ("0.5", 1),
            ("3.5", 7),
            ("4", 8),
            ("4.50", 9),
            ("5.0", 10),
        ] {
            assert_eq!(RatingHalfSteps::parse_stars(text).unwrap().get(), expected);
        }
        for text in ["5.5", "4.25", "NaN", "-1", "11", "", "4,5"] {
            assert!(RatingHalfSteps::parse_stars(text).is_err(), "{text}");
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum RatingError {
    #[error("{0}")]
    InvalidInput(String),
    #[error("{0}")]
    Storage(String),
}
