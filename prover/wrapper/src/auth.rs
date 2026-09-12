// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Authentication (R8-A2).
//!
//! Implemented today: a bearer API key per account, with a rolling 24 h run quota.
//!
//! Intended scheme (documented in `README.md`, not implemented): a **Cartridge Controller session
//! signature**. The client signs the canonical submission digest
//! `h = poseidon(domain, run_id, program_id, leaf_key_0, …, leaf_key_n)` with its session key and
//! sends `X-Hellproof-Account`, `X-Hellproof-Session-Signature` and the session policy proof. The
//! wrapper resolves the account's `is_valid_signature` (SNIP-6) against a Starknet node,
//! checks the session policy allows "submit run", and uses the account address as the quota key.
//! `Authenticator` is the seam: `ApiKeyAuth` today, `ControllerSessionAuth` next to it later,
//! with no change to the handlers.

use crate::config::{ApiKey, Config};

#[derive(Debug, Clone)]
pub struct Identity {
    /// Quota and ownership key: the account this submission is billed to.
    pub account: String,
    pub admin: bool,
    pub daily_run_quota: u32,
}

#[derive(Debug, PartialEq, Eq)]
pub enum AuthError {
    Missing,
    Invalid,
}

impl AuthError {
    pub fn message(&self) -> &'static str {
        match self {
            AuthError::Missing => "missing Authorization: Bearer <api-key>",
            AuthError::Invalid => "unknown API key",
        }
    }
}

pub trait Authenticator: Send + Sync {
    /// `authorization` is the raw header value, if present.
    fn authenticate(&self, authorization: Option<&str>) -> Result<Identity, AuthError>;
}

pub struct ApiKeyAuth {
    keys: Vec<ApiKey>,
}

impl ApiKeyAuth {
    pub fn new(cfg: &Config) -> Self {
        Self { keys: cfg.api_keys.clone() }
    }
}

impl Authenticator for ApiKeyAuth {
    fn authenticate(&self, authorization: Option<&str>) -> Result<Identity, AuthError> {
        let header = authorization.ok_or(AuthError::Missing)?;
        let token = header
            .strip_prefix("Bearer ")
            .or_else(|| header.strip_prefix("bearer "))
            .ok_or(AuthError::Missing)?
            .trim();
        if token.is_empty() {
            return Err(AuthError::Missing);
        }
        let key = self
            .keys
            .iter()
            .find(|k| constant_time_eq(k.key.as_bytes(), token.as_bytes()))
            .ok_or(AuthError::Invalid)?;
        Ok(Identity {
            account: key.account.clone(),
            admin: key.admin,
            daily_run_quota: key.daily_run_quota,
        })
    }
}

/// Comparison whose timing does not depend on where the first difference is.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        let mut c = Config::default();
        c.api_keys.push(ApiKey {
            key: "secret".into(),
            account: "0xabc".into(),
            admin: false,
            daily_run_quota: 10,
        });
        c.api_keys.push(ApiKey {
            key: "root".into(),
            account: "0xdef".into(),
            admin: true,
            daily_run_quota: 0,
        });
        c
    }

    #[test]
    fn accepts_a_known_key() {
        let auth = ApiKeyAuth::new(&cfg());
        let id = auth.authenticate(Some("Bearer secret")).unwrap();
        assert_eq!(id.account, "0xabc");
        assert!(!id.admin);
        assert_eq!(id.daily_run_quota, 10);
        assert!(auth.authenticate(Some("Bearer root")).unwrap().admin);
    }

    #[test]
    fn rejects_missing_and_wrong_keys() {
        let auth = ApiKeyAuth::new(&cfg());
        assert_eq!(auth.authenticate(None).unwrap_err(), AuthError::Missing);
        assert_eq!(auth.authenticate(Some("secret")).unwrap_err(), AuthError::Missing);
        assert_eq!(auth.authenticate(Some("Bearer ")).unwrap_err(), AuthError::Missing);
        assert_eq!(auth.authenticate(Some("Bearer nope")).unwrap_err(), AuthError::Invalid);
    }
}
