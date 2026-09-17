package protocol

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

func TestSigningMessageMatchesTheSharedVectors(t *testing.T) {
	raw, err := os.ReadFile("vectors/signing-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Version int `json:"version"`
		Cases   []struct {
			Name       string `json:"name"`
			Purpose    string `json:"purpose"`
			PayloadHex string `json:"payloadHex"`
			MessageHex string `json:"messageHex"`
			Valid      bool   `json:"valid"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if file.Version != Version || len(file.Cases) == 0 {
		t.Fatalf("vector file version %d with %d cases", file.Version, len(file.Cases))
	}
	for _, c := range file.Cases {
		payload, _ := hex.DecodeString(c.PayloadHex)
		message, err := SigningMessage(SigningPurpose(c.Purpose), payload)
		if !c.Valid {
			if err == nil {
				t.Errorf("%s: built a message the vectors say must be refused", c.Name)
			}
			continue
		}
		want, _ := hex.DecodeString(c.MessageHex)
		if err != nil || !bytes.Equal(message, want) {
			t.Errorf("%s: got %x, %v; want %x", c.Name, message, err, want)
		}
	}
}

func TestSigningMessagePrefixesNeverOverlap(t *testing.T) {
	nonce := make([]byte, NonceLen)
	seen := map[string]SigningPurpose{}
	for _, purpose := range SigningPurposes {
		message, err := SigningMessage(purpose, nonce)
		if err != nil {
			t.Fatal(err)
		}
		prefix := string(message[:len(message)-NonceLen])
		for other, otherPurpose := range seen {
			if bytes.HasPrefix([]byte(prefix), []byte(other)) || bytes.HasPrefix([]byte(other), []byte(prefix)) {
				t.Fatalf("%s and %s share a prefix", purpose, otherPurpose)
			}
		}
		seen[prefix] = purpose
	}
	if _, err := SigningMessage("login", nonce); err == nil {
		t.Fatal("an unknown purpose built a message")
	}
}

func TestDeviceIDCertMessageIsBoundToIDAndKeyAndNeverADevicePurpose(t *testing.T) {
	der := []byte{0x30, 0x59, 0x01}
	message, err := DeviceIDCertMessage("481930275", der)
	if err != nil {
		t.Fatal(err)
	}
	prefix := "skipperdesk/device-id-cert/v1|481930275"
	if !bytes.HasPrefix(message, []byte(prefix)) || len(message) != len(prefix)+32 {
		t.Fatalf("message %q does not carry the prefix, id and a 32-byte key digest", message)
	}
	other, _ := DeviceIDCertMessage("481930276", der)
	otherKey, _ := DeviceIDCertMessage("481930275", []byte{0x30, 0x59, 0x02})
	if bytes.Equal(message, other) || bytes.Equal(message, otherKey) {
		t.Fatal("a certificate message does not depend on both the id and the key")
	}
	for _, bad := range []string{"", "12345678", "1234567890", "12345678a"} {
		if _, err := DeviceIDCertMessage(bad, der); err == nil {
			t.Fatalf("built a certificate message for id %q", bad)
		}
	}
	if _, err := DeviceIDCertMessage("481930275", nil); err == nil {
		t.Fatal("built a certificate message without a key")
	}
	if _, err := SigningMessage(PurposeDeviceIDCert, make([]byte, NonceLen)); err == nil {
		t.Fatal("a device key can build a device-id-cert message")
	}
	certPrefix := []byte(signingPrefix(PurposeDeviceIDCert))
	for _, purpose := range SigningPurposes {
		device := []byte(signingPrefix(purpose))
		if bytes.HasPrefix(device, certPrefix) || bytes.HasPrefix(certPrefix, device) {
			t.Fatalf("%s overlaps the device-id-cert prefix", purpose)
		}
	}
}
