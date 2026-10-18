#!/bin/bash
# Memory check: footprint before/after N hover expand/collapse cycles on the running MyNotch.
# Usage: ./soak.sh [cycles]   (moves the mouse cursor; restores it afterwards)
set -euo pipefail
P=$(pgrep -x MyNotch) || { echo "MyNotch not running (./build.sh run)"; exit 1; }
fp() { footprint -p "$P" | awk '/phys_footprint:/{print $2, $3}'; }
echo "before: $(fp)"
swift - "${1:-40}" <<'SWIFT' 2>/dev/null
import AppKit
let n = Int(CommandLine.arguments[1])!
let s = NSScreen.main!.frame
let notch = CGPoint(x: s.midX, y: 20), away = CGPoint(x: s.midX, y: s.height / 2)
let orig = CGEvent(source: nil)!.location
func move(_ p: CGPoint) { CGWarpMouseCursorPosition(p); CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
for _ in 0..<n { move(notch); usleep(50_000); move(CGPoint(x: notch.x + 1, y: notch.y)); usleep(700_000); move(away); usleep(800_000) }
move(orig)
SWIFT
sleep 2
echo "after:  $(fp)   (budget: idle <= 30 MB, no growth)"
