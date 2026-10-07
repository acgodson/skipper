// Identity acceptance: an account is the identity provider's subject, the address is
// an attribute of it, and an unverified address is not an identity at all
// (review5 H2). These run the real handlers, because the defect was in which column
// a lookup used and no unit test of the verifier could see it.
package apisrv

import (
	"context"
	"net/http"
	"testing"

	"rc-signal/internal/idp"
	protocol "rcprotocol"
)

// federated stands in for the day Apple or Google lands: a second, separate subject
// in the same pool that carries whatever email its provider asserts, with no linking
// Lambda to merge it into the subject that owns that address already.
type federated struct {
	subject  string
	email    string
	verified bool
}

func (federated) Name() string { return "cognito" }

func (f federated) UserSession(context.Context, string) (idp.Session, error) {
	return idp.Session{Subject: f.subject, Email: f.email, EmailVerified: f.verified}, nil
}

// The attack: a second subject presenting the victim's email claim landed on the
// victim's account, read the balance and could have drained it by gift. Accounts
// were resolved by email and the subject was ignored outright whenever a row existed.
func TestASecondSubjectCarryingAnAddressGetsItsOwnAccount(t *testing.T) {
	h := newHarness(t)
	const victimEmail = "victim@example.com"
	h.link(victimEmail, newDevice(t), "SERIAL-VICTIM")
	h.topUp(victimEmail, 500)

	victim, err := h.db.AccountByEmail(victimEmail)
	if err != nil {
		t.Fatal(err)
	}
	funded := int64(500 + 50)
	if got := h.balance(victimEmail); got != funded {
		t.Fatalf("the victim's balance is %d, want %d", got, funded)
	}

	attacker := h.withIdP(federated{subject: "apple|attacker", email: victimEmail, verified: true})
	var seen protocol.Balance
	r := h.callAt(attacker, "GET", protocol.PathCredits, "any-token", "", nil, nil)
	if r.status != http.StatusOK {
		t.Fatalf("the second subject could not read its own credits: %d %s", r.status, r.body)
	}
	r.decode(t, &seen)
	if seen.BalanceCents != 0 {
		t.Fatalf("a second subject carrying %s sees a balance of %d; it must see its own, empty account",
			victimEmail, seen.BalanceCents)
	}

	landed, err := h.db.AccountBySubject("apple|attacker")
	if err != nil {
		t.Fatal(err)
	}
	if landed.AccountID == victim.AccountID {
		t.Fatalf("the second subject landed on the victim's account %s", victim.AccountID)
	}
	if got := h.balance(victimEmail); got != funded {
		t.Fatalf("the victim's balance moved to %d", got)
	}
}

// An unverified address is one its holder only asserted, so it cannot carry an
// account or receive what is addressed to it.
func TestAnUnverifiedAddressIsRefusedASession(t *testing.T) {
	h := newHarness(t)
	unverified := h.withIdP(federated{subject: "apple|unverified", email: "nobody@example.com"})
	r := h.callAt(unverified, "GET", protocol.PathCredits, "any-token", "", nil, nil)
	if r.status != http.StatusUnauthorized {
		t.Fatalf("an unverified address got %d %s, want 401", r.status, r.body)
	}
	if _, err := h.db.AccountBySubject("apple|unverified"); err == nil {
		t.Fatal("an unverified address created an account")
	}
}

// The migration for the accounts that already exist. The live account predates the
// subject column, so it carries an empty one; the first subject bearing its address
// adopts it, which is sound only because email is the username on this pool and no
// federated provider exists. Afterwards the address grants nothing: the subject does.
func TestAnAccountWithoutASubjectIsAdoptedOnceAndThenKeyedOnIt(t *testing.T) {
	h := newHarness(t)
	const email = "owner@example.com"
	h.link(email, newDevice(t), "SERIAL-ADOPT")
	h.topUp(email, 500)
	owner, err := h.db.AccountByEmail(email)
	if err != nil {
		t.Fatal(err)
	}
	funded := int64(500 + 50)

	// Rewind to the shape the live row has: an account with no subject.
	h.rawExec(`UPDATE accounts SET subject='' WHERE account_id=?`, owner.AccountID)

	cognito := h.withIdP(federated{subject: "cognito|owner", email: email, verified: true})
	var seen protocol.Balance
	r := h.callAt(cognito, "GET", protocol.PathCredits, "any-token", "", nil, nil)
	if r.status != http.StatusOK {
		t.Fatalf("the owner could not sign in: %d %s", r.status, r.body)
	}
	r.decode(t, &seen)
	if seen.BalanceCents != funded {
		t.Fatalf("after adoption the owner sees %d cents, want their own %d", seen.BalanceCents, funded)
	}

	adopted, err := h.db.AccountByID(owner.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if adopted.Subject != "cognito|owner" || adopted.Email != email {
		t.Fatalf("after adoption the row is %+v", adopted)
	}

	// Adoption happens once. A different subject bearing the same address now gets
	// its own account rather than the owner's.
	second := h.withIdP(federated{subject: "apple|someone-else", email: email, verified: true})
	r = h.callAt(second, "GET", protocol.PathCredits, "any-token", "", nil, nil)
	if r.status != http.StatusOK {
		t.Fatalf("the second subject: %d %s", r.status, r.body)
	}
	r.decode(t, &seen)
	if seen.BalanceCents != 0 {
		t.Fatalf("a second subject adopted the owner's account too: it sees %d", seen.BalanceCents)
	}

	// Signing in again changes nothing, which is what makes the migration a no-op
	// on every request after the first.
	for range 3 {
		if r := h.callAt(cognito, "GET", protocol.PathCredits, "any-token", "", nil, nil); r.status != http.StatusOK {
			t.Fatalf("a repeat sign-in: %d %s", r.status, r.body)
		}
	}
	again, err := h.db.AccountBySubject("cognito|owner")
	if err != nil || again.AccountID != owner.AccountID {
		t.Fatalf("the owner's account moved to %+v (err=%v)", again, err)
	}
}

// The address is an attribute now, so changing it keeps the account and its money.
func TestChangingAddressKeepsTheAccount(t *testing.T) {
	h := newHarness(t)
	const was, now = "was@example.com", "now@example.com"
	h.link(was, newDevice(t), "SERIAL-RENAME")
	h.topUp(was, 500)
	before, err := h.db.AccountByEmail(was)
	if err != nil {
		t.Fatal(err)
	}
	h.rawExec(`UPDATE accounts SET subject=? WHERE account_id=?`, "cognito|stable", before.AccountID)

	renamed := h.withIdP(federated{subject: "cognito|stable", email: now, verified: true})
	var seen protocol.Balance
	r := h.callAt(renamed, "GET", protocol.PathCredits, "any-token", "", nil, nil)
	if r.status != http.StatusOK {
		t.Fatalf("after an address change: %d %s", r.status, r.body)
	}
	r.decode(t, &seen)
	if seen.BalanceCents != 500+50 {
		t.Fatalf("an address change cost the account its balance: %d", seen.BalanceCents)
	}
	after, err := h.db.AccountByID(before.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if after.Email != now {
		t.Fatalf("the account's address is %q, want the new one", after.Email)
	}
}
