package ech

import (
	"context"
	"crypto/tls"
	"errors"
	"net/http"
	"net/http/httptrace"
	"sync/atomic"
	"time"
)

// 仅对无请求体读请求在 GotConn 之前重试：此时尚未发送任何 HTTP 字节。
// 绝不重放上传、HTTP 错误或已开始的正文读取。
// 底层使用 DialTLSContext，因此 Transport.TLSHandshakeTimeout 不会生效。
func doWithConnectRetry(do func(*http.Request) (*http.Response, error), request *http.Request, budget time.Duration, limit ...int) (*http.Response, error) {
	attempts := 1
	if request.Body == nil && (request.Method == http.MethodGet || request.Method == http.MethodHead) {
		attempts = 3
	}
	if len(limit) > 0 && limit[0] > 0 && limit[0] < attempts {
		attempts = limit[0]
	}
	var last error
	for attempt := 0; attempt < attempts; attempt++ {
		if err := request.Context().Err(); err != nil {
			return nil, err
		}
		diagnostic(request.Context(), diagnosticEvent{Stage: "connect_attempt", Outcome: "start", Attempt: attempt + 1})
		ctx, cancel := context.WithCancel(request.Context())
		var connected atomic.Bool
		var timer *time.Timer
		if budget > 0 {
			timer = time.AfterFunc(budget, cancel)
		}
		trace := &httptrace.ClientTrace{GotConn: func(httptrace.GotConnInfo) {
			connected.Store(true)
			if timer != nil {
				timer.Stop()
			}
		}}
		// net/http 会解绑拨号取消信号但保留 context 值，借此把本次尝试的取消与超时传给自定义 TLS 拨号。
		ctx = context.WithValue(ctx, dialPolicyKey{}, dialPolicy{parent: ctx, timeout: budget})
		response, err := do(request.Clone(httptrace.WithClientTrace(ctx, trace)))
		if timer != nil {
			timer.Stop()
		}
		if err == nil {
			// 外层 Call.Cancel 会在 EOF/关闭时取消父 context，确保建连预算过后响应正文仍可继续读取。
			return response, nil
		}
		connectExpired := ctx.Err() != nil && request.Context().Err() == nil
		cancel()
		if response != nil && response.Body != nil {
			response.Body.Close()
		}
		last = err
		reason := diagnosticReason(err)
		if !connected.Load() && connectExpired {
			reason = "timeout"
		}
		diagnostic(request.Context(), diagnosticEvent{Stage: "connect_attempt", Outcome: "failed", Attempt: attempt + 1, Reason: reason})
		var certificate *tls.CertificateVerificationError
		if connected.Load() || errors.As(err, &certificate) {
			break
		}
	}
	return nil, last
}
