//! Ownership-checked batch API. No daemon management or remote path inference.
use super::slskd_search::{SlskdSearch, client, endpoint, request};
use crate::{
    api::DownloadFileState as S,
    application::{
        music_catalog::IntegrationFuture, music_plugins::PluginContext, transfer_ports::*,
    },
    domain::music::{ContractError, IntegrationError as E},
};
use reqwest::{Client, Method};
use serde_json::{Value, json};
use url::Url;
pub(crate) fn uuid(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn invalid() -> E {
    E::InvalidInput(ContractError::InvalidSearch)
}
fn peer_path(peer: &str) -> Result<String, E> {
    if peer.is_empty() || peer.len() > 512 || peer.chars().any(char::is_control) {
        return Err(invalid());
    }
    let mut url = Url::parse("https://placeholder/").unwrap();
    url.path_segments_mut().unwrap().push(peer);
    Ok(url.path().trim_start_matches('/').into())
}
impl DownloadTransferProvider for SlskdSearch {
    fn transfer(
        &self,
        context: PluginContext,
        command: TransferCommand,
    ) -> IntegrationFuture<'_, TransferReceipt> {
        Box::pin(async move {
            let enqueue = matches!(&command.action, TransferAction::Enqueue { .. });
            let prepared = (|| {
                let (client, base) = client(&context)?;
                if endpoint(&command.endpoint).map_err(|_| invalid())? != base {
                    return Err(E::AccessDenied);
                }
                Ok((client, base))
            })();
            let (client, base) = match prepared {
                Ok(value) => value,
                Err(e) if enqueue => {
                    return Ok(TransferReceipt {
                        rows: vec![],
                        not_submitted: Some(e),
                    });
                }
                Err(e) => return Err(e),
            };
            match command.action {
                TransferAction::Inspect {
                    batch_id,
                    peer,
                    destination,
                    files,
                } => inspect(&client, &base, &batch_id, &peer, &destination, &files).await,
                TransferAction::Enqueue {
                    batch_id,
                    peer,
                    destination,
                    files,
                    previous,
                } => {
                    let preflight = async {
                        validate(&batch_id, &destination, &files)?;
                        match inspect(&client, &base, &batch_id, &peer, &destination, &files).await
                        {
                            Ok(r) => return Ok(Some(r)),
                            Err(E::NotFound) => {}
                            Err(e) => return Err(e),
                        }
                        // Never supersede transfers belonging to another client or job.
                        let existing = match request(
                            &client,
                            &base,
                            Method::GET,
                            &format!("transfers/downloads/{}", peer_path(&peer)?),
                            None,
                        )
                        .await
                        {
                            Ok(v) => v,
                            Err(E::NotFound) => json!([]),
                            Err(e) => return Err(e),
                        };
                        for row in peer_files(&existing)? {
                            if let Some(file) = files.iter().find(|f| {
                                row.get("filename").and_then(Value::as_str) == Some(&f.filename)
                            }) {
                                let permitted = previous.iter().any(|own| {
                                    row.get("id").and_then(Value::as_str) == Some(&own.transfer_id)
                                        && row.get("batchId").and_then(Value::as_str)
                                            == Some(&own.batch_id)
                                        && own.file.filename == file.filename
                                        && row.get("size").and_then(Value::as_u64)
                                            == Some(file.size)
                                        && terminal_failure(
                                            row.get("state").and_then(Value::as_str).unwrap_or(""),
                                        )
                                });
                                if !permitted {
                                    return Err(E::AccessDenied);
                                }
                            }
                        }
                        Ok::<_, E>(None)
                    }
                    .await;
                    match preflight {
                        Ok(Some(receipt)) => return Ok(receipt),
                        Err(e) => {
                            return Ok(TransferReceipt {
                                rows: vec![],
                                not_submitted: Some(e),
                            });
                        }
                        Ok(None) => {}
                    }
                    let body = json!({"id":batch_id,"username":peer,"options":{"destination":destination},"files":files.iter().map(|f|json!({"filename":f.filename,"size":f.size})).collect::<Vec<_>>()});
                    match request(
                        &client,
                        &base,
                        Method::POST,
                        "transfers/downloads/batches",
                        Some(body),
                    )
                    .await
                    {
                        Ok(value) => receipt(
                            value.get("batch").ok_or(E::InvalidResponse)?,
                            &batch_id,
                            &peer,
                            &destination,
                            &files,
                        ),
                        Err(original) => {
                            inspect(&client, &base, &batch_id, &peer, &destination, &files)
                                .await
                                .or(Err(original))
                        }
                    }
                }
                TransferAction::Cancel {
                    identity,
                    peer,
                    destination,
                } => {
                    validate(
                        &identity.batch_id,
                        &destination,
                        std::slice::from_ref(&identity.file),
                    )?;
                    if !uuid(&identity.transfer_id) {
                        return Err(invalid());
                    }
                    // Inspect the complete batch; cancelling one file must not reject its siblings.
                    let batch = request(
                        &client,
                        &base,
                        Method::GET,
                        &format!("transfers/downloads/batches/{}", identity.batch_id),
                        None,
                    )
                    .await?;
                    validate_batch(&batch, &identity.batch_id, &peer, &destination)?;
                    let row = batch
                        .get("transfers")
                        .and_then(Value::as_array)
                        .ok_or(E::InvalidResponse)?
                        .iter()
                        .find(|r| {
                            r.get("id").and_then(Value::as_str) == Some(&identity.transfer_id)
                        })
                        .ok_or(E::NotFound)?;
                    let row = parse_row(
                        row,
                        &identity.batch_id,
                        &peer,
                        std::slice::from_ref(&identity.file),
                    )?;
                    if !matches!(row.state, S::Completed | S::Cancelled | S::Failed) {
                        request(
                            &client,
                            &base,
                            Method::DELETE,
                            &format!(
                                "transfers/downloads/{}/{}",
                                peer_path(&peer)?,
                                identity.transfer_id
                            ),
                            None,
                        )
                        .await?;
                    }
                    Ok(TransferReceipt {
                        rows: vec![row],
                        not_submitted: None,
                    })
                }
            }
        })
    }
}
fn validate(batch: &str, destination: &str, files: &[TransferFileSpec]) -> Result<(), E> {
    if !uuid(batch)
        || destination.is_empty()
        || destination.starts_with('/')
        || destination.contains('\\')
        || destination
            .split('/')
            .any(|c| c.is_empty() || c == ".." || c == ".")
        || files.is_empty()
        || files.len() > 500
    {
        return Err(invalid());
    }
    let mut names = std::collections::HashSet::new();
    if files.iter().any(|f| {
        f.size == 0
            || f.size > i64::MAX as u64
            || f.filename.len() > 4096
            || f.filename.chars().any(char::is_control)
            || f.filename.replace('\\', "/").split('/').any(|c| c == "..")
            || !names.insert(&f.filename)
    }) {
        return Err(invalid());
    }
    Ok(())
}
fn peer_files(value: &Value) -> Result<Vec<&Value>, E> {
    if let Some(rows) = value.as_array() {
        return Ok(rows.iter().collect());
    }
    let directories = value
        .get("directories")
        .and_then(Value::as_array)
        .ok_or(E::InvalidResponse)?;
    let mut rows = vec![];
    for directory in directories {
        rows.extend(
            directory
                .get("files")
                .and_then(Value::as_array)
                .ok_or(E::InvalidResponse)?
                .iter(),
        );
    }
    Ok(rows)
}
async fn inspect(
    client: &Client,
    base: &Url,
    batch: &str,
    peer: &str,
    destination: &str,
    files: &[TransferFileSpec],
) -> Result<TransferReceipt, E> {
    validate(batch, destination, files)?;
    let value = request(
        client,
        base,
        Method::GET,
        &format!("transfers/downloads/batches/{batch}"),
        None,
    )
    .await?;
    receipt(&value, batch, peer, destination, files)
}
fn validate_batch(value: &Value, batch: &str, peer: &str, destination: &str) -> Result<(), E> {
    if value.get("id").and_then(Value::as_str) != Some(batch)
        || value.get("username").and_then(Value::as_str) != Some(peer)
        || value
            .get("options")
            .and_then(|v| v.get("destination"))
            .and_then(Value::as_str)
            .map(|v| v.replace('\\', "/"))
            != Some(destination.into())
    {
        return Err(E::InvalidResponse);
    }
    Ok(())
}
fn receipt(
    value: &Value,
    batch: &str,
    peer: &str,
    destination: &str,
    files: &[TransferFileSpec],
) -> Result<TransferReceipt, E> {
    validate_batch(value, batch, peer, destination)?;
    let rows = value
        .get("transfers")
        .and_then(Value::as_array)
        .ok_or(E::InvalidResponse)?;
    if rows.len() > files.len() {
        return Err(E::InvalidResponse);
    }
    let mut names = std::collections::HashSet::new();
    let mut ids = std::collections::HashSet::new();
    let mut result = vec![];
    for row in rows {
        let row = parse_row(row, batch, peer, files)?;
        if !names.insert(row.file.filename.clone()) || !ids.insert(row.transfer_id.clone()) {
            return Err(E::InvalidResponse);
        }
        result.push(row);
    }
    Ok(TransferReceipt {
        rows: result,
        not_submitted: None,
    })
}
fn terminal_failure(state: &str) -> bool {
    let flags: Vec<_> = state.split(',').map(str::trim).collect();
    flags.contains(&"Completed") && !flags.contains(&"Succeeded")
}
fn parse_row(
    row: &Value,
    batch: &str,
    peer: &str,
    files: &[TransferFileSpec],
) -> Result<TransferRow, E> {
    let id = row
        .get("id")
        .and_then(Value::as_str)
        .filter(|v| uuid(v))
        .ok_or(E::InvalidResponse)?;
    if row.get("batchId").and_then(Value::as_str) != Some(batch)
        || row
            .get("username")
            .and_then(Value::as_str)
            .is_some_and(|v| v != peer)
    {
        return Err(E::InvalidResponse);
    }
    let file = files
        .iter()
        .find(|f| {
            row.get("filename").and_then(Value::as_str) == Some(&f.filename)
                && row.get("size").and_then(Value::as_u64) == Some(f.size)
        })
        .ok_or(E::InvalidResponse)?;
    let bytes = row
        .get("bytesTransferred")
        .and_then(Value::as_u64)
        .ok_or(E::InvalidResponse)?;
    if bytes > file.size {
        return Err(E::InvalidResponse);
    }
    let state = row
        .get("state")
        .and_then(Value::as_str)
        .ok_or(E::InvalidResponse)?;
    let flags: Vec<_> = state.split(',').map(str::trim).collect();
    let state =
        if flags.contains(&"Completed") && flags.contains(&"Succeeded") && bytes == file.size {
            S::Completed
        } else if flags.contains(&"Cancelled") {
            S::Cancelled
        } else if flags.contains(&"Completed") || flags.contains(&"Errored") {
            S::Failed
        } else if flags.contains(&"InProgress") || bytes > 0 {
            S::Downloading
        } else {
            S::Queued
        };
    Ok(TransferRow {
        transfer_id: id.into(),
        file: file.clone(),
        state,
        bytes,
        queue: row
            .get("placeInQueue")
            .and_then(Value::as_u64)
            .and_then(|v| u32::try_from(v).ok()),
    })
}

#[cfg(test)]
mod tests;
