#!/usr/bin/env python3
"""用模拟认证存储测试实际的统一登录编排流程。"""
from pathlib import Path
import subprocess
import tempfile
s = Path('iOSApp/Features/Account/AccountAuth.swift').read_text()
def method(part, signature):
    start = part.index(signature)
    brace = part.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (part[end] == '{') - (part[end] == '}')
        end += 1
    return part[start:end] + "\n"
a = s.split('final class AccountAuthStore',1)[1].split('final class ForumAuthStore',1)[0]
f = s.split('final class ForumAuthStore',1)[1].split('enum NoveliaForumSessionTokenVault',1)[0]
code = '''import Foundation
@MainActor final class AccountAuthStore {
 var isRefreshing = false; var username: String?; var errorMessage: String?
 weak var forumAuth: ForumAuthStore?
 var nextUser = "alice"; var succeeds = true; var refreshes = 0; var clears = 0
 func refreshSession() async -> Bool { refreshes += 1; if succeeds { username = nextUser }; return succeeds }
 func clearSession() { clears += 1; username = nil }
''' + method(a,'func establishUnifiedSession()') + method(a,'func logout()') + '''
}
@MainActor final class ForumAuthStore {
 var isRefreshing = false; var username: String?; var errorMessage: String?
 weak var accountAuth: AccountAuthStore?
 var nextUser = "alice"; var succeeds = true; var refreshes = 0; var clears = 0
 func refreshSession() async -> Bool { refreshes += 1; if succeeds && nextUser == accountAuth?.username { username = nextUser; return true }; return false }
 func clearSession() { clears += 1; username = nil }
''' + method(f,'func establishUnifiedSession()') + method(f,'func logout()') + '''
}
@main struct Tests {
 @MainActor static func main() async {
  let account = AccountAuthStore(), forum = ForumAuthStore()
  account.forumAuth = forum; forum.accountAuth = account
  var result = await account.establishUnifiedSession()
  assert(result && account.username == "alice" && forum.username == "alice")
  forum.logout(); assert(account.username == nil && forum.username == nil)
  result = await forum.establishUnifiedSession()
  assert(result && account.username == forum.username)
  account.logout(); assert(account.username == nil && forum.username == nil)
  account.succeeds = false; let count = forum.refreshes
  result = await account.establishUnifiedSession(); assert(!result && forum.refreshes == count)
  account.succeeds = true; forum.username = "old-account"; let clears = forum.clears
  result = await account.establishUnifiedSession(); assert(result && forum.clears == clears + 1)
  forum.nextUser = "other-account"
  result = await account.establishUnifiedSession(); assert(!result && account.errorMessage != nil)
  print("Unified login passed: either entry establishes both sessions, unified logout, primary failure, stale-account clearing and mismatched identity rejection")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='novelia-unified-login-') as directory:
    root = Path(directory)
    (root/'Test.swift').write_text(code)
    subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(root/'cache'),str(root/'Test.swift'),'-o',str(root/'test')],check=True)
    subprocess.run([str(root/'test')],check=True)
