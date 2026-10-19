# Islet — complete feature list

Built from a full read of `Sources/Islet` and `Sources/IsletCLI`. Grouped by area.

## 1. The notch itself

- Black panel pinned to the top-centre of every screen; seamless with the hardware notch.
- Screens without a notch get a fake 190 pt pill sized to the menu bar.
- One panel per display; rebuilds automatically when displays change.
- Collapsed panel is exactly notch-sized, so the rest of the menu bar stays clickable.
- **Hover to open**: 150 ms dwell before opening, 250 ms grace before closing.
- Expands to 680 × 220 with a spring animation; concave "ears" + rounded bottom shape.
- Hides itself over full-screen apps; visible on all Spaces.
- Non-activating: clicking buttons doesn't steal focus from your app (Spotlight-style).
- Stays open while you type in a text field inside it.
- **Lock open** with double-tap Control (lock icon shown); closes on outside click or another double-Control.
- Double-Control opens on the screen your pointer is on and unlocks the others.
- Optional haptic tap on open (Force Touch trackpad).
- Frees memory back to macOS every time it collapses.
- "Added to Shelf" toast and "Merging…/Making PDF…" working capsule inside the open notch.

## 2. Tabs (top-left strip)

| Tab | Icon | Notes |
|---|---|---|
| Home | house | Always on |
| This App | wand | Only appears when the front app has actions |
| Agents & Tasks | sparkles | Orange badge = agents waiting |
| Dev | `</>` | |
| File Shelf | tray | Blue badge = item count; icon bounces when something lands |
| Camera | camera | Off by default; turn on in Control panel → Notch |

- Sliding highlight capsule; pages slide in from the direction you move.
- Each tab (except Home) can be hidden in settings.
- Optional: auto-open on the App tab when the front app has actions.

## 3. Top-right strip

- Mic/camera-in-use indicators + one-click **All Mute** button.
- Coffee-cup icon while keeping the Mac awake.
- Lock icon while locked open.
- Timer chip (shows countdown when running).
- Gear button → control panel.

## 4. Keyboard shortcuts

**Global**
- `⌃ ⌃` (double-tap Control alone, each press ≤ 0.3 s, ≤ 0.4 s apart) — open/close notch locked with keyboard focus. Ctrl+other key or Shift+Control cancels it.

**Inside the open notch** (locked, or while the pointer is over it after hover-opening)
- `⌘1` … `⌘6` — jump to tab N (only the tabs currently visible)
- `←` / `→` — previous / next tab
- `⌘,` — control panel
- `⌘T` — timer panel; then `1`–`6` = 1/3/5/10/25/45 min, `F` = Focus (Pomodoro), `X` = cancel
- `Space` — play / pause
- `⌘←` / `⌘→` — previous / next track
- `M` — mute / unmute microphone system-wide
- `J` — jump to the agent that needs you
- `⌘/` or `?` — show shortcut cheat sheet
- `Esc` — close innermost (timer panel → help → unlock). In hover mode Esc passes through to your app unless a panel is open.
- `Esc` inside a text field hands keyboard back to your app.

**Onboarding window**: `Return` = Continue, `Esc` = Back.

## 5. Collapsed-notch live activities ("pill")

Wings appear left/right of the notch. Priority (highest wins):

1. Agent needs you (✋ bounce, count) — click pill to jump to its window
2. Mic / camera in use (iPhone-style green/orange dots; red when muted) — click pill to toggle All Mute
3. Public tunnel LIVE (always shown, safety reminder)
4. Short alerts: battery, Bluetooth, timer done, task done, agent done/error, transfer done, "shelved"
5. File job working (Merging…)
6. Running `islet run` task (elapsed clock, count)
7. Download / AirDrop progress (%)
8. Timer / focus / break countdown
9. Agents running (count)
10. Meeting soon (10 min before → 5 min after start, minutes countdown)
11. Now playing (artwork + animated bars in album accent colour)

Each kind can be switched off in settings. Event-driven (no polling).

## 6. Home tab cards (reorderable, toggleable)

- **Now Playing**: artwork with source-app badge (click opens app), title/artist, animated bars, draggable scrubber with elapsed/remaining, prev / play-pause / next.
- **Next Meeting**: title, calendar colour, start time, "in X min" (turns orange ≤ 5 min), one-click **Join** for Zoom / Google Meet / Teams / Webex links found in URL, location or notes.
- **Claude Usage**: tokens in current 5-hour window, output tokens, message count, progress bar (time elapsed, or quota if you set a token budget — red above 85%), "resets in".

## 7. Media

- Works with any Now Playing source via bundled MediaRemote adapter.
- Play/pause, next, previous, seek.
- Album-art accent colour drives bars and scrubber.
- Helper auto-restarts with backoff; killed if it exceeds 50 MB.

## 8. Timer & Pomodoro

- Presets 1, 3, 5, 10, 25, 45 min.
- Focus mode 25/5, long 15-min break after every 4 focus sessions, auto-rolls focus ↔ break.
- Progress ring with "Focus N" / "Break" label; Cancel.
- Chime + pill when done ("Done" / "Break" / "Focus").

## 9. File Shelf (tray) & drag-and-drop

- Drag files toward the notch: it opens early (within 250 pt below / 300 pt either side) to avoid Mission Control.
- Drop zones: **Add to Tray**, **AirDrop**, and **Merge into <PDF>** when Preview has a PDF open.
- Shelf stores bookmarks, not copies (no disk cost, follows renames/moves, missing files dropped).
- Persists across restarts.
- Tile: hover ✕ to remove, double-click to open, drag out to any app.
- Right-click: Open, Show in Finder, AirDrop, Remove from Tray.
- Header: AirDrop all, Clear tray.
- AirDrop with result pill (success/failure).
- Optional: finished downloads land on the shelf automatically.

## 10. Agents & Tasks tab

**Agents column**
- Every Claude Code / Codex / custom agent: Running, Needs you, Done, Error.
- Shows name · project, last message, relative time.
- Click row → jump to the app that ran it (Terminal, iTerm, VS Code, Cursor…).
- Dismiss finished rows; "Clear" all finished.
- Sorted needs-you → running → error → done; stale rows expire after 30 min; cap 40.
- Sounds: Funk (needs you), Glass (done), Basso (error).

**Tasks column**
- Live downloads / AirDrop with progress bars.
- Running `islet run` tasks with live elapsed time.
- Last 15 finished tasks (persisted) with exit code + duration; Clear.
- Click row → jump to host app.

## 11. Keep-awake

- Holds a display-sleep assertion while any agent is running/waiting or any task runs; released automatically.

## 12. This App tab — context actions per front app

**VS Code / Cursor (git panel)**
- Detects project (active file → git root, or window title → common dev folders / Spotlight).
- Branch, ↑ahead / ↓behind, changed count / clean.
- "main ↓N · update" menu: rebase onto or merge base branch.
- Background `git fetch` at most every 2 min.
- **Commit**: AI-written Conventional Commit message via Claude Code CLI (Haiku, low effort, no tools), editable, Stage all toggle, copy message.
- **Stash dashboard**: stash changes (incl. untracked), list with file count/age, expand to see files, Apply / Pop / Drop.
- **Undo commit** (soft reset) with confirm; warns if already pushed.
- **Git guide**: 21 recipes (Undo, Stash, Sync, Merge, Branch, Look) filled in with your branch/main/last SHA, copy button, destructive ones flagged.
- Open Terminal in project.
- **Test** button: auto-detects npm/pnpm/bun/swift/cargo/pytest/go test, runs as a tracked task.
- Last commit line.
- This project's listening ports: open in browser, stop.
- Badge with this project's agents/tasks → jumps to Agents tab.

**Chrome / Brave / Safari**
- Current tab URL + title.
- localhost → LAN URL for your phone (copy) + QR code.
- **Share publicly**: tunnel via Cloudflare (`cloudflared`) or localhost.run over ssh; copy link, Stop, QR switches to public link, 20 s timeout, stops on quit.
- Window size presets: iPhone, iPad, Laptop, Desktop.
- Clean link (strips utm_*, fbclid, gclid…), Markdown link, QR to phone.
- Open in another installed browser; open in Private/Incognito (non-Safari).
- GitHub repo: copy clone cmd, Clone in VS Code. PR: copy `gh pr checkout`, copy "#N title". Issue: copy as task checklist line, copy "#N title".
- Google Meet: mute/unmute, camera on/off.
- Notion: copy page link, new page, search.
- Active downloads with progress.
- Built but switched off (`Browser.shelfActions` / `tabActions`): window screenshot → shelf, .webloc link file → shelf, all tabs → Markdown, close duplicate tabs.

**Terminal / iTerm / Ghostty / Warp**
- Running `islet run` tasks with Stop (Ctrl-C, then SIGTERM).
- Finished tasks: click to copy command, Re-run in original folder.
- Last 15 distinct shell-history commands (zsh/bash), click to copy; secret-looking lines hidden.

**Finder** (only with a real window open)
- Shows selection or current folder.
- Open Terminal here, Copy path, Copy relative path (to git root or ~).
- Images → PDF (one or many).

**Preview — images**
- Info: size, bytes, dpi, colour profile, palette swatches (click to copy hex).
- Convert to JPG / PNG / HEIC / WebP / TIFF / PDF.
- Resize: 50%, 1080p, 720p, app Icon set, Custom W × H.
- Compress with quality slider + live size estimate; Under 1 MB / Under 500 KB.

**Preview — PDFs**
- Info: pages, bytes, A4/Letter/size, has text / scanned / locked.
- Export pages as PNG/JPG at 72/150/300 dpi.
- Copy all text; save as .txt or Markdown.
- Extract page ranges ("2-5, 9"), split every page.
- Merge with file picker, or drag files onto the notch.
- Add password / remove password (password via stdin, never stored).
- All outputs saved next to the original (never overwrite), added to the Shelf, Finder revealed, Reveal/Open buttons.

**Figma**
- Screen eyedropper → hex copied; history of last 12 colours, click to copy.

**Claude desktop**
- Usage card + all agents & recent tasks.

**Any other app**
- Your own custom buttons (title + shell command, run in login shell as a tracked task).

## 13. Dev tab

- Listening TCP ports (system daemons hidden): open in browser, kill (confirm; SIGTERM then SIGKILL).
- Your open GitHub PRs (via `gh`): CI status icon, approved / changes requested; click to open.
- Not set up yet? The tab shows **Set up GitHub** (installs `gh` via Homebrew, or opens GitHub's installer) and then **Sign in to GitHub** (browser sign-in; the token stays in the Keychain).
- Refreshes only while visible (ports 3 s, PRs 60 s; 3 s while setting up).

## 14. Camera tab

- Off by default (opt-in in Control panel → Notch → Tabs).

- Mirror preview (720p, 24 fps) — runs only while tab is visible.
- **Ring light**: soft glow around screen edges, intensity and warmth sliders, click-through.

## 15. System events

- Battery: pill on plug/unplug, low-battery warning at ≤ 20%.
- Bluetooth connect/disconnect pill with device-specific icon (AirPods / Pro / Max, mouse, trackpad, keyboard, headphones).
- Calendar: next 24 h, non-all-day, refreshes on change + every 30 min.
- Mic/camera usage across all apps via CoreAudio/CoreMediaIO listeners.

## 16. `islet` CLI

- `islet run <cmd…>` — run anything, show in notch, chime at end, Stop/re-run from notch; output stays in your terminal; exit code passed through.
- `islet agent <running|waiting|done|error|ended> [--name] [--project] [--id] [--message]` — report from any tool.
- `islet hook claude` — Claude Code hook (SessionStart, UserPromptSubmit, Pre/PostToolUse → running; Notification → needs you; Stop → done; SessionEnd → ended).
- `islet hook codex <json>` — Codex `notify` program.
- `islet settings` — open control panel.
- `islet usage` — print current Claude 5 h window as JSON.
- `islet media …` — qr, info, convert, resize, compress, target, images-pdf, pdf-images, pdf-text, pdf-extract, pdf-split, pdf-merge, pdf-encrypt, pdf-decrypt.
- Detects host app (Terminal, VS Code…) so the notch can jump back to it.
- Never blocks if Islet isn't running.

## 17. Control panel (settings window)

- **General**: Open at login, sounds, haptics, keep awake, auto-shelf downloads, double-Control hotkey, Accessibility status + open settings, full shortcut list, live memory footprint.
- **Notch**: show/hide tabs, open-to-App-tab, Home cards on/off + reorder, toggle each live-activity kind.
- **App Actions**: list/delete/add custom per-app buttons (pick running app, title, shell command).
- **Agents**: install/remove Claude Code hooks (backs up settings.json), install `islet` command (no admin; ~/.local/bin, Homebrew, /usr/local/bin or ~/.zshrc PATH), Codex config snippet, token budget for usage meter.
- **About**: version, privacy note, "Show setup again".
- Opened by gear, `⌘,`, `islet settings`, or re-launching the app.

## 18. Onboarding (first run)

1. Welcome + tips
2. Move to Applications and relaunch
3. Permissions: Accessibility, Calendar (others asked on first use)
4. Connect Claude Code hooks + install `islet` command
5. GitHub (optional): install `gh`, sign in in the browser; ticks itself off when done
6. Open at login toggle

## 19. Privacy, performance & housekeeping

- Everything local, no accounts, no analytics.
- Hotkey reads only Control key state.
- Heavy work (image/PDF, QR, usage log scan, AppleScript) runs in separate helper processes to keep Islet's memory small.
- Event-driven everywhere; per-tab work only while visible.
- Tunnel/helper cleanup on quit and stale-tunnel cleanup on launch; SIGTERM = clean quit.
- One-time migration from old "MyNotch" settings/data.
- Debug logging with `ISLET_DEBUG=1`; self-tests with `ISLET_SELFTEST=1`; dev hooks `ISLET_TEST_*`, `ISLET_ONBOARDING`, `ISLET_CLAUDE_DIR`.
