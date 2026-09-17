use super::*;

#[test]
fn a_session_id_is_exactly_32_lowercase_hex() {
    assert!(session_id("8c7f1a2b3c4d5e6f708192a3b4c5d6e7").is_ok());
    for bad in [
        "",
        "8c7f1a2b3c4d5e6f708192a3b4c5d6e",
        "8c7f1a2b3c4d5e6f708192a3b4c5d6e70",
        "8C7F1A2B3C4D5E6F708192A3B4C5D6E7",
        "8c7f1a2b3c4d5e6f708192a3b4c5d|e7",
        "sess-0001",
        "8c7f1a2b3c4d5e6f708192a3b4c5d6e\u{e9}",
    ] {
        assert_eq!(session_id(bad), Err(InputError::SessionId), "{bad:?}");
    }
}

#[test]
fn a_device_id_is_exactly_nine_ascii_digits() {
    assert!(device_id("739000587").is_ok());
    for bad in [
        "",
        "73900058",
        "7390005870",
        "739 000 587",
        "73900058x",
        "\u{0663}39000587",
        "Evil Mac",
    ] {
        assert_eq!(device_id(bad), Err(InputError::DeviceId), "{bad:?}");
    }
}

#[test]
fn only_offer_and_answer_are_sdp_types() {
    assert!(sdp_type("offer").is_ok());
    assert!(sdp_type("answer").is_ok());
    for bad in ["", "pranswer", "rollback", "Offer", "offer|x"] {
        assert_eq!(sdp_type(bad), Err(InputError::SdpType), "{bad:?}");
    }
}
