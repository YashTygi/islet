#!/bin/bash
# Dev tool: a silent "music player" that publishes Now Playing info (title, artist, artwork,
# 3-minute duration) and logs remote commands, so the media milestone can be tested without
# real audio. Usage: tools/fakeplayer.sh   (Ctrl-C or `pkill -x FakePlayer` to stop)
set -euo pipefail
cd "$(dirname "$0")"
OUT=../build/FakePlayer.app/Contents
mkdir -p "$OUT/MacOS"
cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.yashtyagi.FakePlayer</string>
<key>CFBundleName</key><string>FakePlayer</string>
<key>CFBundleExecutable</key><string>FakePlayer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -O -o "$OUT/MacOS/FakePlayer" - <<'SWIFT'
import AppKit
import AVFoundation
import MediaPlayer

let engine = AVAudioEngine()
let node = AVAudioPlayerNode()
let format = engine.outputNode.inputFormat(forBus: 0)
let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))!
silence.frameLength = silence.frameCapacity  // zero-filled = silent
engine.attach(node)
engine.connect(node, to: engine.mainMixerNode, format: format)
try! engine.start()
node.scheduleBuffer(silence, at: nil, options: .loops)

let art = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { r in
    NSGradient(colors: [.systemPink, .systemOrange])!.draw(in: r, angle: 45); return true
}
let duration = 180.0
var elapsed = 0.0, since = Date(), playing = false
let center = MPNowPlayingInfoCenter.default()

func publish() {
    center.nowPlayingInfo = [
        MPMediaItemPropertyTitle: "Fake Sunset Drive",
        MPMediaItemPropertyArtist: "MyNotch Test Band",
        MPMediaItemPropertyPlaybackDuration: duration,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
        MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        MPMediaItemPropertyArtwork: MPMediaItemArtwork(boundsSize: art.size) { _ in art },
    ]
    center.playbackState = playing ? .playing : .paused
}
func setPlaying(_ p: Bool) {
    if playing { elapsed += Date().timeIntervalSince(since) }
    since = Date(); playing = p
    p ? node.play() : node.pause()
    publish(); print(p ? "PLAY" : "PAUSE"); fflush(stdout)
}
let cc = MPRemoteCommandCenter.shared()
_ = cc.playCommand.addTarget { _ in setPlaying(true); return .success }
_ = cc.pauseCommand.addTarget { _ in setPlaying(false); return .success }
_ = cc.togglePlayPauseCommand.addTarget { _ in setPlaying(!playing); return .success }
_ = cc.nextTrackCommand.addTarget { _ in print("NEXT"); fflush(stdout); return .success }
_ = cc.previousTrackCommand.addTarget { _ in print("PREVIOUS"); fflush(stdout); return .success }
_ = cc.changePlaybackPositionCommand.addTarget { e in
    elapsed = (e as! MPChangePlaybackPositionCommandEvent).positionTime; since = Date()
    publish(); print("SEEK \(Int(elapsed))"); fflush(stdout); return .success
}
setPlaying(true)
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
SWIFT
codesign --force --sign - ../build/FakePlayer.app
exec ../build/FakePlayer.app/Contents/MacOS/FakePlayer
