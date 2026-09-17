package main

import (
	"encoding/json"
	"strings"

	p "rcprotocol"
)

// RelayVector pins the v5 strict relay decoder. Input is the raw payload text, so duplicate
// keys and number spellings survive; Output is the exact payload text the server relays instead.
type RelayVector struct {
	Note     string          `json:"note"`
	Accepted []RelayAccepted `json:"accepted"`
	Rejected []RelayRejected `json:"rejected"`
}

type RelayAccepted struct {
	Name   string `json:"name"`
	Type   string `json:"type"`
	Input  string `json:"input"`
	Output string `json:"output"`
	Note   string `json:"note,omitempty"`
}

type RelayRejected struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Input string `json:"input"`
	Note  string `json:"note,omitempty"`
}

const relayNote = "PROTOCOL.md v5: sdp, ice and pake payloads are decoded into their exact schema (exact-case keys, each once, no null, no unknown key, per-field limits) and re-encoded; every implementation accepts exactly the accepted inputs, producing output, and refuses every rejected input."

const (
	sid = "8c7f1a2b3c4d5e6f708192a3b4c5d6e7"
	esc = "\\u"
)

func relayVectors() RelayVector {
	var accepted []RelayAccepted
	accept := func(name, msgType, input, note string) {
		msg, err := p.DecodeRelay(msgType, []byte(input))
		if err != nil {
			panic(name + ": " + err.Error())
		}
		out, err := json.Marshal(msg)
		if err != nil {
			panic(err)
		}
		accepted = append(accepted, RelayAccepted{name, msgType, input, string(out), note})
	}
	var rejected []RelayRejected
	reject := func(name, msgType, input, note string) {
		if _, err := p.DecodeRelay(msgType, []byte(input)); err == nil {
			panic(name + " was accepted")
		}
		rejected = append(rejected, RelayRejected{name, msgType, input, note})
	}

	accept("ice_mline_zero_kept", p.TypeICE,
		`{"sessionId":"`+sid+`","candidate":"candidate:1 1 udp 2130706431 192.0.2.1 54321 typ host","sdpMid":"0","sdpMLineIndex":0}`,
		"an explicit sdpMLineIndex 0 is relayed as 0, not dropped")
	accept("ice_reordered_and_escaped_key", p.TypeICE,
		` { "sdpMid" : "0", "candidate":"candidate:842163049 1 udp 1677729535 203.0.113.9 61000 typ srflx raddr 0.0.0.0 rport 0 generation 0 ufrag Zx9+ network-cost 999", "session`+esc+`0049d":"`+sid+`" } `,
		"keys are matched after JSON unescaping; the output is re-encoded in schema order with no whitespace")
	accept("ice_end_of_candidates", p.TypeICE, `{"sessionId":"`+sid+`","candidate":""}`, "")
	accept("ice_mdns_tcp_ipv6", p.TypeICE,
		`{"sessionId":"`+sid+`","candidate":"candidate:3 1 TCP 1518280447 3f1c6e0a-9b2d-4c5e-8f7a-1d2e3f4a5b6c.local 9 typ host tcptype active raddr 2001:db8::1 rport 9","sdpMLineIndex":2}`,
		"an mDNS host name, an upper-case transport and an IPv6 raddr are all valid")
	accept("sdp_restart_false_dropped", p.TypeSDP,
		`{"sessionId":"`+sid+`","sdpType":"answer","sdp":"v=0\r\ns=-\r\n","restart":false,"fp":"sha-256 AA:01","pubkey":"cHVia2V5","sig":"c2ln","mac":"bWFj"}`,
		"restart:false is omitempty in the re-encoding")
	accept("pake_step_three", p.TypePake,
		"{\n  \"payload\": \"Y29uZmlybQ==\",\n  \"step\": 3,\n  \"sessionId\": \""+sid+"\"\n}", "")

	pake := func(fields string) string { return `{"sessionId":"` + sid + `",` + fields + `}` }
	for _, c := range [][2]string{
		{"pake_step_zero", "0"},
		{"pake_step_four", "4"},
		{"pake_step_negative", "-1"},
		{"pake_step_2_pow_32", "4294967296"},
		{"pake_step_2_pow_31", "2147483648"},
		{"pake_step_fraction", "1.5"},
		{"pake_step_float_integer", "1.0"},
		{"pake_step_exponent", "1e0"},
		{"pake_step_string", `"1"`},
		{"pake_step_null", "null"},
		{"pake_step_bool", "true"},
	} {
		reject(c[0], p.TypePake, pake(`"step":`+c[1]+`,"payload":"cA=="`), "step must be a JSON integer 1..3")
	}
	reject("pake_step_missing", p.TypePake, pake(`"payload":"cA=="`), "")
	reject("pake_payload_empty", p.TypePake, pake(`"step":1,"payload":""`), "")
	reject("pake_payload_unpadded", p.TypePake, pake(`"step":1,"payload":"cA"`), "")
	reject("pake_payload_url_alphabet", p.TypePake, pake(`"step":1,"payload":"c-_="`), "")
	reject("pake_payload_newline", p.TypePake, pake(`"step":1,"payload":"cA==\ncA=="`), "")
	reject("pake_payload_too_long", p.TypePake, pake(`"step":1,"payload":"`+strings.Repeat("A", p.MaxPakePayloadBytes+4)+`"`), "")
	reject("pake_unknown_key", p.TypePake, pake(`"step":1,"payload":"cA==","extra":1`), "")
	reject("pake_case_variant_key", p.TypePake, pake(`"Step":1,"payload":"cA=="`), "keys match exactly, never case-insensitively")
	reject("pake_duplicate_key", p.TypePake, pake(`"step":1,"step":2,"payload":"cA=="`), "")

	ice := func(fields string) string { return `{"sessionId":"` + sid + `",` + fields + `}` }
	reject("ice_carrying_sdp", p.TypeICE,
		ice(`"candidate":"","sdp":"v=0 full offer","sdpType":"offer"`), "an SDP smuggled in an ice envelope is an unknown key")
	reject("ice_case_variant_session_id", p.TypeICE,
		`{"sessionId":"ffffffffffffffffffffffffffffffff","SESSIONID":"`+sid+`","candidate":""}`,
		"a case-variant duplicate of sessionId is an unknown key")
	reject("ice_duplicate_session_id", p.TypeICE,
		`{"sessionId":"ffffffffffffffffffffffffffffffff","sessionId":"`+sid+`","candidate":""}`, "")
	reject("ice_candidate_missing", p.TypeICE, `{"sessionId":"`+sid+`"}`, "")
	reject("ice_candidate_not_a_candidate", p.TypeICE, ice(`"candidate":"v=0 o=- 0 0 IN IP4 127.0.0.1"`), "")
	reject("ice_candidate_without_prefix", p.TypeICE, ice(`"candidate":"1 1 udp 2130706431 192.0.2.1 54321 typ host"`), "")
	reject("ice_candidate_double_space", p.TypeICE, ice(`"candidate":"candidate:1 1 udp 2130706431  192.0.2.1 54321 typ host"`), "")
	reject("ice_candidate_bad_type", p.TypeICE, ice(`"candidate":"candidate:1 1 udp 2130706431 192.0.2.1 54321 typ bogus"`), "")
	reject("ice_candidate_hostname", p.TypeICE, ice(`"candidate":"candidate:1 1 udp 2130706431 attacker.example 54321 typ host"`), "only IP literals and <uuid>.local")
	reject("ice_candidate_dangling_extension", p.TypeICE, ice(`"candidate":"candidate:1 1 udp 2130706431 192.0.2.1 54321 typ host generation"`), "")
	reject("ice_candidate_too_long", p.TypeICE,
		ice(`"candidate":"candidate:1 1 udp 2130706431 192.0.2.1 54321 typ host`+strings.Repeat(" ufrag "+strings.Repeat("a", 60), 16)+`"`), "over 1024 bytes")
	reject("ice_mline_negative", p.TypeICE, ice(`"candidate":"","sdpMLineIndex":-1`), "")
	reject("ice_mline_2_pow_31", p.TypeICE, ice(`"candidate":"","sdpMLineIndex":2147483648`), "")
	reject("ice_mid_with_space", p.TypeICE, ice(`"candidate":"","sdpMid":"0 1"`), "")

	sdp := func(fields string) string { return `{"sessionId":"` + sid + `",` + fields + `}` }
	reject("sdp_without_version_line", p.TypeSDP, sdp(`"sdpType":"offer","sdp":"o=- 0 0 IN IP4 0.0.0.0"`), "")
	reject("sdp_with_nul", p.TypeSDP, sdp(`"sdpType":"offer","sdp":"v=0`+esc+`0000"`), "")
	reject("sdp_too_long", p.TypeSDP, sdp(`"sdpType":"offer","sdp":"v=0`+strings.Repeat("a", p.MaxSDPBytes-2)+`"`), "over 64 KiB")
	reject("sdp_type_upper_case", p.TypeSDP, sdp(`"sdpType":"OFFER","sdp":"v=0"`), "")
	reject("sdp_case_variant_body", p.TypeSDP, sdp(`"sdpType":"offer","sdp":"v=0","SDP":"v=0 other"`), "")
	reject("sdp_null_fp", p.TypeSDP, sdp(`"sdpType":"offer","sdp":"v=0","fp":null`), "")
	reject("sdp_upper_case_session_id", p.TypeSDP, `{"sessionId":"8C7F1A2B3C4D5E6F708192A3B4C5D6E7","sdpType":"offer","sdp":"v=0"}`, "")
	reject("sdp_trailing_object", p.TypeSDP, sdp(`"sdpType":"offer","sdp":"v=0"`)+`{}`, "")
	reject("sdp_array", p.TypeSDP, `[]`, "")

	return RelayVector{Note: relayNote, Accepted: accepted, Rejected: rejected}
}
