#!/bin/bash
# Dev tool: performs a real file drag onto the notch and drops it at a point in the nook.
# Usage: tools/dragtest.sh FILE DROP_X DROP_Y   (screen points, top-left origin)
# Moves the mouse; restores it afterwards.
set -euo pipefail
FILE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
swift - "$FILE" "$2" "$3" <<'SWIFT' 2>/dev/null
import AppKit

let file = URL(fileURLWithPath: CommandLine.arguments[1])
let drop = CGPoint(x: Double(CommandLine.arguments[2])!, y: Double(CommandLine.arguments[3])!)

final class Source: NSView, NSDraggingSource {
    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: file.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        print("drag ended, operation=\(operation.rawValue)"); exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!.frame
let win = NSWindow(contentRect: NSRect(x: 100, y: screen.height - 400, width: 120, height: 120),
                   styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = Source()
win.level = .floating
win.orderFrontRegardless()

let start = CGPoint(x: 160, y: 340)  // window centre, top-left coords
let orig = CGEvent(source: nil)!.location
func post(_ t: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
DispatchQueue.global().async {
    usleep(500_000)
    CGWarpMouseCursorPosition(start); post(.mouseMoved, start); usleep(100_000)
    post(.leftMouseDown, start); usleep(100_000)
    func glide(_ a: CGPoint, _ b: CGPoint, steps: Int) {
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); usleep(16_000)
        }
    }
    let notch = CGPoint(x: screen.midX, y: 15)
    glide(start, notch, steps: 40); usleep(500_000)   // hover over the notch: it should open
    glide(notch, drop, steps: 20); usleep(500_000)
    post(.leftMouseUp, drop); usleep(800_000)
    CGWarpMouseCursorPosition(orig)
    usleep(3_000_000); print("timeout"); exit(1)
}
app.run()
SWIFT
