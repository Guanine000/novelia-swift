package ech

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCustomDoHResolverValidation(t *testing.T) {
	client := NewClient()
	if err := client.SetCustomDoHResolvers(""); err != nil {
		t.Fatalf("empty reset should succeed: %v", err)
	}
	if err := client.SetCustomDoHResolvers("https://dns.alidns.com/dns-query\nhttps://1.1.1.1/dns-query, https://1.1.1.1/dns-query"); err != nil {
		t.Fatalf("valid custom DoH list should succeed: %v", err)
	}
	invalidCases := []string{
		"http://1.1.1.1/dns-query",
		"https://user:pass@1.1.1.1/dns-query",
		"https://1.1.1.1/dns-query?name=a",
		"https://1.1.1.1/dns-query#frag",
		"not-a-url",
		strings.Join([]string{
			"https://1.0.0.1/dns-query", "https://1.0.0.2/dns-query", "https://1.0.0.3/dns-query",
			"https://1.0.0.4/dns-query", "https://1.0.0.5/dns-query", "https://1.0.0.6/dns-query",
			"https://1.0.0.7/dns-query", "https://1.0.0.8/dns-query", "https://1.0.0.9/dns-query",
		}, "\n"),
	}
	for _, raw := range invalidCases {
		if err := client.SetCustomDoHResolvers(raw); err == nil {
			t.Fatalf("expected error for invalid DoH input %q", raw)
		}
	}
}

func TestProbeDiagnosticsUnsupportedHost(t *testing.T) {
	client := NewClient()
	raw := client.ProbeDiagnostics("example.com")
	var report probeDiagnosticReport
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatalf("invalid probe diagnostic JSON: %v (%s)", err, raw)
	}
	if report.OK || report.Summary != "不支持的诊断域名" {
		t.Fatalf("unexpected report: %+v", report)
	}
}
