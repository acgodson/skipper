use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::consts::VERSION;

/// `payload` is always present and never `null` on the wire; a type with no
/// fields sends `{}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub v: i32,
    #[serde(rename = "type")]
    pub msg_type: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub re: String,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub ts: i64,
    #[serde(default = "empty_object", deserialize_with = "null_as_empty_object")]
    pub payload: Value,
}

fn is_zero(v: &i64) -> bool {
    *v == 0
}

fn empty_object() -> Value {
    Value::Object(serde_json::Map::new())
}

fn null_as_empty_object<'de, D>(d: D) -> Result<Value, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let v = Value::deserialize(d)?;
    Ok(if v.is_null() { empty_object() } else { v })
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum DecodeError {
    #[error("malformed JSON: {0}")]
    Json(String),
    #[error("unsupported protocol version {0}")]
    Version(i32),
    #[error("missing type")]
    MissingType,
    #[error("frame of {0} bytes exceeds the {1} byte maximum")]
    TooLarge(usize, usize),
    #[error("payload does not match {0}: {1}")]
    Payload(&'static str, String),
}

impl Envelope {
    /// `id` and `re` may be empty; `payload` of `None` becomes `{}`.
    pub fn new<T: Serialize>(
        msg_type: &str,
        id: &str,
        re: &str,
        now_ms: i64,
        payload: Option<&T>,
    ) -> Result<Self, DecodeError> {
        let payload = match payload {
            None => empty_object(),
            Some(p) => serde_json::to_value(p).map_err(|e| DecodeError::Json(e.to_string()))?,
        };
        Ok(Self {
            v: VERSION,
            msg_type: msg_type.to_string(),
            id: id.to_string(),
            re: re.to_string(),
            ts: now_ms,
            payload,
        })
    }

    pub fn encode(&self) -> Result<Vec<u8>, DecodeError> {
        serde_json::to_vec(self).map_err(|e| DecodeError::Json(e.to_string()))
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        if bytes.len() > crate::consts::MAX_FRAME_BYTES {
            return Err(DecodeError::TooLarge(
                bytes.len(),
                crate::consts::MAX_FRAME_BYTES,
            ));
        }
        let env: Envelope =
            serde_json::from_slice(bytes).map_err(|e| DecodeError::Json(e.to_string()))?;
        if env.v != VERSION {
            return Err(DecodeError::Version(env.v));
        }
        if env.msg_type.is_empty() {
            return Err(DecodeError::MissingType);
        }
        Ok(env)
    }

    /// An absent payload decodes as `{}`.
    pub fn payload_as<T: serde::de::DeserializeOwned>(&self) -> Result<T, DecodeError> {
        let v = if self.payload.is_null() {
            &Value::Object(serde_json::Map::new())
        } else {
            &self.payload
        };
        serde_json::from_value(v.clone())
            .map_err(|e| DecodeError::Payload(std::any::type_name::<T>(), e.to_string()))
    }
}

/// Exactly 9 ASCII digits; leading zeros are significant.
pub fn valid_device_id(s: &str) -> bool {
    s.len() == 9 && s.bytes().all(|b| b.is_ascii_digit())
}
