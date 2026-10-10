#!/usr/bin/env python3
"""Test the actual injected bridge without contacting an authentication server."""
from pathlib import Path
import json
import subprocess
source = Path('iOSApp/AccountAuth.swift').read_text()
script = source.split('        let script = """',1)[1].split('        """',1)[0]
js = r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const injected = SCRIPT;
async function test(path, method, ok, expected, origin = 'https://auth.novelia.cc', asRequest = false) {
 const notifications = [];
 const listeners = {};
 const response = {ok};
 Object.defineProperty(response, 'body', {get() { throw Error('Body must not be inspected'); }});
 const window = {location: {origin, href: origin + '/'},
   webkit: {messageHandlers: {noveliaAuth: {postMessage: m => notifications.push(m)}}},
   addEventListener: (type, listener) => listeners[type] = listener,
   fetch: async () => response};
 vm.runInNewContext(injected, {window, URL, Request});
 const options = {method};
 Object.defineProperty(options, 'body', {get() { throw Error('Credentials must not be inspected'); }});
 const result = await window.fetch(asRequest ? new Request(new URL(path, origin), {method}) : path, options);
 assert.equal(result, response);
 assert.equal(notifications.length, expected);
 listeners.message({origin: 'https://evil.invalid', data: {type: 'login_success'}});
 assert.equal(notifications.length, expected);
 listeners.message({origin: 'https://auth.novelia.cc', data: {type: 'login_success'}});
 assert.equal(notifications.length, expected + 1);
}
(async () => {
 await test('/api/v1/auth/login', 'POST', true, 1);
 await test('/api/v1/auth/register', 'POST', true, 1, undefined, true);
 await test('/api/v1/auth/login', 'POST', false, 0);
 await test('/api/v1/auth/login', 'GET', true, 0);
 await test('/api/v1/auth/otp/request', 'POST', true, 0);
 await test('https://evil.invalid/api/v1/auth/login', 'POST', true, 0);
 await test('/api/v1/auth/login', 'POST', true, 0, 'https://evil.invalid');
 console.log('Auth login bridge passed: login/register success, failed login, unrelated requests and untrusted origins; no credential/body inspection');
})().catch(error => { console.error(error); process.exit(1); });
'''.replace('SCRIPT',json.dumps(script))
subprocess.run(['node','-e',js],check=True)
