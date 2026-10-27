//! Pure Replay configuration and period policy shared by application and storage.
use crate::api::{
    ReplayPeriod, ReplayRequest, ReplaySaveMode, SmartPlaylistDefinition, SmartPlaylistRule,
};
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Definition {
    pub version: u8,
    pub period: String,
    pub start_at: i64,
    pub end_at: i64,
    pub mode: String,
    pub close_automatically: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artwork_base64: Option<String>,
}

pub(crate) fn policy(period: ReplayPeriod) -> (&'static str, u32, u32, u32) {
    match period {
        ReplayPeriod::Daily => ("daily", 5, 10, 25),
        ReplayPeriod::Weekly => ("weekly", 10, 25, 50),
        ReplayPeriod::Monthly => ("monthly", 20, 50, 100),
        ReplayPeriod::Yearly => ("yearly", 50, 100, 200),
    }
}

pub(crate) fn definition(
    request: &ReplayRequest,
    mode: ReplaySaveMode,
    close_automatically: bool,
    artwork_base64: Option<String>,
    now: i64,
) -> Result<SmartPlaylistDefinition, String> {
    let (period, _, standard, _) = policy(request.period);
    let current = request.start_at <= now && now < request.end_at;
    let value = Definition {
        version: 1,
        period: period.into(),
        start_at: request.start_at,
        end_at: request.end_at,
        mode: if mode == ReplaySaveMode::Live && current {
            "live"
        } else {
            "snapshot"
        }
        .into(),
        close_automatically,
        artwork_base64,
    };
    let definition = SmartPlaylistDefinition {
        match_all: true,
        rules: vec![SmartPlaylistRule {
            field: "retrospective".into(),
            comparison: "equals".into(),
            value: serde_json::to_string(&value).map_err(|error| error.to_string())?,
        }],
        limit: Some(standard),
        sort_by: "retrospective_score".into(),
        descending: true,
    };
    config(&definition)?;
    Ok(definition)
}

pub(crate) fn limits(period: &str) -> Option<(usize, usize)> {
    let period = match period {
        "daily" => ReplayPeriod::Daily,
        "weekly" => ReplayPeriod::Weekly,
        "monthly" => ReplayPeriod::Monthly,
        "yearly" => ReplayPeriod::Yearly,
        _ => return None,
    };
    let (_, minimum, _, maximum) = policy(period);
    Some((minimum as usize, maximum as usize))
}

pub(crate) fn config(definition: &SmartPlaylistDefinition) -> Result<Option<Definition>, String> {
    let retrospective = definition.sort_by == "retrospective_score"
        || definition
            .rules
            .iter()
            .any(|rule| rule.field == "retrospective");
    if !retrospective {
        return Ok(None);
    }
    if definition.rules.len() != 1
        || definition.rules[0].field != "retrospective"
        || definition.rules[0].comparison != "equals"
        || !definition.match_all
        || !definition.descending
        || definition.sort_by != "retrospective_score"
    {
        return Err("Invalid retrospective playlist rule".into());
    }
    let value: Definition =
        serde_json::from_str(&definition.rules[0].value).map_err(|error| error.to_string())?;
    let (minimum, maximum) = limits(&value.period).ok_or("Invalid retrospective period")?;
    let limit = definition
        .limit
        .ok_or("A retrospective playlist requires a limit")? as usize;
    if value.version != 1
        || value.start_at >= value.end_at
        || chrono::DateTime::from_timestamp(value.start_at, 0).is_none()
        || chrono::DateTime::from_timestamp(value.end_at, 0).is_none()
        || !matches!(value.mode.as_str(), "live" | "snapshot")
        || !(minimum..=maximum).contains(&limit)
    {
        return Err("Invalid retrospective playlist configuration".into());
    }
    // Calendar boundaries are supplied by the client, including its time zone/DST.
    let maximum_span = match value.period.as_str() {
        "daily" => 90_000,
        "weekly" => 608_400,
        "monthly" => 2_682_000,
        _ => 31_626_000,
    };
    if value.end_at.saturating_sub(value.start_at) > maximum_span {
        return Err("Retrospective interval exceeds its period".into());
    }
    Ok(Some(value))
}
