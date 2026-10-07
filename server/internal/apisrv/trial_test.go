// Trial-grant acceptance: what a client-chosen hardwareId is worth, and what it is
// not (review5 H4). The grant cannot be keyed on anything the client asserts, so
// these tests state the bound rather than claiming prevention.
package apisrv

import (
	"fmt"
	"net/http"
	"testing"

	"rc-signal/internal/apidb"
	"rc-signal/internal/clientip"
	"rc-signal/internal/policy"
	protocol "rcprotocol"
)

func (h *harness) grants(email string) int {
	h.t.Helper()
	return len(h.entriesOfType(email, protocol.LedgerTrialGrant))
}

// The attack: a fresh P-256 keypair plus any hardwareId the attacker likes earned a
// fresh 50-cent grant, as often as they cared to repeat it, all on one account. The
// review minted five. Both inputs are attacker-chosen, so the cap is on the account.
func TestFiveFreshHardwareIdsOnOneAccountEarnOneGrant(t *testing.T) {
	h := newHarness(t)
	const email = "farmer@example.com"

	for i := range 5 {
		h.link(email, newDevice(t), fmt.Sprintf("SERIAL-INVENTED-%d", i))
	}

	if got := h.grants(email); got != policy.MaxTrialGrantsPerMailbox {
		t.Fatalf("five invented hardware ids on one account earned %d grants, want %d",
			got, policy.MaxTrialGrantsPerMailbox)
	}
	if got := h.balance(email); got != policy.TrialGrantCents {
		t.Fatalf("the account holds %d cents of starting credit, want %d",
			got, policy.TrialGrantCents)
	}
}

// Plus-addressing yields unlimited distinct usernames from one mailbox, and
// NormaliseEmail is lowercase and trim only. The grant folds the tag away, so one
// mailbox is worth one grant; nothing else does, so a folded address still gets its
// own account and keeps every cent it pays for.
func TestOneMailboxIsWorthOneGrantHoweverItIsTagged(t *testing.T) {
	h := newHarness(t)
	addresses := []string{"tagger@example.com", "tagger+1@example.com", "TAGGER+two@example.com"}

	for i, email := range addresses {
		h.link(email, newDevice(t), fmt.Sprintf("SERIAL-TAG-%d", i))
	}

	total := 0
	for _, email := range addresses {
		total += h.grants(email)
	}
	if total != policy.MaxTrialGrantsPerMailbox {
		t.Fatalf("three tags on one mailbox earned %d grants, want %d",
			total, policy.MaxTrialGrantsPerMailbox)
	}
	// Folding bounds a free grant and nothing else: these are still separate
	// accounts, and a top-up to one is not visible to another.
	first, err := h.db.AccountByEmail(apidb.NormaliseEmail(addresses[0]))
	if err != nil {
		t.Fatal(err)
	}
	second, err := h.db.AccountByEmail(apidb.NormaliseEmail(addresses[1]))
	if err != nil {
		t.Fatal(err)
	}
	if first.AccountID == second.AccountID {
		t.Fatal("folding the tag merged two accounts; it must only withhold a grant")
	}
	h.topUp(addresses[1], 500)
	if got := h.balance(addresses[0]); got != policy.TrialGrantCents {
		t.Fatalf("a top-up to the tagged address moved the untagged balance to %d", got)
	}
}

// One address cannot mint grants without limit even with a fresh mailbox each time:
// the per-address budget is charged only when a grant is otherwise due, and a refusal
// withholds the grant, never the link.
func TestOneAddressCanOnlyTakeItsBudgetOfGrantsADay(t *testing.T) {
	h := newHarnessWith(t, clientip.Resolver{})
	granted, linked := 0, 0

	for i := range int(limitTrialGrantIP.Limit) + 3 {
		email := fmt.Sprintf("fresh%d@example.com", i)
		grant := h.link(email, newDevice(t), fmt.Sprintf("SERIAL-FRESH-%d", i))
		linked++
		if r := h.call("GET", protocol.PathEntitlement, grant.DeviceToken, "", nil); r.status != http.StatusOK {
			t.Fatalf("a device whose grant was withheld could not read entitlement: %d %s", r.status, r.body)
		}
		granted += h.grants(email)
	}

	if want := int(limitTrialGrantIP.Limit); granted != want {
		t.Fatalf("%d fresh accounts from one address earned %d grants, want the budget of %d",
			linked, granted, want)
	}
	if linked != int(limitTrialGrantIP.Limit)+3 {
		t.Fatalf("only %d of %d links succeeded; a withheld grant must not fail the link",
			linked, int(limitTrialGrantIP.Limit)+3)
	}
}
