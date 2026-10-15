#!/usr/bin/env python3
"""Exercise the production novel/forum session refresh coordination with a fake auth server; no network or Keychain."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'iOSApp/Features/Account/AccountAuth.swift').read_text()
gate = (root / 'Sources/NoveliaIOSCore/Support/SerialAsyncGate.swift').read_text()


def method(part, signature):
    start = part.index(signature)
    brace = part.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (part[end] == '{') - (part[end] == '}')
        end += 1
    return part[start:end] + '\n'


account = source.split('final class AccountAuthStore', 1)[1].split('final class ForumAuthStore', 1)[0]
forum = source.split('final class ForumAuthStore', 1)[1].split('struct AuthSessionRefresher', 1)[0]
error = source[source.index('private enum AccountAuthError'):source.index('struct NoveliaLoginSheet')]

stored = '''
 var username: String?; var isRefreshing = false; var errorMessage: String?
 var sessionGeneration = 0
 let tokenStore = MemoryTokens()
 let refresher: AuthSessionRefresher
 let refreshQueue: SerialAsyncGate
 var refreshTask: (generation: Int, task: Task<Bool, Never>)?
 init(_ refresher: AuthSessionRefresher, _ queue: SerialAsyncGate) { self.refresher = refresher; refreshQueue = queue }
'''
code = 'import Foundation\n' + gate + error + r'''
final class MemoryTokens {
 var token: String?; var clears = 0
 func save(_ value: String) throws { token = value }
 func clear() { clears += 1; token = nil }
}
func jwt(_ subject: String) -> String {
 let payload = try! JSONSerialization.data(withJSONObject: ["sub": subject, "exp": 4_000_000_000])
 let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
  .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
 return "e30.\(encoded).sig"
}
/// 刷新 Cookie 每次使用后轮换；带着已被轮换的旧 Cookie 续期会被拒绝（401）。
@MainActor final class FakeAuthServer {
 var cookie = 0; var active = 0; var maxActive = 0; var requests: [String] = []; var subject = "alice"; var rejectNext = false
 func refresh(app: String) async throws -> String {
  let used = cookie
  requests.append(app); active += 1; maxActive = max(maxActive, active)
  defer { active -= 1 }
  try? await Task.sleep(nanoseconds: 20_000_000)
  if rejectNext { rejectNext = false; throw AccountAuthError.refreshRejected(401) }
  guard used == cookie else { throw AccountAuthError.refreshRejected(401) }
  cookie += 1
  return jwt(subject)
 }
}
@MainActor struct AuthSessionRefresher {
 let server: FakeAuthServer; let app: String
 func fetchToken() async throws -> String { try await server.refresh(app: app) }
}
@MainActor final class AccountAuthStore {
''' + stored + method(account, '    func refreshSession() async -> Bool {') \
    + method(account, '    private func performRefresh(generation: Int) async -> Bool {') \
    + method(account, '    func clearSession() {') + method(account, '    static func username(from token: String?) -> String? {') + r'''
}
@MainActor final class ForumAuthStore {
 weak var accountAuth: AccountAuthStore?
''' + stored + method(forum, '    func refreshSession() async -> Bool {') \
    + method(forum, '    private func performRefresh(generation: Int) async -> Bool {') \
    + method(forum, '    func clearSession() {') + r'''
}
@main struct Checks {
 @MainActor static func main() async {
  let server = FakeAuthServer(), queue = SerialAsyncGate()
  let account = AccountAuthStore(AuthSessionRefresher(server: server, app: "n"), queue)
  let forum = ForumAuthStore(AuthSessionRefresher(server: server, app: "f"), queue)
  forum.accountAuth = account

  // 小说与论坛同时续期：逐个执行，后者使用前者轮换后的 Cookie，两者都成功。
  async let novel = account.refreshSession()
  async let board = forum.refreshSession()
  let (n, f) = await (novel, board)
  precondition(n && f, "both sessions renew")
  precondition(server.maxActive == 1, "refreshes sharing one cookie never overlap")
  precondition(account.username == "alice" && forum.username == "alice" && account.tokenStore.clears == 0)

  // 同一会话重复调用：等待进行中的续期，只发一次请求。
  let before = server.requests.count
  async let first = account.refreshSession()
  async let second = account.refreshSession()
  let (a, b) = await (first, second)
  precondition(a && b && server.requests.count == before + 1, "a caller during renewal waits for the same result")
  precondition(!account.isRefreshing)

  // 排队期间退出登录：旧续期放弃，不写入令牌；之后的新调用重新续期。
  let blocker = Task { await forum.refreshSession() }
  await Task.yield()
  let queued = Task { await account.refreshSession() }
  await Task.yield()
  account.clearSession()
  let queuedResult = await queued.value
  precondition(!queuedResult && account.username == nil, "logout discards a queued renewal")
  _ = await blocker.value
  let renewed = await account.refreshSession()
  precondition(renewed && account.username == "alice", "a call after logout starts a new renewal")

  // 认证服务拒绝（401）时清除会话。
  server.rejectNext = true
  let rejected = await account.refreshSession()
  precondition(!rejected && account.username == nil && account.errorMessage != nil, "401 clears the session")
  print("Auth refresh queue passed: novel/forum renewals serialize on the rotating cookie, concurrent callers share one renewal, logout discards queued renewal, 401 clears the session")
 }
}
'''

with tempfile.TemporaryDirectory(prefix='novelia-auth-refresh-') as directory:
    folder = Path(directory)
    (folder / 'Checks.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'cache'),
                    str(folder / 'Checks.swift'), '-o', str(folder / 'checks')], check=True)
    subprocess.run([str(folder / 'checks')], check=True)
