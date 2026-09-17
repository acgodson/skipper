// Command interopverify reads the JSON emitted by `rc-tests --emit-interop` on
// stdin and checks it with the SAME auth.VerifyDeviceSig the production
// signaling server uses to authenticate a device.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"

	"rc-signal/internal/auth"
	"rcprotocol"
)

type emitted struct {
	DeviceID string `json:"deviceId"`
	Pubkey   string `json:"pubkey"`
	Nonce    string `json:"nonce"`
	Sig      string `json:"sig"`
}

func main() {
	var in emitted
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fail("could not decode the emitted JSON: %v", err)
	}
	nonce, err := base64.StdEncoding.DecodeString(in.Nonce)
	if err != nil {
		fail("nonce is not base64: %v", err)
	}
	if len(nonce) != 32 {
		fail("nonce is %d bytes, want 32", len(nonce))
	}

	if _, err := auth.ParsePubkey(in.Pubkey); err != nil {
		fail("Go could not parse the public key Swift produced: %v\n"+
			"      Swift must send base64(DER SPKI), not the X9.63 raw point.", err)
	}
	fmt.Println("PASS  Go parsed the Swift public key as a P-256 DER SPKI key")

	if err := auth.VerifyDeviceSig(protocol.PurposeHello, in.Pubkey, in.Sig, nonce); err != nil {
		fail("Go rejected a valid Swift signature: %v\n"+
			"      Swift must send base64(ASN.1 DER ECDSA-SHA256) over \"skipperdesk/hello/v1|\" + the raw nonce bytes.", err)
	}
	fmt.Println("PASS  Go verified the Swift hello signature over the nonce")

	raw, err := base64.StdEncoding.DecodeString(in.Sig)
	if err != nil || len(raw) == 0 {
		fail("signature is not base64: %v", err)
	}
	tampered := make([]byte, len(raw))
	copy(tampered, raw)
	tampered[len(tampered)-1] ^= 0x01
	if err := auth.VerifyDeviceSig(protocol.PurposeHello, in.Pubkey, base64.StdEncoding.EncodeToString(tampered), nonce); err == nil {
		fail("a TAMPERED signature was accepted — the verifier is not actually checking")
	}
	fmt.Println("PASS  Go rejected the tampered signature")

	if err := auth.VerifyDeviceSig(protocol.PurposeRegister, in.Pubkey, in.Sig, nonce); err == nil {
		fail("the Swift hello signature was accepted as a register signature")
	}
	fmt.Println("PASS  Go rejected the hello signature for any other purpose")

	other := make([]byte, len(nonce))
	copy(other, nonce)
	other[0] ^= 0xff
	if err := auth.VerifyDeviceSig(protocol.PurposeHello, in.Pubkey, in.Sig, other); err == nil {
		fail("a signature over a DIFFERENT nonce was accepted")
	}
	fmt.Println("PASS  Go rejected the signature when checked against a different nonce")

	fmt.Printf("PASS  interop OK (deviceId %s, pubkey %d B64 chars, sig %d bytes DER)\n",
		in.DeviceID, len(in.Pubkey), len(raw))
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FAIL  "+format+"\n", args...)
	os.Exit(1)
}
