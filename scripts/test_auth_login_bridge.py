#!/usr/bin/env python3
"""Test the actual injected bridge without contacting an authentication server."""
from pathlib import Path
import json
import subprocess
import tempfile
# Generate the production JavaScript through the actual Swift configuration.
# Keep origin/path escaping and generation under test, rather than substituting
# Swift interpolation in a copied script.
with tempfile.TemporaryDirectory(prefix='novelia-auth-script-') as directory:
    root = Path(directory)
    (root/'main.swift').write_text('''import Foundation
let configurations = [APIConfiguration.production.authentication,
    try AuthenticationConfiguration(origin: URL(string: "https://login.example.test:8443")!,
        loginPath: "/session/login", registerPath: "/session/register")]
let profiles = configurations.map { ["script": $0.loginSuccessScript, "origin": $0.origin.absoluteString,
                                     "login": $0.loginPath, "register": $0.registerPath] }
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
let injected, trustedOrigin;
async function test(path, method, ok, expected, origin = trustedOrigin, asRequest = false) {
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
 listeners.message({origin: trustedOrigin, data: {type: 'login_success'}});
 assert.equal(notifications.length, expected + 1);
}
(async () => {
 for (const profile of profiles) {
  injected = profile.script; trustedOrigin = profile.origin;
  await test(profile.login, 'POST', true, 1);
  await test(profile.register, 'POST', true, 1, undefined, true);
  await test(profile.login, 'POST', false, 0);
  await test(profile.login, 'GET', true, 0);
  await test('/api/v1/auth/otp/request', 'POST', true, 0);
  await test('https://evil.invalid' + profile.login, 'POST', true, 0);
  await test(profile.login, 'POST', true, 0, 'https://evil.invalid');
 }
 console.log('Auth login bridge passed: login/register success, failed login, unrelated requests and untrusted origins; no credential/body inspection');
})().catch(error => { console.error(error); process.exit(1); });
'''.replace('PROFILES',json.dumps(profiles))
subprocess.run(['node','-e',js],check=True)
