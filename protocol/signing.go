package protocol

import (
	"crypto/sha256"
	"fmt"
)

// SigningPurpose names what a device-key signature is for (PROTOCOL.md §3.1).
type SigningPurpose string

const (
	PurposeHello        SigningPurpose = "hello"
	PurposeRegister     SigningPurpose = "register"
	PurposeSDP          SigningPurpose = "sdp"
	PurposeAPIChallenge SigningPurpose = "api-challenge"
)

// NonceLen is the only accepted length of a challenge nonce.
const NonceLen = 32

var SigningPurposes = []SigningPurpose{PurposeHello, PurposeRegister, PurposeSDP, PurposeAPIChallenge}

func (p SigningPurpose) takesNonce() bool { return p != PurposeSDP }

func (p SigningPurpose) known() bool {
	for _, known := range SigningPurposes {
		if p == known {
			return true
		}
	}
	return false
}

// SigningMessage is the exact byte string a device key signs:
// "skipperdesk/" purpose "/v1|" followed by payload. Nonce purposes require a
// payload of exactly NonceLen bytes.
func SigningMessage(purpose SigningPurpose, payload []byte) ([]byte, error) {
	if !purpose.known() {
		return nil, fmt.Errorf("unknown signing purpose %q", purpose)
	}
	if purpose.takesNonce() && len(payload) != NonceLen {
		return nil, fmt.Errorf("a %s nonce must be exactly %d bytes, got %d", purpose, NonceLen, len(payload))
	}
	if len(payload) == 0 {
		return nil, fmt.Errorf("an %s signing payload must not be empty", purpose)
	}
	return append([]byte(signingPrefix(purpose)), payload...), nil
}

func signingPrefix(purpose SigningPurpose) string {
	return "skipperdesk/" + string(purpose) + "/v1|"
}

// PurposeDeviceIDCert is signed by the registry's own key, never by a device key,
// so it is deliberately not one of SigningPurposes.
const PurposeDeviceIDCert SigningPurpose = "device-id-cert"

// DeviceIDCertMessage is what an idCert signs: the prefix, the 9-digit deviceId,
// then SHA-256 of the device's DER SPKI public key.
func DeviceIDCertMessage(deviceID string, pubkeyDER []byte) ([]byte, error) {
	if !ValidDeviceID(deviceID) {
		return nil, fmt.Errorf("a device-id certificate needs a 9-digit deviceId, got %q", deviceID)
	}
	if len(pubkeyDER) == 0 {
		return nil, fmt.Errorf("a device-id certificate needs a public key")
	}
	digest := sha256.Sum256(pubkeyDER)
	message := append([]byte(signingPrefix(PurposeDeviceIDCert)), deviceID...)
	return append(message, digest[:]...), nil
}
