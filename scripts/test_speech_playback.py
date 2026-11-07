#!/usr/bin/env python3
"""用可控平台桩运行真实 App 播放代码；不发声、不访问网络，也不代替真机验收。"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    speech = ROOT / 'iOSApp/Features/Reader/Speech'
    # 保留真实控制器、两种引擎和远程会话；只排除 SwiftUI 视图，替换平台依赖。
    system = (speech / 'SystemSpeechEngine.swift').read_text().split('// MARK: - 各阅读器共用的朗读入口')[0]
    readium = (speech / 'ReadiumSpeechPlayback.swift').read_text().split('// MARK: - 朗读面板')[0]
    remote = (speech / 'SpeechRemoteSession.swift').read_text()
    core = [ROOT / p for p in [
        'Sources/NoveliaIOSCore/Domain/SpeechPlaybackContract.swift',
        'Sources/NoveliaIOSCore/Domain/CloudSpeechContract.swift',
        'Sources/NoveliaIOSCore/Features/Reader/CloudSpeechText.swift',
        'Sources/NoveliaIOSCore/Features/Reader/SpeechText.swift',
        'Sources/NoveliaIOSCore/Support/SpeechSettingsStore.swift',
        'Sources/NoveliaIOSCore/Support/SettingsKeys.swift',
    ]]
    fragments = [p.read_text() for p in core] + [system, readium, remote, (speech / 'EdgeSpeechEngine.swift').read_text(), (ROOT / 'iOSApp/App/Integrations/SpeechEngineFactory.swift').read_text()]
    actual = '\n'.join('\n'.join(line for line in s.splitlines() if not line.startswith('import ')) for s in fragments)
    fixture = (ROOT / 'scripts/fixtures/speech_playback_harness.swift').read_text()
    source = fixture.replace('// ACTUAL_PLAYBACK_SOURCES', actual)
    with tempfile.TemporaryDirectory(prefix='novelia-speech-tests-') as folder:
        folder = Path(folder)
        swift = folder / 'SpeechTests.swift'
        swift.write_text(source)
        binary = folder / 'SpeechTests'
        subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'), str(swift), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
    # UI 停止由阅读器宿主持有：退出时按引擎能力移交或停止（handOffOnExit），
    # 不把停止重新绑回会随顶栏隐藏的按钮；三个滚动/分页宿主仍保留文本规则变化的停止。
    accessory = (speech / 'SystemSpeechEngine.swift').read_text().split('// MARK: - 各阅读器共用的朗读入口')[1]
    assert '.onDisappear { handOffOnExit() }' in accessory and 'func handOffOnExit' in accessory
    for path in ['ReaderView.swift', 'TXTReaderView.swift', 'EPUBReader/EPUBReaderView.swift']:
        text = (ROOT / 'iOSApp/Features/Reader' / path).read_text()
        assert 'speech.stop()' in text, path
    # 跨页移交：存储随共用朗读入口放在宿主层，阅读器出现时回收遗留会话，Readium 视图同样接入。
    assert 'final class SpeechHandoffStore' in accessory and 'func adopt(' in accessory and 'func release()' in accessory
    assert 'speechHandoff?.release()' in accessory and 'speechHandoff?.adopt(' in accessory
    assert '.speechHandoff' in (ROOT / 'iOSApp/Features/Reader/EPUBReader/ReadiumEPUBReaderView.swift').read_text()
    assert 'controller.capabilities.contains(.readingFollow)' in (speech / 'ReadiumSpeechPlayback.swift').read_text()
    print('PASS: reader teardown and follow-control wiring guards')


if __name__ == '__main__':
    main()
