// Command rustcompat checks material emitted by the Rust identity crate
// with the SAME function the production signaling server uses to authenticate a device.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"

	"rc-signal/internal/auth"
)

type emitted struct {
	Pubkey string `json:"pubkey"`
	Nonce  string `json:"nonce"`
	Sig    string `json:"sig"`
}

func main() {
	var in emitted
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fail("could not decode the emitted JSON: %v", err)
	}
	nonce, err := base64.StdEncoding.DecodeString(in.Nonce)
	if err != nil || len(nonce) != 32 {
		fail("nonce must be base64 of 32 bytes (err=%v len=%d)", err, len(nonce))
	}

	if _, err := auth.ParsePubkey(in.Pubkey); err != nil {
		fail("Go could not parse the Rust public key as P-256 DER SPKI: %v", err)
	}
	fmt.Println("PASS  Go parsed the Rust public key as a P-256 DER SPKI key")

	if err := auth.VerifyDeviceSig(in.Pubkey, in.Sig, nonce); err != nil {
		fail("Go rejected a valid Rust signature: %v", err)
	}
	fmt.Println("PASS  Go verified the Rust signature over the nonce")

	raw, _ := base64.StdEncoding.DecodeString(in.Sig)
	tampered := append([]byte(nil), raw...)
	tampered[len(tampered)-1] ^= 0x01
	if auth.VerifyDeviceSig(in.Pubkey, base64.StdEncoding.EncodeToString(tampered), nonce) == nil {
		fail("a TAMPERED signature was accepted — the verifier is not actually checking")
	}
	fmt.Println("PASS  Go rejected the tampered signature")

	fmt.Println("PASS  rustcompat OK")
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FAIL  "+format+"\n", args...)
	os.Exit(1)
}
