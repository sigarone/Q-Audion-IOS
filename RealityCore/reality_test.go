package reality

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestValidateRequiresCoreFields(t *testing.T) {
	cases := []struct {
		name string
		p    startParams
	}{
		{"missing serverAddress", startParams{UUID: "u", PublicKey: "k", ServerName: "s"}},
		{"missing uuid", startParams{ServerAddress: "a", PublicKey: "k", ServerName: "s"}},
		{"missing publicKey", startParams{ServerAddress: "a", UUID: "u", ServerName: "s"}},
		{"missing serverName", startParams{ServerAddress: "a", UUID: "u", PublicKey: "k"}},
	}
	for _, c := range cases {
		if err := c.p.validate(); err == nil {
			t.Errorf("%s: expected validation error, got nil", c.name)
		}
	}
}

func TestApplyDefaults(t *testing.T) {
	p := startParams{ServerAddress: "a", UUID: "u", PublicKey: "k", ServerName: "s"}
	p.applyDefaults()
	if p.ServerPort != 443 {
		t.Errorf("ServerPort default = %d, want 443", p.ServerPort)
	}
	if p.Flow != "xtls-rprx-vision" {
		t.Errorf("Flow default = %q, want xtls-rprx-vision", p.Flow)
	}
	if p.Fingerprint != "chrome" {
		t.Errorf("Fingerprint default = %q, want chrome", p.Fingerprint)
	}
}

// TestBuildClientConfigShape locks the JSON shape to the vnext-style VLESS
// outbound schema verified against XTLS/Xray-examples (NOT the older
// flattened address/port/id form some stale blog posts show).
func TestBuildClientConfigShape(t *testing.T) {
	p := startParams{
		ServerAddress: "front.example.invalid",
		ServerPort:    443,
		UUID:          "11111111-2222-3333-4444-555555555555",
		Flow:          "xtls-rprx-vision",
		PublicKey:     "pubkey-b64",
		ShortID:       "0123456789abcdef",
		ServerName:    "www.example-disguise.invalid",
		Fingerprint:   "chrome",
	}
	cfg := buildClientConfig(p, 10809)

	out, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var round map[string]any
	if err := json.Unmarshal(out, &round); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	inbounds, _ := round["inbounds"].([]any)
	if len(inbounds) != 1 {
		t.Fatalf("expected 1 inbound, got %d", len(inbounds))
	}
	in0 := inbounds[0].(map[string]any)
	if in0["protocol"] != "socks" || in0["port"].(float64) != 10809 {
		t.Errorf("inbound shape wrong: %+v", in0)
	}

	outbounds, _ := round["outbounds"].([]any)
	if len(outbounds) != 1 {
		t.Fatalf("expected 1 outbound, got %d", len(outbounds))
	}
	out0 := outbounds[0].(map[string]any)
	settings := out0["settings"].(map[string]any)
	if _, ok := settings["vnext"]; !ok {
		t.Fatalf("outbound settings missing vnext[] (wrong VLESS schema): %+v", settings)
	}
	vnext := settings["vnext"].([]any)[0].(map[string]any)
	if vnext["address"] != p.ServerAddress {
		t.Errorf("vnext.address = %v, want %v", vnext["address"], p.ServerAddress)
	}

	streamSettings := out0["streamSettings"].(map[string]any)
	if streamSettings["security"] != "reality" {
		t.Errorf("streamSettings.security = %v, want reality", streamSettings["security"])
	}
	reality := streamSettings["realitySettings"].(map[string]any)
	if reality["publicKey"] != p.PublicKey || reality["serverName"] != p.ServerName {
		t.Errorf("realitySettings shape wrong: %+v", reality)
	}
	if !strings.Contains(string(out), `"shortId":"0123456789abcdef"`) {
		t.Errorf("shortId missing from marshaled config: %s", out)
	}
}

func TestStartRejectsInvalidParamsJSON(t *testing.T) {
	if port := Start("not json"); port != 0 {
		t.Errorf("expected 0 for invalid JSON, got %d", port)
	}
	if LastError() == "" {
		t.Error("expected LastError() to be set after a rejected Start()")
	}
}

func TestStartRejectsMissingRequiredFields(t *testing.T) {
	if port := Start(`{"serverAddress":"a"}`); port != 0 {
		t.Errorf("expected 0 for missing required fields, got %d", port)
	}
	if LastError() == "" {
		t.Error("expected LastError() to be set after a rejected Start()")
	}
}
