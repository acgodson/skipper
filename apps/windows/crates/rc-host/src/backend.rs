//! The one configured value and everything derived from it, mirroring
//! `Config.swift` (`deriveSignalingURL`, `BackendURLPolicy`, `BackendOverrides`)
//! so a Windows host and a Mac pointed at the same domain reach the same
//! deployment.
//!
//! There is no compiled-in address and no certificate pin: `wss` is validated
//! by the system's public CA store like any other HTTPS client.

pub const API_VARIABLE: &str = "SKIPPER_API_BASE_URL";
pub const WEB_VARIABLE: &str = "SKIPPER_WEB_BASE_URL";
pub const DEFAULT_API_BASE_URL: &str = "https://api.skipperdesk.app";
pub const DEFAULT_WEB_BASE_URL: &str = "https://skipperdesk.app";

const LOCAL_DEVELOPMENT_HOSTS: [&str; 2] = ["localhost", "127.0.0.1"];

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum BackendUrlError {
    #[error("'{0}' is not a valid https:// URL")]
    Malformed(String),
    #[error("{scheme}:// against '{host}' is refused; only https:// is allowed outside localhost/127.0.0.1")]
    Insecure { scheme: String, host: String },
}

/// Scheme, host and optional port — the only parts of a base URL that are
/// load-bearing here. A base URL's path is ignored: every route is absolute.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BaseUrl {
    pub scheme: String,
    pub host: String,
    pub port: Option<u16>,
}

impl BaseUrl {
    pub fn parse(raw: &str) -> Result<Self, BackendUrlError> {
        let malformed = || BackendUrlError::Malformed(raw.to_string());
        let (scheme, rest) = raw.split_once("://").ok_or_else(malformed)?;
        let scheme = scheme.to_ascii_lowercase();
        let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
        if authority.is_empty() || authority.contains('@') {
            return Err(malformed());
        }
        let (host, port) = split_host_port(authority).ok_or_else(malformed)?;
        let host = host.to_ascii_lowercase();
        if host.is_empty() {
            return Err(malformed());
        }
        let local = LOCAL_DEVELOPMENT_HOSTS.contains(&host.as_str());
        match scheme.as_str() {
            "https" => {}
            "http" if local => {}
            _ => return Err(BackendUrlError::Insecure { scheme, host }),
        }
        Ok(Self { scheme, host, port })
    }

    pub fn authority(&self) -> String {
        match self.port {
            Some(port) => format!("{}:{port}", self.host),
            None => self.host.clone(),
        }
    }

    pub fn origin(&self) -> String {
        format!("{}://{}", self.scheme, self.authority())
    }

    pub fn url(&self, path: &str) -> String {
        format!("{}{path}", self.origin())
    }

    /// `wss://<domain>/ws`, or `ws://` when the API itself is plain HTTP
    /// (local development only). rc-api proxies `/ws` to rc-signal, so one
    /// configured domain is enough.
    pub fn signaling_url(&self) -> String {
        let scheme = if self.scheme == "http" { "ws" } else { "wss" };
        format!("{scheme}://{}/ws", self.authority())
    }

    /// The sign-in website: the API domain with a leading `api.` label
    /// dropped, as `AccountLinker.defaultWebBaseURL` does.
    pub fn web_base_url(&self) -> BaseUrl {
        let host = self
            .host
            .strip_prefix("api.")
            .filter(|rest| rest.contains('.'))
            .unwrap_or(&self.host);
        BaseUrl {
            scheme: self.scheme.clone(),
            host: host.to_string(),
            port: self.port,
        }
    }
}

fn split_host_port(authority: &str) -> Option<(&str, Option<u16>)> {
    if let Some(rest) = authority.strip_prefix('[') {
        let (host, tail) = rest.split_once(']')?;
        let port = match tail.strip_prefix(':') {
            Some(port) => Some(port.parse().ok()?),
            None if tail.is_empty() => None,
            None => return None,
        };
        return Some((host, port));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) => Some((host, Some(port.parse().ok()?))),
        None => Some((authority, None)),
    }
}

/// The API and sign-in domains this process will use. `SKIPPER_WEB_BASE_URL`
/// exists because a deployment whose API host is not `api.<site>` cannot be
/// derived from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Backend {
    pub api: BaseUrl,
    pub web: BaseUrl,
}

impl Backend {
    pub fn resolve(
        api_override: Option<&str>,
        web_override: Option<&str>,
    ) -> Result<Self, BackendUrlError> {
        let api = BaseUrl::parse(api_override.unwrap_or(DEFAULT_API_BASE_URL))?;
        let web = match web_override {
            Some(raw) => BaseUrl::parse(raw)?,
            None if api_override.is_none() => BaseUrl::parse(DEFAULT_WEB_BASE_URL)?,
            None => api.web_base_url(),
        };
        Ok(Self { api, web })
    }

    pub fn from_environment() -> Result<Self, BackendUrlError> {
        let read = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
        Self::resolve(read(API_VARIABLE).as_deref(), read(WEB_VARIABLE).as_deref())
    }
}

#[cfg(test)]
mod tests;
