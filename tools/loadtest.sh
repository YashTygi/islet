#!/bin/bash
# Load test: pushes every Islet subsystem far past normal use and reports memory, CPU and disk.
# Usage: tools/loadtest.sh   (moves the mouse during hover phases; restores it)
set -uo pipefail
cd "$(dirname "$0")/.."
S=$(mktemp -d)
N=build/Islet.app/Contents/Helpers/islet

# Synthetic Claude logs: 60 MB, mostly huge tool-output lines plus 3000 assistant usage lines.
mkdir -p "$S/claude/p1"
python3 -I - "$S/claude/p1/s.jsonl" <<'PY'
import json, sys, datetime, random
now = datetime.datetime.now(datetime.timezone.utc)
with open(sys.argv[1], "w") as f:
    for i in range(3000):
        ts = (now - datetime.timedelta(seconds=(3000 - i) * 3)).isoformat().replace("+00:00", "Z")
        f.write(json.dumps({"type": "user", "timestamp": ts, "message": {"content": "x" * random.randint(2000, 30000)}}) + "\n")
        f.write(json.dumps({"type": "assistant", "timestamp": ts, "requestId": f"req_{i}",
            "message": {"id": f"msg_{i}", "content": [{"type": "text", "text": "y" * 4000}],
                        "usage": {"input_tokens": 10, "output_tokens": 500, "cache_read_input_tokens": 20000, "cache_creation_input_tokens": 1000}}}) + "\n")
    f.write(json.dumps({"type": "user", "timestamp": ts, "message": {"content": "z" * 12_000_000}}) + "\n")  # 12 MB single line
PY

pkill -x Islet; sleep 0.5
open --env ISLET_CLAUDE_DIR="$S/claude" build/Islet.app
sleep 3
P=$(pgrep -x Islet)

stat() {  # footprint now/peak, cumulative CPU seconds, disk bytes written
  local fp; fp=$(footprint -p "$P" 2>/dev/null | awk '/phys_footprint:/{n=$2$3} /peak/{p=$2$3} END{print n" "p}')
  local cpu; cpu=$(ps -o time= -p "$P" | awk -F'[:.]' '{print $1*60+$2"."$3}')
  local disk; disk=$(python3 -I -c "
import ctypes,sys
class R(ctypes.Structure): _fields_=[('u',ctypes.c_uint8*16)]+[(f'f{i}',ctypes.c_uint64) for i in range(40)]
lib=ctypes.CDLL('/usr/lib/libproc.dylib'); r=R()
print(r.f17 if lib.proc_pid_rusage(int(sys.argv[1]),2,ctypes.byref(r))==0 else 0)" "$P")
  echo "$fp $cpu $disk"
}
phase() {  # phase NAME COMMAND...
  local name=$1; shift
  read -r n0 p0 c0 d0 <<<"$(stat)"; local t0; t0=$(python3 -c 'import time;print(time.time())')
  "$@" >/dev/null 2>&1
  read -r n1 p1 c1 d1 <<<"$(stat)"; local t1; t1=$(python3 -c 'import time;print(time.time())')
  python3 -I -c "
c=float('$c1')-float('$c0'); w=float('$t1')-float('$t0'); d=(int('$d1')-int('$d0'))/1024
print(f'%-34s now %-6s peak %-6s cpu %5.2fs over %5.1fs (%4.1f%%)  disk +%.0f KB' % ('$name','$n1','$p1',c,w,100*c/max(w,0.1),d))"
}
idle() { sleep "$1"; }
hover() { ./soak.sh "$1"; }
hold() { swift - "$1" <<'SW'   # keep the pointer on the notch so the open nook (App tab polling) runs
import AppKit
let secs = Double(CommandLine.arguments[1])!
let s = NSScreen.main!.frame, o = CGEvent(source: nil)!.location
func move(_ p: CGPoint) { CGWarpMouseCursorPosition(p); CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
move(CGPoint(x: s.midX, y: 20)); usleep(50_000); move(CGPoint(x: s.midX + 1, y: 20)); usleep(500_000)
move(CGPoint(x: s.midX + 20, y: 120))   // inside the open nook
Thread.sleep(forTimeInterval: secs)
move(CGPoint(x: s.midX, y: s.height / 2)); usleep(800_000); move(o)
SW
}
agents() { for i in $(seq 1 "$1"); do $N agent "$(echo running waiting done error | tr ' ' '\n' | sed -n "$((i % 4 + 1))p")" --id "a$((i % 120))" --name "Agent $((i % 120))" --project "proj$((i % 30))" --message "msg $i"; done; }
tasks() { for i in $(seq 1 "$1"); do $N run sleep 1 & done; wait; }
downloads() { swift - "$1" <<'SW'
import Foundation
let n = Int(CommandLine.arguments[1])!
let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
let ps = (0..<n).map { i -> Progress in
    let p = Progress(totalUnitCount: 100); p.kind = .file; p.fileOperationKind = .downloading
    p.fileURL = dir.appendingPathComponent("loadtest-\(i).bin"); p.publish(); return p }
for step in 1...20 { for p in ps { p.completedUnitCount = Int64(step * 5) }; Thread.sleep(forTimeInterval: 0.25) }
ps.forEach { $0.unpublish() }; Thread.sleep(forTimeInterval: 1)
SW
}

echo "Islet load test — $(sysctl -n hw.model), $(($(sysctl -n hw.memsize) / 1073741824)) GB"
phase "idle 20s (fresh)"                  idle 20
phase "hover 30 cycles + 60MB usage scan" hover 30
phase "agent storm: 1200 events/120 ids"  agents 1200
phase "task storm: 60 parallel islet run" tasks 60
phase "download storm: 40 concurrent"     downloads 40
phase "hover 30 cycles (all tabs data)"   hover 30
phase "hold open 60s (App tab polling)"   hold 60
phase "idle 60s (settle)"                 idle 60
rm -rf "$S"
