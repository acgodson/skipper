// The relay fields on bye are host-reported measurement, and the trust boundary is
// that only the host's claim is read (PROTOCOL.md §2.14.1, API.md §5.4).
package hub

import (
	"testing"

	protocol "rcprotocol"
)

// meterSession takes an open session to the point where accounting knows about it:
// metering starts on the host's first relayed sdp (PROTOCOL.md §3.4), and only a
// metered session is ever reported.
func (hn *harness) meterSession(t *testing.T) (host, ctrl *peer, sessionID string) {
	t.Helper()
	host, ctrl, sessionID, _, _ = hn.openSession(t)
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: sessionID, SDPType: "offer", SDP: "v=0\r\n"})
	return host, ctrl, sessionID
}

func relayed(used bool, bytes int64) protocol.Bye {
	return protocol.Bye{RelayUsed: &used, BytesRelayed: &bytes}
}

// The host's own claim reaches the stop report. Before this there was no wire field at
// all, so /v1/sessions answered relayUsed:false for every session ever held and
// PHASE5.md §3's relay fraction rested on a number nothing produced.
func TestTheHostsRelayClaimReachesTheStopReport(t *testing.T) {
	hn := newHarness(t)
	host, _, sid := hn.meterSession(t)

	bye := relayed(true, 377_487_360)
	bye.SessionID, bye.Reason = sid, protocol.ByeUserEnded
	host.send(protocol.TypeBye, bye)

	_, stops := hn.ent.awaitReports(t, 1, 1)
	if !stops[0].RelayUsed {
		t.Fatal("the host said its media went through a relay and the stop report says it did not")
	}
	if stops[0].BytesRelayed == nil || *stops[0].BytesRelayed != 377_487_360 {
		t.Fatalf("stop report bytesRelayed = %v, want the host's 377487360", stops[0].BytesRelayed)
	}
}

// A controller cannot write a relay figure into a host's record. The host is the party
// whose account would pay, so its claim is the only one accepted; a controller's is
// discarded rather than merged, refused or logged against the host.
func TestAControllersRelayClaimIsDiscarded(t *testing.T) {
	hn := newHarness(t)
	_, ctrl, sid := hn.meterSession(t)

	bye := relayed(true, 1<<40)
	bye.SessionID, bye.Reason = sid, protocol.ByeUserEnded
	ctrl.send(protocol.TypeBye, bye)

	_, stops := hn.ent.awaitReports(t, 1, 1)
	if stops[0].RelayUsed || stops[0].BytesRelayed != nil {
		t.Fatalf("a controller wrote %v / %v into the host's session record; "+
			"only the host's own claim may be read (PROTOCOL.md §2.14.1)",
			stops[0].RelayUsed, stops[0].BytesRelayed)
	}
}

// A bye that claims nothing reports nothing, which is what keeps the field additive:
// every peer that never learned about it behaves exactly as it did before.
func TestAByeWithoutRelayFieldsReportsNothing(t *testing.T) {
	hn := newHarness(t)
	host, _, sid := hn.meterSession(t)

	host.send(protocol.TypeBye, protocol.Bye{SessionID: sid, Reason: protocol.ByeUserEnded})

	_, stops := hn.ent.awaitReports(t, 1, 1)
	if stops[0].RelayUsed || stops[0].BytesRelayed != nil {
		t.Fatalf("a bye with no relay fields reported %v / %v",
			stops[0].RelayUsed, stops[0].BytesRelayed)
	}
}

// A host that claims bytes without claiming a relay, or a negative count, has said
// nothing coherent. Normalising at the edge keeps the column free of values the cost
// model would have to special-case later.
func TestIncoherentRelayClaimsAreNormalisedAway(t *testing.T) {
	cases := map[string]protocol.Bye{
		"bytes without a relay": relayed(false, 1<<20),
		"a negative count":      relayed(true, -1),
	}
	for name, bye := range cases {
		t.Run(name, func(t *testing.T) {
			used, bytes := bye.RelayReport()
			if name == "a negative count" {
				if !used || bytes != nil {
					t.Fatalf("relay use with a negative count = %v / %v, want true with no count",
						used, bytes)
				}
				return
			}
			if used || bytes != nil {
				t.Fatalf("%s = %v / %v, want nothing", name, used, bytes)
			}
		})
	}
}
