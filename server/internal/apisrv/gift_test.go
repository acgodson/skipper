// Gift acceptance: a gift is credit moved, never credit created (review5 H3).
package apisrv

import (
	"net/http"
	"sync"
	"testing"

	protocol "rcprotocol"
)

// netSystemCredit is every cent the ledger holds across every account, plus every
// cent held in a pending gift. Gifts move credit between accounts, so this total can
// only change when credit enters or leaves the system -- a top-up or a charge --
// never because of a gift.
func (h *harness) netSystemCredit() int64 {
	h.t.Helper()
	return h.rawInt(`SELECT
 (SELECT COALESCE(SUM(amount_cents),0) FROM ledger)
 + (SELECT COALESCE(SUM(amount_cents),0) FROM gifts WHERE status=?)`, protocol.GiftPending)
}

// The hole: createGift wrote the pending row and then debited. When two concurrent
// gifts both passed the balance read and the ledger refused the second debit, a
// pending gift survived with no debit behind it -- credit from nothing, realised
// either by the recipient accepting it or by nobody doing anything and the expiry
// refunding a sender who never paid. The 5xx released the idempotency key, so it was
// freely retryable.
func TestARefusedGiftDebitLeavesNothingBehind(t *testing.T) {
	h := newHarness(t)
	const sender = "sender@example.com"
	h.link(sender, newDevice(t), "SERIAL-SENDER")
	spendDown(h, sender)
	h.topUp(sender, protocol.MinGiftAmountCents)

	before := h.netSystemCredit()
	if before != protocol.MinGiftAmountCents {
		t.Fatalf("the system holds %d cents before any gift, want %d",
			before, protocol.MinGiftAmountCents)
	}

	// Enough concurrent gifts that only one can possibly be paid for.
	const attempts = 12
	var wg sync.WaitGroup
	created := make([]int, attempts)
	for i := range attempts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := h.call("POST", protocol.PathCreditsGifts, "dev:"+sender, idem(),
				protocol.CreateGiftRequest{
					ToEmail:     "recipient@example.com",
					AmountCents: protocol.MinGiftAmountCents,
					Message:     "concurrent",
				})
			if r.status == http.StatusCreated {
				created[i] = 1
			}
		}()
	}
	wg.Wait()

	accepted := 0
	for _, n := range created {
		accepted += n
	}
	if accepted != 1 {
		t.Fatalf("%d of %d concurrent gifts were created against a balance that covers one",
			accepted, attempts)
	}

	// Every pending gift must have its debit, and no debit may exist without a gift.
	unpaid := h.rawInt(`SELECT COUNT(1) FROM gifts g WHERE g.status=?
 AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.gift_id=g.gift_id AND l.type=?)`,
		protocol.GiftPending, protocol.LedgerGiftSent)
	if unpaid != 0 {
		t.Fatalf("%d pending gifts have no debit behind them: that is credit from nothing", unpaid)
	}
	if got := h.balance(sender); got != 0 {
		t.Fatalf("the sender's balance is %d after giving away all of it, want 0", got)
	}
	if after := h.netSystemCredit(); after != before {
		t.Fatalf("the system held %d cents before the gifts and %d after; a gift moves "+
			"credit and must never create it", before, after)
	}
}

// The whole round trip, so the invariant is checked against a gift that completes
// rather than only against one that is refused.
func TestAGiftMovesCreditAndNeverCreatesIt(t *testing.T) {
	h := newHarness(t)
	const sender, recipient = "gives@example.com", "gets@example.com"
	h.link(sender, newDevice(t), "SERIAL-GIVES")
	h.topUp(sender, 1000)
	before := h.netSystemCredit()

	r := h.call("POST", protocol.PathCreditsGifts, "dev:"+sender, idem(),
		protocol.CreateGiftRequest{ToEmail: recipient, AmountCents: 600, Message: "here"})
	if r.status != http.StatusCreated {
		t.Fatalf("create: %d %s", r.status, r.body)
	}
	var gift protocol.Gift
	r.decode(t, &gift)
	if after := h.netSystemCredit(); after != before {
		t.Fatalf("holding a gift moved the system total from %d to %d", before, after)
	}

	r = h.call("POST", protocol.PathCreditsGifts+"/"+gift.GiftID+"/accept", "dev:"+recipient, idem(), struct{}{})
	if r.status != http.StatusOK {
		t.Fatalf("accept: %d %s", r.status, r.body)
	}
	if got := h.balance(recipient); got != 600 {
		t.Fatalf("the recipient holds %d cents, want 600", got)
	}
	if after := h.netSystemCredit(); after != before {
		t.Fatalf("accepting a gift moved the system total from %d to %d", before, after)
	}
}

// A gift whose hold runs out is refunded only because a debit paid for it. Were an
// unpaid row ever to exist, the expiry must not turn it into credit.
func TestAnUnpaidPendingGiftIsNeverRefunded(t *testing.T) {
	h := newHarness(t)
	const sender = "unpaid@example.com"
	h.link(sender, newDevice(t), "SERIAL-UNPAID")
	account, err := h.db.AccountByEmail(sender)
	if err != nil {
		t.Fatal(err)
	}
	before := h.balance(sender)

	// The shape H3 could produce: a pending gift with no debit behind it. The code
	// can no longer write one, so the test writes it.
	now := h.clock.Now().UnixMilli()
	h.rawExec(`INSERT INTO gifts (gift_id, from_account_id, from_email, to_email,
 amount_cents, message, status, created_at, expires_at, accepted_at)
 VALUES (?,?,?,?,?,?,?,?,?,NULL)`, "gift_orphan", account.AccountID, sender,
		"somebody@example.com", 5000, "", protocol.GiftPending, now, now-1)

	h.call("GET", protocol.PathCredits, "dev:"+sender, "", nil)

	if got := h.balance(sender); got != before {
		t.Fatalf("expiring an unpaid gift credited the sender %d cents it never paid",
			got-before)
	}
	if got := h.rawInt(`SELECT COUNT(1) FROM gifts WHERE gift_id=? AND status=?`,
		"gift_orphan", protocol.GiftExpired); got != 1 {
		t.Fatalf("the unpaid gift was left pending; it must still be closed out")
	}
}
