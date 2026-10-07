// The KMS-backed signer (PHASE5.md §1.2, API.md §6.1). The private half never leaves
// AWS: this process holds only the public key, fetched once at startup, and turns every
// certificate into a kms:Sign call that CloudTrail records.
package idcert

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"errors"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/kms"
	"github.com/aws/aws-sdk-go-v2/service/kms/types"
)

// The signing budget is set by the caller, not by KMS. rc-signal allows 3 s for a whole
// internal call (API.md §6.1), and a `hello` spends that budget on POST
// /internal/devices/{id}/cert. So every attempt's timeout plus every backoff has to come
// in under 3 s with room for the handler's own work: at 700 ms × 3 attempts plus
// 100 ms + 200 ms of backoff the worst case is 2.4 s, leaving 600 ms. Exceeding it would
// have rc-signal give up while rc-api is still waiting on KMS, which spends the caller's
// retry budget on a request that was never answered and makes a slow KMS
// indistinguishable from a failed one. internalCallBudget keeps that arithmetic honest in
// a test rather than in a comment alone.
//
// GetPublicKey is not in that budget: it runs once at startup, inside rc-api's own
// startupTimeout, so it can afford to wait.
const (
	kmsSignTimeout     = 700 * time.Millisecond
	kmsStartupTimeout  = 10 * time.Second
	kmsAttempts        = 3
	kmsBackoff         = 100 * time.Millisecond
	internalCallBudget = 3 * time.Second
	handlerHeadroomMin = 500 * time.Millisecond
)

type kmsAPI interface {
	Sign(context.Context, *kms.SignInput, ...func(*kms.Options)) (*kms.SignOutput, error)
	GetPublicKey(context.Context, *kms.GetPublicKeyInput, ...func(*kms.Options)) (*kms.GetPublicKeyOutput, error)
}

type kmsSigner struct {
	client kmsAPI
	keyID  string
}

func openKMS(ctx context.Context, keyID string) (*Authority, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("device-id certificate KMS key %q: %w", keyID, err)
	}
	// The retry below is the only one, so the SDK's own attempts are turned off rather
	// than multiplied by ours.
	client := kms.NewFromConfig(cfg, func(o *kms.Options) { o.RetryMaxAttempts = 1 })
	return newKMSAuthority(ctx, client, keyID)
}

func newKMSAuthority(ctx context.Context, client kmsAPI, keyID string) (*Authority, error) {
	s := &kmsSigner{client: client, keyID: keyID}
	pub, err := s.fetchPublicKey(ctx)
	if err != nil {
		return nil, err
	}
	return &Authority{pub: pub, signer: s}, nil
}

// fetchPublicKey runs once, at startup. Every error it returns is deliberately fatal to
// the process: a wrong key id, a wrong region and a missing kms:Sign grant all surface
// here, and they must stop the first deploy loudly instead of yielding a server that
// reports healthy and then 500s on every registration.
func (s *kmsSigner) fetchPublicKey(ctx context.Context) (*ecdsa.PublicKey, error) {
	callCtx, cancel := context.WithTimeout(ctx, kmsStartupTimeout)
	defer cancel()
	out, err := s.client.GetPublicKey(callCtx, &kms.GetPublicKeyInput{KeyId: aws.String(s.keyID)})
	if err != nil {
		return nil, fmt.Errorf("device-id certificate KMS key %q: %w", s.keyID, err)
	}
	if out.KeyUsage != types.KeyUsageTypeSignVerify {
		return nil, fmt.Errorf("device-id certificate KMS key %q: key usage is %q, want SIGN_VERIFY", s.keyID, out.KeyUsage)
	}
	pub, err := parseKMSPublicKey(out.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("device-id certificate KMS key %q: %w", s.keyID, err)
	}
	return pub, nil
}

// parseKMSPublicKey converts the DER SubjectPublicKeyInfo kms:GetPublicKey returns into
// the P-256 public key Verify already uses.
func parseKMSPublicKey(der []byte) (*ecdsa.PublicKey, error) {
	if len(der) == 0 {
		return nil, errors.New("KMS returned no public key")
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	pub, ok := parsed.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, errors.New("want a P-256 key")
	}
	return pub, nil
}

// signDigest asks KMS for the ASN.1 DER signature the wire format already carries:
// ECDSA_SHA_256 returns the same encoding ecdsa.SignASN1 produces locally, so there is
// nothing to convert. MessageType DIGEST is what makes KMS sign the 32 bytes as given
// instead of hashing them again.
func (s *kmsSigner) signDigest(ctx context.Context, digest []byte) ([]byte, error) {
	var last error
	for attempt := range kmsAttempts {
		if attempt > 0 {
			if err := pause(ctx, kmsBackoff<<(attempt-1)); err != nil {
				return nil, fmt.Errorf("device-id certificate signature: %w", err)
			}
		}
		sig, err := s.signOnce(ctx, digest)
		if err == nil {
			return sig, nil
		}
		last = err
		if !retryableKMSError(err) {
			break
		}
	}
	return nil, fmt.Errorf("device-id certificate signature: %w", last)
}

func (s *kmsSigner) signOnce(ctx context.Context, digest []byte) ([]byte, error) {
	callCtx, cancel := context.WithTimeout(ctx, kmsSignTimeout)
	defer cancel()
	out, err := s.client.Sign(callCtx, &kms.SignInput{
		KeyId:            aws.String(s.keyID),
		Message:          digest,
		MessageType:      types.MessageTypeDigest,
		SigningAlgorithm: types.SigningAlgorithmSpecEcdsaSha256,
	})
	if err != nil {
		return nil, err
	}
	if len(out.Signature) == 0 {
		return nil, errors.New("KMS returned an empty signature")
	}
	return out.Signature, nil
}

// retryableKMSCodes are the throttling and transient-capacity answers only. An access
// or key-state failure is not retried: it will not fix itself inside a request.
var retryableKMSCodes = map[string]bool{
	"ThrottlingException":        true,
	"LimitExceededException":     true,
	"KMSInternalException":       true,
	"DependencyTimeoutException": true,
}

func retryableKMSError(err error) bool {
	var coded interface{ ErrorCode() string }
	if errors.As(err, &coded) {
		return retryableKMSCodes[coded.ErrorCode()]
	}
	return false
}

func pause(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
