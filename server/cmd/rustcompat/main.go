// Command rustcompat checks material emitted by the Rust identity crate
// (win/crates/rc-identity) with the SAME functions the production signaling
// server uses: auth.VerifyDeviceSig for the registration signature and
// auth.VerifyCode for the Argon2id access-code verifier.
//
// The sibling `interopverify` does this for the Swift client; this one exists
// so the Windows host's crypto is held to the identical standard. Both assert
// the negative direction too — a checker hardwired to "yes" must fail here.
//
// Input (stdin): {"pubkey","nonce","sig","plaintextCode","code":{...}}
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"

	protocol "rcprotocol"

	"rc-signal/internal/auth"
)

type emitted struct {
	Pubkey        string                `json:"pubkey"`
	Nonce         string                `json:"nonce"`
	Sig           string                `json:"sig"`
	PlaintextCode string                `json:"plaintextCode"`
	Code          protocol.CodeVerifier `json:"code"`
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

	if err := in.Code.Validate(); err != nil {
		fail("the Rust verifier is structurally invalid: %v", err)
	}
	if !auth.VerifyCode(in.Code, in.PlaintextCode) {
		fail("auth.VerifyCode rejected the Rust Argon2id verifier for its own code")
	}
	fmt.Println("PASS  Go verified the Rust Argon2id verifier against the plaintext code")

	if auth.VerifyCode(in.Code, in.PlaintextCode+"X") {
		fail("auth.VerifyCode accepted the WRONG plaintext — it is not actually checking")
	}
	fmt.Println("PASS  Go rejected a wrong access code against the same verifier")

	fmt.Println("PASS  rustcompat OK")
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FAIL  "+format+"\n", args...)
	os.Exit(1)
}
