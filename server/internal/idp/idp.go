// Package idp turns a user-session bearer token into an account identity.
// The dev provider is for local work only; cognito is the deployed one.
package idp

import (
	"context"
	"errors"
	"strings"
)

var ErrUnauthenticated = errors.New("the user session token is not valid")

// Session is the identity the provider vouched for. Subject is the provider's
// immutable identifier for the person and is what an account is keyed on; Email is a
// display attribute that can change, and is only trusted when the provider says it
// verified it (review5 H2).
type Session struct {
	Subject       string
	Email         string
	EmailVerified bool
}

type Provider interface {
	Name() string
	UserSession(ctx context.Context, bearer string) (Session, error)
}

// Dev accepts `Bearer dev:<email>` and nothing else. rc-api refuses to start
// with this provider unless it is also serving plain HTTP locally.
type Dev struct{}

func (Dev) Name() string { return "dev" }

// DevSubjectPrefix makes the dev provider's subject deterministic for an address,
// so a dev session resolves to the same account every time the way a real one does.
const DevSubjectPrefix = "dev|"

func (Dev) UserSession(_ context.Context, bearer string) (Session, error) {
	rest, ok := strings.CutPrefix(bearer, "dev:")
	if !ok {
		return Session{}, ErrUnauthenticated
	}
	email := strings.ToLower(strings.TrimSpace(rest))
	if email == "" || !strings.Contains(email, "@") || strings.ContainsAny(email, " \t\r\n") {
		return Session{}, ErrUnauthenticated
	}
	return Session{Subject: DevSubjectPrefix + email, Email: email, EmailVerified: true}, nil
}
