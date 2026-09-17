// Package idp turns a user-session bearer token into an account identity.
// The dev provider is for local work only; cognito is the deployed one.
package idp

import (
	"context"
	"errors"
	"strings"
)

var ErrUnauthenticated = errors.New("the user session token is not valid")

type Session struct {
	AccountID string
	Email     string
}

type Provider interface {
	Name() string
	UserSession(ctx context.Context, bearer string) (Session, error)
}

// Dev accepts `Bearer dev:<email>` and nothing else. rc-api refuses to start
// with this provider unless it is also serving plain HTTP locally.
type Dev struct{}

func (Dev) Name() string { return "dev" }

func (Dev) UserSession(_ context.Context, bearer string) (Session, error) {
	rest, ok := strings.CutPrefix(bearer, "dev:")
	if !ok {
		return Session{}, ErrUnauthenticated
	}
	email := strings.ToLower(strings.TrimSpace(rest))
	if email == "" || !strings.Contains(email, "@") || strings.ContainsAny(email, " \t\r\n") {
		return Session{}, ErrUnauthenticated
	}
	return Session{Email: email}, nil
}
