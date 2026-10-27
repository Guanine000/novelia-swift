#!/usr/bin/env python3
"""测试实际注入的登录桥接脚本，不连接认证服务器。"""
from pathlib import Path
import json
import subprocess
import tempfile
# 通过实际的 Swift 配置生成生产环境 JavaScript，
# 让 origin／路径转义与生成过程都处于测试之下，
# 而不是在复制的脚本里替换 Swift 插值。
with tempfile.TemporaryDirectory(prefix='novelia-auth-script-') as directory:
    root = Path(directory)
    (root/'main.swift').write_text('''import Foundation
let configurations = [APIConfiguration.production.authentication,
    try AuthenticationConfiguration(origin: URL(string: "https://login.example.test:8443")!,
        loginPath: "/session/login", registerPath: "/session/register")]
let profiles = configurations.map { ["script": $0.loginSuccessScript, "origin": $0.origin.absoluteString,
                                     "pageOrigin": $0.loginPageOrigin.absoluteString, "login": $0.loginPath, "register": $0.registerPath] }
print(String(decoding: try JSONEncoder().encode(profiles), as: UTF8.self))
''')
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(root/'cache'),
                    'Sources/NoveliaIOSCore/Infrastructure/API/APIConfiguration.swift', str(root/'main.swift'),
                    '-o', str(root/'generate')], check=True)
    profiles = json.loads(subprocess.check_output([str(root/'generate')], text=True))
js = r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const profiles = PROFILES;
let injected, trustedOrigin, loginPageOrigin;
async function test(path, method, ok, expected, origin = trustedOrigin, asRequest = false) {
 const notifications = [];
 const listeners = {};
 const response = {ok};
 Object.defineProperty(response, 'body', {get() { throw Error('Body must not be inspected'); }});
 const window = {location: {origin, href: origin + '/'},
   webkit: {messageHandlers: {noveliaAuth: {postMessage: m => notifications.push(m)}}},
   addEventListener: (type, listener) => listeners[type] = listener,
   fetch: async () => response};
 const document = {readyState: 'loading', addEventListener: () => {}};
 vm.runInNewContext(injected, {window, document, URL, Request});
 const options = {method};
 Object.defineProperty(options, 'body', {get() { throw Error('Credentials must not be inspected'); }});
 const result = await window.fetch(asRequest ? new Request(new URL(path, origin), {method}) : path, options);
 assert.equal(result, response);
 assert.equal(notifications.length, expected);
 listeners.message({origin: 'https://evil.invalid', data: {type: 'login_success'}});
 assert.equal(notifications.length, expected);
 listeners.message({origin: trustedOrigin, data: {type: 'login_success'}});
 assert.equal(notifications.length, expected + ([trustedOrigin, loginPageOrigin].includes(origin) ? 1 : 0));
}
(async () => {
 for (const profile of profiles) {
  injected = profile.script; trustedOrigin = profile.origin; loginPageOrigin = profile.pageOrigin;
  await test(profile.login, 'POST', true, 1);
  await test(trustedOrigin + profile.login, 'POST', true, 1, loginPageOrigin, true);
  if (loginPageOrigin !== trustedOrigin) await test(profile.login, 'POST', true, 0, loginPageOrigin);
  await test(trustedOrigin + profile.login, 'POST', true, 0, 'https://evil.invalid');
  await test(profile.register, 'POST', true, 1, undefined, true);
  await test(profile.login, 'POST', false, 0);
  await test(profile.login, 'GET', true, 0);
  await test('/api/v1/auth/otp/request', 'POST', true, 0);
  await test('https://evil.invalid' + profile.login, 'POST', true, 0);
  await test(profile.login, 'POST', true, 0, 'https://evil.invalid');
 }
 // 官网按钮立即出现、异步出现和超时停止观察；不读取表单或响应。
 const profile = profiles[0];
 for (const delayed of [false, true]) {
  let available = !delayed, clicks = 0, disconnected = 0, callback, timeout;
  const button = {textContent: ' 登录/注册 ', click: () => clicks++};
  const document = {readyState: 'complete', documentElement: {},
    querySelectorAll: () => available ? [button] : []};
  const window = {location: {origin: profile.pageOrigin}, addEventListener: () => {}, fetch: async () => ({})};
  class MutationObserver { constructor(fn) { callback = fn; } observe() {} disconnect() { disconnected++; } }
  vm.runInNewContext(profile.script, {window, document, MutationObserver, setTimeout: fn => timeout = fn});
  if (delayed) { assert.equal(clicks, 0); available = true; callback(); assert.equal(disconnected, 1); timeout(); }
  assert.equal(clicks, 1);
 }
 console.log('Auth login bridge passed: login/register success, failed login, unrelated requests and untrusted origins; no credential/body inspection');
})().catch(error => { console.error(error); process.exit(1); });
'''.replace('PROFILES',json.dumps(profiles))
subprocess.run(['node','-e',js],check=True)
