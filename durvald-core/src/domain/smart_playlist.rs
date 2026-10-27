//! Pure smart-playlist validation; contains no persistence operations.
const SMART_FIELDS: &[&str] = &[
    "rating",
    "favorite",
    "genre",
    "user_tag",
    "release_user_tag",
    "year",
    "play_count",
    "last_played",
    "date_added",
];
const SMART_COMPARISONS: &[&str] = &[
    "equals",
    "not_equals",
    "greater",
    "greater_or_equal",
    "less",
    "less_or_equal",
    "contains",
    "before",
    "after",
    "is_empty",
    "is_not_empty",
];
const SMART_SORT_FIELDS: &[&str] = &[
    "title",
    "artist",
    "album",
    "rating",
    "play_count",
    "last_played",
    "date_added",
    "year",
];

pub(crate) fn validate_smart_playlist_definition(
    definition: &crate::api::SmartPlaylistDefinition,
) -> Result<(), String> {
    if super::replay::config(definition)?.is_some() {
        return Ok(());
    }
    if definition.rules.is_empty() {
        return Err("A smart playlist must contain at least one rule".into());
    }
    if definition.rules.len() > 32 {
        return Err("A smart playlist cannot contain more than 32 rules".into());
    }
    if definition.limit == Some(0) || definition.limit.is_some_and(|value| value > 10_000) {
        return Err("Smart playlist limit must be between 1 and 10000".into());
    }
    if !SMART_SORT_FIELDS.contains(&definition.sort_by.as_str()) {
        return Err("Unsupported smart playlist sort field".into());
    }
    for rule in &definition.rules {
        if !SMART_FIELDS.contains(&rule.field.as_str()) {
            return Err(format!("Unsupported smart playlist field: {}", rule.field));
        }
        if !SMART_COMPARISONS.contains(&rule.comparison.as_str()) {
            return Err(format!(
                "Unsupported smart playlist comparison: {}",
                rule.comparison
            ));
        }
        let no_value = matches!(rule.comparison.as_str(), "is_empty" | "is_not_empty");
        let comparison_allowed = match rule.field.as_str() {
            "favorite" => matches!(rule.comparison.as_str(), "equals" | "not_equals"),
            "genre" => matches!(
                rule.comparison.as_str(),
                "equals" | "not_equals" | "contains" | "is_empty" | "is_not_empty"
            ),
            "user_tag" | "release_user_tag" => matches!(
                rule.comparison.as_str(),
                "equals" | "not_equals" | "is_empty" | "is_not_empty"
            ),
            "last_played" | "date_added" => matches!(
                rule.comparison.as_str(),
                "before" | "after" | "is_empty" | "is_not_empty"
            ),
            _ => matches!(
                rule.comparison.as_str(),
                "equals"
                    | "not_equals"
                    | "greater"
                    | "greater_or_equal"
                    | "less"
                    | "less_or_equal"
                    | "is_empty"
                    | "is_not_empty"
            ),
        };
        if !comparison_allowed {
            return Err(format!(
                "Comparison {} is not valid for {}",
                rule.comparison, rule.field
            ));
        }
        if !no_value && rule.value.trim().is_empty() {
            return Err("Smart playlist rule value cannot be empty".into());
        }
        if matches!(rule.field.as_str(), "user_tag" | "release_user_tag")
            && !no_value
            && rule
                .value
                .parse::<i64>()
                .ok()
                .filter(|id| *id > 0)
                .is_none()
        {
            return Err("Personal tag rules require a positive tag ID".into());
        }
        if rule.field == "rating" && !no_value {
            crate::domain::rating::RatingHalfSteps::parse_stars(&rule.value)
                .map_err(str::to_owned)?;
        }
        if matches!(rule.field.as_str(), "year" | "play_count")
            && !no_value
            && rule.value.parse::<i64>().is_err()
        {
            return Err(format!("{} rules require a whole number", rule.field));
        }
        if !no_value {
            let numeric = rule.value.parse::<i64>().ok();

            if rule.field == "year" && numeric.is_some_and(|value| !(1..=9999).contains(&value)) {
                return Err("Year rules require a value between 1 and 9999".into());
            }
            if rule.field == "play_count" && numeric.is_some_and(|value| value < 0) {
                return Err("Play count rules cannot use a negative value".into());
            }
        }
        if rule.field == "favorite" && !no_value && !matches!(rule.value.as_str(), "true" | "false")
        {
            return Err("Favorite rules require true or false".into());
        }
        if matches!(rule.field.as_str(), "last_played" | "date_added")
            && !no_value
            && chrono::NaiveDate::parse_from_str(&rule.value, "%Y-%m-%d").is_err()
        {
            return Err("Date rules require the YYYY-MM-DD format".into());
        }
    }
    Ok(())
}
