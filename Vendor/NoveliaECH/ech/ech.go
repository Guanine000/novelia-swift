// Package ech 为移动端提供流式 ECH 传输桥接，不在内存中整包缓存大文件。
package ech

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"strings"
	"sync"
	"time"

	core "github.com/inqadh/jissr-bypass"
)

// Client 持有可复用的 TLS 连接池与 DNS/ECH 缓存；所有受保护请求均要求 ECH 协商通过，绝不自动降级为明文 SNI。
type Client struct {
	transportMu       sync.RWMutex
	core              *core.Client
	probe             *core.Client
	transport         *http.Transport
	resolverTransport *resolverHTTPTransport
	proxy             ProxyResolver
	do                func(*http.Request) (*http.Response, error)
}

func NewClient() *Client {
	return NewClientWithProxyResolver(nil)
}

var (
	defaultWireResolvers = []string{
		"https://dns.alidns.com/dns-query", "https://223.5.5.5/dns-query",
		"https://1.1.1.1/dns-query", "https://cloudflare-dns.com/dns-query",
		"https://8.8.8.8/dns-query",
	}
	defaultJSONResolvers = []string{
		"https://cloudflare-dns.com/dns-query", "https://dns.google/resolve",
	}
)

func buildCoreClients(resolverTransport *resolverHTTPTransport, customWire []string) (*core.Client, *core.Client, error) {
	config := core.DefaultConfig()
	config.ResolverTransport = resolverTransport
	// 每个 DoH 提供方同时提供 A、AAAA 与 HTTPS 记录，不混用不同提供方的结果；
	// 包含 IP 字面量节点以确保系统 DNS 不可用时仍可解析。
	if len(customWire) > 0 {
		config.WireResolvers = append([]string(nil), customWire...)
		config.JSONResolvers = nil
	} else {
		config.WireResolvers = append([]string(nil), defaultWireResolvers...)
		config.JSONResolvers = append([]string(nil), defaultJSONResolvers...)
	}
	// 上游客户端仅负责加密 DNS 解析，实际 HTTP 调用走本地 transport 与按阶段超时。
	config.RequestTimeout = 24 * time.Hour
	config.UserAgent = "Novelia-ECH/1"
	c, err := core.NewClient(config)
	if err != nil {
		return nil, nil, err
	}
	config.RequestTimeout = 20 * time.Second
	p, err := core.NewClient(config)
	if err != nil {
		return nil, nil, err
	}
	return c, p, nil
}

func parseCustomDoHResolvers(rawList string) ([]string, error) {
	trimmed := strings.TrimSpace(rawList)
	if trimmed == "" {
		return nil, nil
	}
	parts := strings.FieldsFunc(trimmed, func(r rune) bool {
		return r == '\n' || r == '\r' || r == ',' || r == ';'
	})
	var resolvers []string
	seen := make(map[string]struct{})
	for _, part := range parts {
		item := strings.TrimSpace(part)
		if item == "" {
			continue
		}
		u, err := url.Parse(item)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return nil, errors.New("无效的 DoH 地址，仅支持不含查询参数的 https:// 地址")
		}
		normalized := u.String()
		if _, exists := seen[normalized]; exists {
			continue
		}
		seen[normalized] = struct{}{}
		resolvers = append(resolvers, normalized)
		if len(resolvers) > 8 {
			return nil, errors.New("自定义 DoH 节点最多支持 8 个")
		}
	}
	return resolvers, nil
}

func NewClientWithProxyResolver(proxy ProxyResolver) *Client {
	resolverTransport := newResolverHTTPTransport(proxy)
	c, p, err := buildCoreClients(resolverTransport, nil)
	if err != nil {
		panic("invalid built-in ECH configuration")
	}
	client := &Client{core: c, probe: p, transport: newHTTPTransport(c, proxy), resolverTransport: resolverTransport, proxy: proxy}
	client.do = client.doCurrent
	return client
}

// SetCustomDoHResolvers 更新用于 A/AAAA/HTTPS（ECH）解析的 DoH 节点列表；传入空字符串恢复内置默认节点。
func (c *Client) SetCustomDoHResolvers(rawList string) error {
	custom, err := parseCustomDoHResolvers(rawList)
	if err != nil {
		return err
	}
	nextCore, nextProbe, err := buildCoreClients(c.resolverTransport, custom)
	if err != nil {
		return errors.New("DoH 配置无效")
	}
	c.transportMu.Lock()
	previous := c.transport
	c.core = nextCore
	c.probe = nextProbe
	c.resolverTransport.reset()
	c.transport = newHTTPTransport(c.core, c.proxy)
	c.transportMu.Unlock()
	if previous != nil {
		previous.CloseIdleConnections()
	}
	return nil
}

// 新请求使用当前连接池，在途响应继续沿用旧 transport 直至结束。
func (c *Client) doCurrent(request *http.Request) (*http.Response, error) {
	c.transportMu.RLock()
	transport := c.transport
	c.transportMu.RUnlock()
	client := &http.Client{Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return client.Do(request)
}

func protectedURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || (u.Port() != "" && u.Port() != "443") {
		return false
	}
	switch u.Hostname() {
	case "n.novelia.cc", "auth.novelia.cc", "forum.novelia.cc":
		return true
	}
	return false
}

// Call 支持在建连、上传、等待响应头和流式读取任意阶段取消。
type Call struct {
	client          *Client
	request         *http.Request
	connectTimeout  time.Duration
	readTimeout     time.Duration
	writeTimeout    time.Duration
	connectAttempts int
	ctx             context.Context
	cancel          context.CancelFunc
	mu              sync.Mutex
	readMu          sync.Mutex
	executed        bool
	body            io.ReadCloser
	failure         string
	diagnostics     *connectionDiagnostics
}

// Upload 由宿主端按块供给，请求体无需落盘。
type Upload interface {
	ReadChunk(maxBytes int) ([]byte, error)
	Close()
}

type uploadReader struct{ source Upload }

func (r *uploadReader) Read(p []byte) (int, error) {
	chunk, err := r.source.ReadChunk(len(p))
	if err != nil {
		return 0, errors.New("upload read failed")
	}
	if len(chunk) > len(p) {
		return 0, errors.New("upload chunk too large")
	}
	if len(chunk) == 0 {
		return 0, io.EOF
	}
	return copy(p, chunk), nil
}
func (r *uploadReader) Close() error { r.source.Close(); return nil }

func (c *Client) NewCall(method, rawURL, headersJSON string, upload Upload, contentLength, connectTimeoutMillis, readTimeoutMillis, writeTimeoutMillis int64) (*Call, error) {
	if !protectedURL(rawURL) {
		return nil, errors.New("ECH destination is outside the configured HTTPS hosts")
	}
	for _, value := range []int64{connectTimeoutMillis, readTimeoutMillis, writeTimeoutMillis} {
		if value < 0 || value > 2147483647 {
			return nil, errors.New("invalid phase timeout")
		}
	}
	var headers map[string][]string
	if err := json.Unmarshal([]byte(headersJSON), &headers); err != nil {
		return nil, errors.New("invalid request headers")
	}
	ctx, cancel := context.WithCancel(context.Background())
	diagnostics := &connectionDiagnostics{start: time.Now()}
	ctx = context.WithValue(ctx, diagnosticKey{}, diagnostics)
	request, err := http.NewRequestWithContext(ctx, method, rawURL, nil)
	if err != nil {
		cancel()
		return nil, errors.New("invalid request")
	}
	for name, values := range headers {
		switch strings.ToLower(name) {
		case "host", "content-length", "connection", "transfer-encoding":
			continue
		}
		for _, value := range values {
			request.Header.Add(name, value)
		}
	}
	if request.Header.Get("User-Agent") == "" {
		request.Header.Set("User-Agent", "Novelia-ECH/1")
	}
	if upload != nil {
		request.Body = &uploadReader{source: upload}
		request.ContentLength = contentLength
		// 保持 GetBody 为 nil：非幂等上传绝不自动重放。
	}
	return &Call{client: c, request: request,
		connectAttempts: 3,
		connectTimeout:  time.Duration(connectTimeoutMillis) * time.Millisecond,
		readTimeout:     time.Duration(readTimeoutMillis) * time.Millisecond,
		writeTimeout:    time.Duration(writeTimeoutMillis) * time.Millisecond,
		ctx:             ctx, cancel: cancel, diagnostics: diagnostics}, nil
}

// SetConnectAttempts 允许外层有界恢复策略接管重试，避免重试层层相乘。
func (c *Call) SetConnectAttempts(attempts int) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.executed || attempts < 1 || attempts > 3 {
		return errors.New("invalid connect attempts")
	}
	c.connectAttempts = attempts
	return nil
}

// Reply 仅包含响应头信息，正文通过 Call.Read 流式读取。
type Reply struct {
	code     int
	protocol string
	headers  string
	length   int64
}

func (r *Reply) StatusCode() int      { return r.code }
func (r *Reply) Protocol() string     { return r.protocol }
func (r *Reply) HeadersJSON() string  { return r.headers }
func (r *Reply) ContentLength() int64 { return r.length }

func (c *Call) Execute() (*Reply, error) {
	c.mu.Lock()
	if c.executed {
		c.mu.Unlock()
		return nil, errors.New("call has already been executed")
	}
	c.executed = true
	c.mu.Unlock()
	if err := c.ctx.Err(); err != nil {
		return nil, err
	}
	phase := newPhaseDeadline(func(reason string) {
		stage := "response_headers"
		if reason == "请求发送超时" {
			stage = "request_sent"
		}
		diagnostic(c.ctx, diagnosticEvent{Stage: stage, Outcome: "failed", Reason: "timeout"})
		c.fail(reason)
		c.Cancel()
	})
	defer phase.stop()
	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			outcome := "new"
			if info.Reused {
				outcome = "reused"
			}
			diagnostic(c.ctx, diagnosticEvent{Stage: "connection", Outcome: outcome})
			phase.start(c.writeTimeout, "请求发送超时")
		},
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			diagnostic(c.ctx, diagnosticEvent{Stage: "request_sent", Outcome: "done", Reason: diagnosticReason(info.Err)})
			phase.start(c.readTimeout, "响应读取超时")
		},
		GotFirstResponseByte: func() { diagnostic(c.ctx, diagnosticEvent{Stage: "first_byte", Outcome: "ok"}) },
	}
	request := c.request.Clone(httptrace.WithClientTrace(c.request.Context(), trace))
	response, err := doWithConnectRetry(c.client.do, request, c.connectTimeout, c.connectAttempts)
	phase.stop()
	if err != nil {
		diagnostic(c.ctx, diagnosticEvent{Stage: "request", Outcome: "failed", Reason: diagnosticReason(err)})
		c.fail(failureReason(err.Error()))
		if c.request.Body != nil {
			c.request.Body.Close()
		}
		c.Cancel()
		return nil, errors.New("ECH connection or request failed")
	}
	if response.TLS == nil || !response.TLS.ECHAccepted || response.TLS.Version != tls.VersionTLS13 {
		diagnostic(c.ctx, diagnosticEvent{Stage: "tls", Outcome: "failed", Reason: "ech_not_accepted"})
		response.Body.Close()
		c.Cancel()
		return nil, errors.New("server did not accept TLS 1.3 ECH")
	}
	c.mu.Lock()
	if c.ctx.Err() != nil {
		c.mu.Unlock()
		response.Body.Close()
		return nil, errors.New("call cancelled")
	}
	c.body = response.Body
	c.mu.Unlock()
	headers, err := json.Marshal(response.Header)
	if err != nil {
		c.Cancel()
		return nil, errors.New("invalid response headers")
	}
	diagnostic(c.ctx, diagnosticEvent{Stage: "response_headers", Outcome: "ok", Protocol: response.Proto})
	return &Reply{code: response.StatusCode, protocol: response.Proto, headers: string(headers), length: response.ContentLength}, nil
}

func (c *Call) fail(reason string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.failure == "" {
		c.failure = reason
	}
}

// FailureReason 仅返回固定中文诊断标签，绝不包含原始错误或 URL。
func (c *Call) FailureReason() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.failure
}

// ReadChunk 显式区分正文数据与正常 EOF，避免 gomobile 把空切片映射为 ObjC nil 导致 Swift try 误判为错误。
type ReadChunk struct {
	Data []byte
	EOF  bool
}

// ReadChunk 流式读取下一块正文；正常结束时返回非空对象且 EOF 为 true。
func (c *Call) ReadChunk(maxBytes int) (*ReadChunk, error) {
	data, err := c.Read(maxBytes)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return &ReadChunk{EOF: true}, nil
	}
	return &ReadChunk{Data: data, EOF: false}, nil
}

// Read 在到达 EOF 时返回空切片，单次读取上限为 64 KiB。
func (c *Call) Read(maxBytes int) ([]byte, error) {
	if maxBytes <= 0 {
		return nil, errors.New("invalid read size")
	}
	if maxBytes > 65536 {
		maxBytes = 65536
	}
	c.readMu.Lock()
	defer c.readMu.Unlock()
	c.mu.Lock()
	body := c.body
	c.mu.Unlock()
	if body == nil {
		return nil, errors.New("response is not open")
	}
	if err := c.ctx.Err(); err != nil {
		return nil, err
	}
	deadline := newPhaseDeadline(func(reason string) {
		diagnostic(c.ctx, diagnosticEvent{Stage: "body", Outcome: "failed", Reason: "timeout"})
		c.fail(reason)
		c.Cancel()
	})
	deadline.start(c.readTimeout, "响应读取超时")
	buffer := make([]byte, maxBytes)
	n, err := body.Read(buffer)
	deadline.stop()
	if n > 0 {
		return buffer[:n], nil
	}
	if err == io.EOF {
		diagnostic(c.ctx, diagnosticEvent{Stage: "body", Outcome: "complete"})
		c.Cancel()
		return []byte{}, nil
	}
	if err != nil {
		diagnostic(c.ctx, diagnosticEvent{Stage: "body", Outcome: "failed", Reason: diagnosticReason(err)})
		c.Cancel()
		return nil, errors.New("ECH response read failed")
	}
	// net/http 的响应体在传入非空缓冲区时不会返回 (0, nil)。
	return nil, errors.New("empty response read")
}

func (c *Call) Cancel() {
	c.cancel()
	if c.request.Body != nil {
		c.request.Body.Close()
	}
	c.mu.Lock()
	body := c.body
	c.body = nil
	c.mu.Unlock()
	if body != nil {
		body.Close()
	}
}

type probeDiagnosticReport struct {
	Host      string            `json:"host"`
	OK        bool              `json:"ok"`
	Summary   string            `json:"summary"`
	ElapsedMs int64             `json:"elapsedMs"`
	Events    []diagnosticEvent `json:"events"`
}

// Probe 发起一次全新匿名 TLS 1.3 / ECH 握手，不携带账号数据也不发 HTTP 请求。
func (c *Client) Probe(host string) string {
	report := c.runProbe(host, false)
	return report.Summary
}

// ProbeDiagnostics 发起匿名握手并返回脱敏诊断 JSON，包含各阶段耗时与失败分类。
func (c *Client) ProbeDiagnostics(host string) string {
	report := c.runProbe(host, true)
	data, err := json.Marshal(report)
	if err != nil {
		return `{"host":"","ok":false,"summary":"诊断结果编码失败","elapsedMs":0,"events":[]}`
	}
	return string(data)
}

func (c *Client) runProbe(host string, collectDiagnostics bool) probeDiagnosticReport {
	if !protectedURL("https://" + host + "/") {
		return probeDiagnosticReport{Host: host, OK: false, Summary: "不支持的诊断域名", Events: []diagnosticEvent{}}
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var diag *connectionDiagnostics
	if collectDiagnostics {
		diag = &connectionDiagnostics{start: start}
		diag.enabled.Store(true)
		ctx = context.WithValue(ctx, diagnosticKey{}, diag)
	}
	c.transportMu.RLock()
	probeClient := c.probe
	c.transportMu.RUnlock()
	connection, err := dialResolvedECH(ctx, probeClient, "tcp", host, c.proxy)
	elapsed := time.Since(start).Milliseconds()
	events := []diagnosticEvent{}
	if diag != nil {
		diag.mu.Lock()
		events = append(events, diag.events...)
		diag.mu.Unlock()
	}
	if err == nil {
		connection.Close()
		return probeDiagnosticReport{Host: host, OK: true, Summary: "TLS 1.3 / ECH 握手成功", ElapsedMs: elapsed, Events: events}
	}
	detail := err.Error()
	var summary string
	switch {
	case strings.HasPrefix(detail, "resolve:"):
		summary = "DNS / ECH 配置获取失败"
	case strings.HasPrefix(detail, "tcp:"):
		summary = "TCP 连接失败：" + failureReason(detail)
	default:
		summary = "ECH 握手失败：" + failureReason(detail)
	}
	return probeDiagnosticReport{Host: host, OK: false, Summary: summary, ElapsedMs: elapsed, Events: events}
}

func (c *Client) ResetNetworkState() {
	c.transportMu.Lock()
	defer c.transportMu.Unlock()
	c.core.ResetNetworkState()
	c.probe.ResetNetworkState()
	c.resolverTransport.reset()
	previous := c.transport
	c.transport = newHTTPTransport(c.core, c.proxy)
	previous.CloseIdleConnections()
}

// 将底层错误归类为固定中文标签，绝不向界面暴露本机地址或原始错误。
func failureReason(detail string) string {
	text := strings.ToLower(detail)
	switch {
	case strings.Contains(text, "x509"), strings.Contains(text, "certificate"):
		return "证书验证未通过"
	case strings.Contains(text, "proxy authentication"):
		return "系统代理需要认证"
	case strings.Contains(text, "unsupported system proxy"), strings.Contains(text, "invalid system proxy"):
		return "系统代理配置不受支持"
	case strings.Contains(text, "proxy"):
		return "系统代理连接失败"
	case strings.Contains(text, "deadline"), strings.Contains(text, "timeout"), strings.Contains(text, "context canceled"):
		return "连接超时"
	case strings.Contains(text, "reset"), strings.Contains(text, "forcibly closed"), strings.Contains(text, "eof"):
		return "连接被中断"
	case strings.Contains(text, "rejected"):
		return "服务器拒绝 ECH 配置"
	case strings.HasPrefix(text, "tcp:"), strings.Contains(text, "dial tcp"), strings.Contains(text, "no such host"), strings.Contains(text, "network is unreachable"), strings.Contains(text, "network is down"):
		return "连接失败"
	default:
		return "TLS 协商未完成"
	}
}
