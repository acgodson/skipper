package wsserver

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"rc-signal/internal/hub"
	protocol "rcprotocol"
)

const token = "internal-token"

func post(t *testing.T, handler http.Handler, bearer string, body any) int {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, protocol.PathInternalSessionClose, bytes.NewReader(raw))
	if bearer != "" {
		req.Header.Set(protocol.HeaderAuthorization, protocol.BearerPrefix+bearer)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	return w.Code
}

func TestInternalSessionCloseNeedsTheInternalTokenAndADefinedReason(t *testing.T) {
	handler := InternalHandler(hub.New(hub.Options{}), token)
	valid := protocol.InternalSessionClose{DeviceID: "123456789", Reason: protocol.ByeHostEnded}

	if got := post(t, handler, "", valid); got != http.StatusUnauthorized {
		t.Fatalf("no bearer: %d, want 401", got)
	}
	if got := post(t, handler, "guessed", valid); got != http.StatusUnauthorized {
		t.Fatalf("wrong bearer: %d, want 401", got)
	}
	for name, body := range map[string]protocol.InternalSessionClose{
		"a malformed device id": {DeviceID: "12345", Reason: protocol.ByeHostEnded},
		"an undefined reason":   {DeviceID: "123456789", Reason: "signed_out"},
		"no reason":             {DeviceID: "123456789"},
	} {
		if got := post(t, handler, token, body); got != http.StatusBadRequest {
			t.Fatalf("%s: %d, want 400", name, got)
		}
	}
	if got := post(t, handler, token, valid); got != http.StatusNoContent {
		t.Fatalf("a device with no live session: %d, want 204", got)
	}
}
