package ech

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 该诊断结构刻意不包含 URL、请求头、请求/响应正文、证书主题、本机地址或原始异常文本。
type diagnosticEvent struct {
	Stage      string `json:"stage"`
	Outcome    string `json:"outcome"`
	AtMillis   int64  `json:"atMillis"`
	DurationMs int64  `json:"durationMs,omitempty"`
	Reason     string `json:"reason,omitempty"`
	Resolver   string `json:"resolver,omitempty"`
	Family     string `json:"family,omitempty"`
	ServerIP   string `json:"serverIp,omitempty"`
	Attempt    int    `json:"attempt,omitempty"`
	Protocol   string `json:"protocol,omitempty"`
}

func diagnosticServerIP(raw string) string {
	ip := net.ParseIP(raw)
	if ip == nil {
		return "unknown"
	}
	if !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return "non_public"
	}
	return ip.String()
}

type diagnosticKey struct{}
type connectionDiagnostics struct {
	enabled atomic.Bool
	start   time.Time
	mu      sync.Mutex
	events  []diagnosticEvent
}

func diagnostic(ctx context.Context, event diagnosticEvent) {
	d, _ := ctx.Value(diagnosticKey{}).(*connectionDiagnostics)
	if d == nil || !d.enabled.Load() {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.events) >= 128 {
		return
	}
	event.AtMillis = time.Since(d.start).Milliseconds()
	d.events = append(d.events, event)
}

func diagnosticPhase(ctx context.Context, stage string) func(error) {
	start := time.Now()
	diagnostic(ctx, diagnosticEvent{Stage: stage, Outcome: "start"})
	return func(err error) {
		outcome := "ok"
		if err != nil {
			outcome = "failed"
		}
		diagnostic(ctx, diagnosticEvent{Stage: stage, Outcome: outcome, DurationMs: time.Since(start).Milliseconds(), Reason: diagnosticReason(err)})
	}
}

func diagnosticReason(err error) string {
	if err == nil {
		return ""
	}
	var certificate *tls.CertificateVerificationError
	var unknownAuthority x509.UnknownAuthorityError
	var rejection *tls.ECHRejectionError
	var dns *net.DNSError
	var network net.Error
	switch {
	case errors.As(err, &certificate), errors.As(err, &unknownAuthority):
		return "certificate"
	case errors.As(err, &rejection):
		return "ech_rejected"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.As(err, &network) && network.Timeout():
		return "timeout"
	case errors.As(err, &dns):
		return "dns"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return "eof"
	}
	// 仅在内部归类，绝不返回可能包含 URL 的原始错误字符串。
	text := strings.ToLower(err.Error())
	switch {
	case strings.Contains(text, "reset"), strings.Contains(text, "forcibly closed"):
		return "reset"
	case strings.Contains(text, "refused"):
		return "refused"
	case strings.Contains(text, "unreachable"), strings.Contains(text, "no route"):
		return "unreachable"
	case strings.Contains(text, "no valid ech"), strings.Contains(text, "no ech"):
		return "ech_config_missing"
	case strings.Contains(text, "no a record"), strings.Contains(text, "no a/aaaa record"):
		return "dns_no_address"
	case strings.Contains(text, "certificate"), strings.Contains(text, "x509"):
		return "certificate"
	case strings.Contains(text, "context canceled"):
		return "cancelled"
	case strings.Contains(text, "http 403"):
		return "http_403"
	case strings.Contains(text, "http 429"):
		return "http_429"
	case strings.Contains(text, "unexpected content type"), strings.Contains(text, "dns status"):
		return "dns_response"
	case strings.Contains(text, "timeout"), strings.Contains(text, "deadline"):
		return "timeout"
	default:
		return "io"
	}
}

// Resolve 会返回聚合错误；此处仅提取内置解析器标识与固定分类，不保留原始错误文本。
func diagnosticResolverFailures(ctx context.Context, err error) {
	if err == nil {
		return
	}
	text := err.Error()
	for _, endpoint := range []string{"https://dns.alidns.com/dns-query", "https://223.5.5.5/dns-query", "https://1.1.1.1/dns-query", "https://cloudflare-dns.com/dns-query", "https://8.8.8.8/dns-query", "https://dns.google/resolve"} {
		index := strings.Index(text, endpoint)
		if index < 0 {
			continue
		}
		part := strings.SplitN(text[index:], ";", 2)[0]
		diagnostic(ctx, diagnosticEvent{Stage: "doh_provider", Outcome: "failed", Resolver: resolverLabel(endpoint), Reason: diagnosticReason(errors.New(part))})
	}
}

func resolverLabel(endpoint string) string {
	switch endpoint {
	case "https://dns.alidns.com/dns-query":
		return "alidns_name"
	case "https://223.5.5.5/dns-query":
		return "alidns_ip"
	case "https://1.1.1.1/dns-query":
		return "cloudflare_ip"
	case "https://cloudflare-dns.com/dns-query":
		return "cloudflare_name"
	case "https://8.8.8.8/dns-query":
		return "google_ip"
	case "https://dns.google/resolve":
		return "google_json"
	default:
		return "other"
	}
}

// EnableDiagnostics 必须在 Execute 前调用；未启用时不保留任何事件。
func (c *Call) EnableDiagnostics() { c.diagnostics.enabled.Store(true) }

// DiagnosticsJSON 可安全导出，绝不暴露 Go 原始错误。
func (c *Call) DiagnosticsJSON() string {
	c.diagnostics.mu.Lock()
	defer c.diagnostics.mu.Unlock()
	if len(c.diagnostics.events) == 0 {
		return "[]"
	}
	data, _ := json.Marshal(c.diagnostics.events)
	return string(data)
}
