// Package reality is a thin, gomobile-bindable wrapper around
// github.com/xtls/libxray (which itself wraps xray-core) exposing exactly the
// VLESS+REALITY client shape bcrypto needs: build the config from a handful
// of server-issued parameters, start/stop the local SOCKS5-fronted tunnel,
// report state. gomobile bind only crosses the language boundary with
// primitive types (string/int/bool) and at most one non-error return value,
// so the surface below is deliberately flat — no exported structs.
//
// Package name is "reality" on purpose: gomobile bind names the produced
// framework/module after it (Reality.xcframework / Reality.aar). Swift does
// NOT strip the package-name prefix from these free C functions the way it
// does for Objective-C class methods (verified against the actual generated
// header, see the "gomobile-facing surface" comment below) — Swift sees the
// exact C names, e.g. RealityStart(...)/RealityStop(), not Reality.start(...).
//
// libxray holds ONE package-level *core.Instance (xray/xray.go: coreServer) —
// only one tunnel can run per process. That matches this project's existing
// single-embedded-Tor-thread model (EmbeddedTorManager.swift), so it is not a
// new constraint we are introducing.
package reality

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sync"

	libXray "github.com/xtls/libxray"
	"github.com/xtls/libxray/nodep"
)

// mu serializes our own Start/Stop calls. libxray's coreServer global has no
// lock of its own (xray/xray.go) — this does not fix that, it just stops
// this wrapper from firing two overlapping Start()s at each other.
var mu sync.Mutex

// startParams is the JSON shape Start() accepts as its single string
// argument. Field names match the wire shape the iOS RealityManager builds
// from server-provisioned values (see qaudion-ios RealityManager.swift) —
// keep both sides in sync by hand, there is no shared schema source yet.
type startParams struct {
	ServerAddress  string `json:"serverAddress"`
	ServerPort     int    `json:"serverPort"`
	UUID           string `json:"uuid"`
	Flow           string `json:"flow"`
	PublicKey      string `json:"publicKey"`
	ShortID        string `json:"shortId"`
	ServerName     string `json:"serverName"`
	Fingerprint    string `json:"fingerprint"`
	LocalSocksPort int    `json:"localSocksPort"`
	// DataDir backs xray-core's AssetLocation/CertLocation (geoip/geosite.dat
	// lookup dir). Our client config has no geoip/geosite-based routing rule
	// (single outbound, no rules[] block) so this directory never actually
	// needs those files populated — any writable, per-app-instance path
	// works (e.g. Application Support). Still required: xray.InitEnv sets
	// the env vars unconditionally.
	DataDir string `json:"dataDir"`
}

func (p *startParams) validate() error {
	if p.ServerAddress == "" {
		return errors.New("reality: serverAddress is required")
	}
	if p.UUID == "" {
		return errors.New("reality: uuid is required")
	}
	if p.PublicKey == "" {
		return errors.New("reality: publicKey is required")
	}
	if p.ServerName == "" {
		return errors.New("reality: serverName is required")
	}
	return nil
}

func (p *startParams) applyDefaults() {
	if p.ServerPort == 0 {
		p.ServerPort = 443
	}
	if p.Flow == "" {
		// Documented best-practice pairing with REALITY in every current
		// official xray-core example — see CENSORSHIP_RESISTANT_TRANSPORT_
		// DESIGN.md §4.4 research notes.
		p.Flow = "xtls-rprx-vision"
	}
	if p.Fingerprint == "" {
		p.Fingerprint = "chrome"
	}
}

// --- xray client config shape (verified against XTLS/Xray-examples' current
// client config — uses settings.vnext[], not a flattened older schema) ---

type clientConfig struct {
	Log       logConfig  `json:"log"`
	Inbounds  []inbound  `json:"inbounds"`
	Outbounds []outbound `json:"outbounds"`
}

type logConfig struct {
	Loglevel string `json:"loglevel"`
}

type inbound struct {
	Listen   string         `json:"listen"`
	Port     int            `json:"port"`
	Protocol string         `json:"protocol"`
	Settings socksSettings  `json:"settings"`
	Sniffing sniffingConfig `json:"sniffing"`
}

type socksSettings struct {
	UDP bool `json:"udp"`
}

type sniffingConfig struct {
	Enabled      bool     `json:"enabled"`
	DestOverride []string `json:"destOverride"`
	RouteOnly    bool     `json:"routeOnly"`
}

type outbound struct {
	Tag            string         `json:"tag"`
	Protocol       string         `json:"protocol"`
	Settings       vlessOutbound  `json:"settings"`
	StreamSettings streamSettings `json:"streamSettings"`
}

type vlessOutbound struct {
	Vnext []vnextEntry `json:"vnext"`
}

type vnextEntry struct {
	Address string      `json:"address"`
	Port    int         `json:"port"`
	Users   []vlessUser `json:"users"`
}

type vlessUser struct {
	ID         string `json:"id"`
	Encryption string `json:"encryption"`
	Flow       string `json:"flow,omitempty"`
}

type streamSettings struct {
	Network         string          `json:"network"`
	Security        string          `json:"security"`
	RealitySettings realitySettings `json:"realitySettings"`
}

type realitySettings struct {
	Fingerprint string `json:"fingerprint"`
	ServerName  string `json:"serverName"`
	PublicKey   string `json:"publicKey"`
	ShortID     string `json:"shortId,omitempty"`
	// SpiderX must be present (even empty) in every verified example config;
	// omitting the field entirely has not been tested against this xray-core
	// pin, so keep it explicit rather than omitempty.
	SpiderX string `json:"spiderX"`
}

func buildClientConfig(p startParams, socksPort int) clientConfig {
	return clientConfig{
		Log: logConfig{Loglevel: "warning"},
		Inbounds: []inbound{{
			Listen:   "127.0.0.1",
			Port:     socksPort,
			Protocol: "socks",
			Settings: socksSettings{UDP: true},
			Sniffing: sniffingConfig{
				Enabled:      true,
				DestOverride: []string{"http", "tls", "quic"},
				RouteOnly:    true,
			},
		}},
		Outbounds: []outbound{{
			Tag:      "reality-out",
			Protocol: "vless",
			Settings: vlessOutbound{Vnext: []vnextEntry{{
				Address: p.ServerAddress,
				Port:    p.ServerPort,
				Users: []vlessUser{{
					ID:         p.UUID,
					Encryption: "none",
					Flow:       p.Flow,
				}},
			}}},
			StreamSettings: streamSettings{
				Network:  "tcp",
				Security: "reality",
				RealitySettings: realitySettings{
					Fingerprint: p.Fingerprint,
					ServerName:  p.ServerName,
					PublicKey:   p.PublicKey,
					ShortID:     p.ShortID,
					SpiderX:     "",
				},
			},
		}},
	}
}

// decodeStringResponse unwraps the base64(json(nodep.CallResponse[string]))
// envelope every libXray entry point returns.
func decodeStringResponse(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", fmt.Errorf("reality: decode xray response: %w", err)
	}
	var resp nodep.CallResponse[string]
	if err := json.Unmarshal(raw, &resp); err != nil {
		return "", fmt.Errorf("reality: parse xray response: %w", err)
	}
	if !resp.Success {
		return "", fmt.Errorf("reality: xray error: %s", resp.Err)
	}
	return resp.Data, nil
}

// --- gomobile-facing surface ---
//
// gomobile bind's (T, error) return convention generates a C signature of
// the shape `BOOL RealityStart(NSString*, long* ret0_, NSError** error)` —
// verified by actually running `gobind -lang=objc` against this package
// while writing it (no Xcode/network-fetch of gomobile needed for that
// step). Plain C functions do NOT get Swift's automatic NSError**→`throws`
// bridging (that conversion is an Objective-C METHOD convention; gomobile
// does not emit the `NS_SWIFT_NAME`/`swift_error` attributes that would
// extend it to these free functions) — so callers would otherwise need to
// manually bridge an UnsafeMutablePointer<NSError?>, which is easy to get
// wrong from Swift without a real compiler to check it against. Exporting
// plain scalars + a LastError() accessor sidesteps that entirely: every
// entry point below is directly, unambiguously Swift-callable.
//
// The (T, error)-returning Go-idiomatic implementations these wrap
// (start/stop/version) are unexported and unit-tested normally.

var lastErrMu sync.Mutex
var lastErr string

func setLastError(err error) {
	lastErrMu.Lock()
	defer lastErrMu.Unlock()
	if err != nil {
		lastErr = err.Error()
	} else {
		lastErr = ""
	}
}

// LastError returns the error message from the most recently failed
// Start/Stop/Version call, or "" if it succeeded.
func LastError() string {
	lastErrMu.Lock()
	defer lastErrMu.Unlock()
	return lastErr
}

// Start builds a VLESS+REALITY client config from paramsJSON (see
// startParams) and starts the tunnel. Returns the bound local SOCKS5 port
// (== LocalSocksPort from paramsJSON when non-zero; auto-picked otherwise)
// on success, or 0 on failure — call LastError() for why.
func Start(paramsJSON string) int {
	port, err := start(paramsJSON)
	setLastError(err)
	if err != nil {
		return 0
	}
	return port
}

// start is the Go-idiomatic (error-returning) implementation Start wraps.
// Errors if a tunnel is already running — call Stop() first.
func start(paramsJSON string) (int, error) {
	mu.Lock()
	defer mu.Unlock()

	if libXray.GetXrayState() {
		return 0, errors.New("reality: tunnel already running, call Stop() first")
	}

	var p startParams
	if err := json.Unmarshal([]byte(paramsJSON), &p); err != nil {
		return 0, fmt.Errorf("reality: invalid params JSON: %w", err)
	}
	if err := p.validate(); err != nil {
		return 0, err
	}
	p.applyDefaults()

	port := p.LocalSocksPort
	if port == 0 {
		ports, err := nodep.GetFreePorts(1)
		if err != nil || len(ports) == 0 {
			return 0, fmt.Errorf("reality: no free local port available: %w", err)
		}
		port = ports[0]
	}

	cfgBytes, err := json.Marshal(buildClientConfig(p, port))
	if err != nil {
		return 0, fmt.Errorf("reality: marshal xray config: %w", err)
	}

	req, err := libXray.NewXrayRunFromJSONRequest(p.DataDir, string(cfgBytes))
	if err != nil {
		return 0, fmt.Errorf("reality: build run request: %w", err)
	}
	if _, err := decodeStringResponse(libXray.RunXrayFromJSON(req)); err != nil {
		return 0, err
	}
	return port, nil
}

// Stop tears down the running tunnel. Returns false on failure — call
// LastError() for why. Safe to call when not running.
func Stop() bool {
	mu.Lock()
	defer mu.Unlock()
	_, err := decodeStringResponse(libXray.StopXray())
	setLastError(err)
	return err == nil
}

// IsRunning reports whether a tunnel is currently active.
func IsRunning() bool {
	return libXray.GetXrayState()
}

// Version returns the bundled xray-core version string, or "" on failure —
// call LastError() for why. Diagnostics only.
func Version() string {
	v, err := decodeStringResponse(libXray.XrayVersion())
	setLastError(err)
	return v
}
