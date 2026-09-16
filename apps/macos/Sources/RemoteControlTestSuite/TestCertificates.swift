import Foundation
import RCTestKit
import RemoteControlCore

/// Real certificate bytes, so the pinning tests are about actual DER rather than
/// about a string comparison we wrote ourselves.
///
/// `liveServerCertificateDER` is the certificate `rc-signal` is serving right
/// now at wss://54.246.73.81:8443 (infra/certs/server.crt). `otherCertificateDER`
/// is an unrelated self-signed certificate — the stand-in for "someone else's
/// server, or an interception proxy".
enum TestCertificates {
    static let liveServerBase64 =
        "MIIBsjCCAVigAwIBAgIUMTsGYpSB8QS/Al9XRNtJQus7us4wCgYIKoZIzj0EAwIwFDESMBAG" +
        "A1UEAwwJcmMtc2lnbmFsMB4XDTI2MDgxOTA5NDQyOVoXDTM2MDgxNjA5NDQyOVowFDESMBAG" +
        "A1UEAwwJcmMtc2lnbmFsMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAED/4XsI01xRCj9EQA" +
        "nOg5lDdONl/lhNnUAEMybDgVi+3qDIJSJpjIK4SlmdOFOV97aa9K3arCOR7Ay9oBHfLTFqOB" +
        "hzCBhDAdBgNVHQ4EFgQUDFvpRScwMvNuONbr7R2jCdwqwnQwHwYDVR0jBBgwFoAUDFvpRScw" +
        "MvNuONbr7R2jCdwqwnQwDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwQ29klRMAsGA1Ud" +
        "DwQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAKBggqhkjOPQQDAgNIADBFAiEA/eAyGCI4" +
        "fxCIaLJz+7+SLsCkUxHKqsGyBG5BcVlobmYCIHLsKM90uJ/vXzERJRKTfUD1fbU8aLGJRuIZ" +
        "EvLpq58Y"

    static let otherBase64 =
        "MIIDETCCAfmgAwIBAgIUeyue81g6B9nd5qTAGg3EnOEMyrYwDQYJKoZIhvcNAQELBQAwGDEW" +
        "MBQGA1UEAwwNcmMtdGVzdC1vdGhlcjAeFw0yNjA4MTkxNTMwNDVaFw0yNjA4MjIxNTMwNDVa" +
        "MBgxFjAUBgNVBAMMDXJjLXRlc3Qtb3RoZXIwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK" +
        "AoIBAQCqui77Wm1O7rwHjdMrukKjIwqNVqko1U603swBEDhoOdByHVE3TSg7g27VR4sx0o6p" +
        "N5qkIvNoTAtyZvUyMeAqZouM87mjec8Hkr7Udezf8CxHgc0RqXi2xtXB/PuNjX/7fsGRzCPX" +
        "7UfOYP0qtpal3Gy37pX3tJaApUzPePTBTkp3ONIcLpL9YUchO06Tka+YE1pV+zEsxSLiwqZE" +
        "I90wWU2wgbDtsXzYRiA+cw+GK8kTVfBseMtlu8duJqYshzZldljAcKVR1wbsCGcdDtW8rHDa" +
        "/6zrLkTmA42DuawxWrfaZT72aHtPwBajVQ/aB+XDsVlN6R1saYYTctn/J4izAgMBAAGjUzBR" +
        "MB0GA1UdDgQWBBQsYLXDZxTOQ6PS/AMr6LtpQsUGdDAfBgNVHSMEGDAWgBQsYLXDZxTOQ6PS" +
        "/AMr6LtpQsUGdDAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAgkOIHjp5q" +
        "O/qGYabeV2VaK7O7TBgwl8CEhHWuH+iJDCg6u+icU7rGiNI0i9ebMaPHvoOTXEfYxOdxRCEd" +
        "EbdFe+IffE9wtoGtCZoTusQNMRf0zxJHmfAEOupvTeTSxNTttKWsRZOo7I7V+QvcxiXhXFq1" +
        "l49mviII1zJJA0yomgw0ssBb8qgvPXT8JBmuQqOH9jR/BapyO2tNvfgjjNL3wLMtI3zRtFzP" +
        "o2CLipm/gHkscz6+c+xl1HtTd3U7jXUO9gBeda9cjxpVavDKmT49nAZY+J8xwq9B0AdirNGq" +
        "Rvt7u7JVAylp6RaYznD31c6N2y5AJ6mtm2cs3+jZmLNw"

    static let liveServerPin = "E30xoxEp9t658+TJEVdaGb8Ooi7HGGMWp1kxVpeSpgk="
    static let otherPin = "CQ9WeOv5AhI7o+z4RMzfip4R1w76Vp/bULeqSYft11Y="

    static var live: Data { Data(base64Encoded: liveServerBase64)! }
    static var other: Data { Data(base64Encoded: otherBase64)! }
}
