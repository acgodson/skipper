//! Every argument crosses the boundary as (pointer, length). Nothing here
//! looks for a terminator, so a NUL inside a value can never shorten what the
//! core checks relative to what the caller later uses.

unsafe fn raw_bytes<'a>(
    pointer: *const u8,
    len: usize,
    name: &str,
) -> Result<Option<&'a [u8]>, String> {
    if pointer.is_null() {
        return match len {
            0 => Ok(None),
            _ => Err(format!("argument {name} is null but has length {len}")),
        };
    }
    if len > isize::MAX as usize {
        return Err(format!("argument {name} is too long"));
    }
    Ok(Some(unsafe { std::slice::from_raw_parts(pointer, len) }))
}

/// # Safety
///
/// `pointer` is null (with `len` 0) or valid for `len` bytes that outlive the call.
pub(crate) unsafe fn optional_text<'a>(
    pointer: *const u8,
    len: usize,
    name: &str,
) -> Result<Option<&'a str>, String> {
    let Some(bytes) = (unsafe { raw_bytes(pointer, len, name) })? else {
        return Ok(None);
    };
    let text =
        std::str::from_utf8(bytes).map_err(|_| format!("argument {name} is not valid UTF-8"))?;
    if text.contains('\0') {
        return Err(format!("argument {name} contains a NUL byte"));
    }
    Ok(Some(text))
}

pub(crate) unsafe fn required_text<'a>(
    pointer: *const u8,
    len: usize,
    name: &str,
) -> Result<&'a str, String> {
    unsafe { optional_text(pointer, len, name) }?
        .ok_or_else(|| format!("argument {name} must not be null"))
}

pub(crate) unsafe fn payload_bytes<'a>(
    pointer: *const u8,
    len: usize,
    name: &str,
) -> Result<&'a [u8], String> {
    Ok(unsafe { raw_bytes(pointer, len, name) }?.unwrap_or(&[]))
}

#[cfg(test)]
mod tests;
