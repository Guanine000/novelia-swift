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
    # UI 停止由阅读器宿主持有，不能重新放回可隐藏的工具栏按钮。
    accessory = (speech / 'SystemSpeechEngine.swift').read_text().split('// MARK: - 各阅读器共用的朗读入口')[1]
    assert '.onDisappear' not in accessory
    for path in ['ReaderView.swift', 'TXTReaderView.swift', 'EPUBReader/EPUBReaderView.swift']:
        text = (ROOT / 'iOSApp/Features/Reader' / path).read_text()
        assert 'speech.stop()' in text, path
    assert 'controller.capabilities.contains(.readingFollow)' in (speech / 'ReadiumSpeechPlayback.swift').read_text()
    print('PASS: reader teardown and follow-control wiring guards')


if __name__ == '__main__':
    main()
