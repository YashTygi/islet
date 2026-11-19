# Islet: context assistant plan

Goal: Islet goes from "buttons for the front app" to "understands what you're looking at and does the work",
with every risky step gated in the notch. Edge over Clicky: we send **facts** (project, URL, DOM element, AX element,
git, shell history), not only pixels, and we target UI by **native IDs**, not coordinates.

What already exists and gets reused:
- Accessibility permission + hotkey monitor (`Hotkey.swift`)
- Front-app detection, browser tab via AppleScript, Finder selection (`Context.swift`)
- Claude Code CLI calls (`GitPanel.swift`: `claude -p --model haiku`)
- `islet run` tracked tasks, `islet hook claude` receiving PreToolUse / Stop events (`IsletCLI/main.swift`)
- Port scanning and port → project mapping (`Dev.swift`, `projectPorts`)
- Shell history reader with secret filter (`TerminalPanel.swift`)

---

## Phase 1: Selected-text tools (no AI, offline)

Read the selection via `kAXSelectedTextAttribute` from the focused element; fall back to the clipboard.
Detect the type and show the top 3 actions in the notch, with "More…" for the rest.
Everything runs on the Mac: no network, no AI. ★ = build first.

**How it behaves**
- Opens with the hotkey while text is selected; if nothing is selected, uses the clipboard.
- Every result has **Copy** and, where the source field is editable, **Replace selection** (writes back via `AXSelectedText`,
  falls back to paste). Transforms like prettify or case change happen in place.
- Several detectors can match (a number is a timestamp *and* bytes): ranked by how specific the match is.
- Last 20 results kept in a small history, click to copy again.

### Data and encoding
| Detected | Actions |
|---|---|
| ★ JWT | Header + payload, `exp` / `iat` in local time, "expired 3 h ago" |
| ★ JSON | Prettify / minify, validate with error line, sort keys, JSON → Swift `Codable` / TS type / Zod / Go struct |
| YAML / TOML / plist | ↔ JSON |
| ★ base64 / base64url | Decode (text, or image preview if it's image data) / encode |
| URL-encoded, HTML entities, `é` escapes | Decode / encode |
| Query string / URL | Parameters as a table, strip tracking params |
| `Cookie:` / HTTP headers block | As a readable table |
| CSV / TSV | → Markdown table; Markdown table → CSV |
| `KEY=value` lines (.env) | → JSON, → `export` lines, values masked in the preview |
| Markdown | Copy as rich text (for Slack / email); HTML → Markdown |

### Time
| Detected | Actions |
|---|---|
| ★ Unix timestamp (s / ms / µs) | Local, UTC, relative ("in 2 days") |
| ISO 8601 / RFC 2822 date | → Unix, other time zones, relative |
| ★ Cron expression | Plain English + next 5 run times |
| Durations (`86400000`, `PT1H30M`) | Human readable |

### Numbers and system values
| Detected | Actions |
|---|---|
| Hex / binary / octal number | All bases |
| Byte counts | KB / MB / GB (both 1000 and 1024) |
| `755` / `rwxr-xr-x` | Convert, explain who can do what |
| IP / CIDR (`10.0.0.0/22`) | Range, host count, private or public |
| ★ HTTP status code | Name + one-line meaning |
| Exit code / signal (`137`, `SIGKILL`) | Meaning ("137 = killed, often out of memory") |
| `OSStatus` / `errno` / `NSError` code | Name + meaning (local tables) |
| Semver range (`^1.2.0`) | Which versions match |
| Maths expression (`1024*3/8`) | Result |
| `px` / `rem` / `pt` | Convert (16 px base, editable) |

### IDs and hashes
| Detected | Actions |
|---|---|
| UUID | Version; creation time for v1 / v7; generate new |
| ULID, MongoDB ObjectId, Snowflake ID | Creation time |
| Hash (32 / 40 / 64 hex) | Likely type (MD5 / SHA-1 / SHA-256) |
| Any text | Hash it (MD5 / SHA-1 / SHA-256), generate UUID |

### Code and text
| Detected | Actions |
|---|---|
| ★ Identifier | camelCase / snake_case / kebab-case / PascalCase / CONSTANT_CASE |
| Any text | Escape as JSON / Swift / shell string; sort, dedupe, trim lines; count lines / words / chars |
| ★ curl command | → `fetch` / `URLSession` / axios / HTTPie |
| `fetch(...)` call | → curl |
| ★ Regex | Test against clipboard text with matches highlighted, plain-English breakdown |
| SQL | Format |
| Two clipboard items | Diff them |

### Developer references
| Detected | Actions |
|---|---|
| ★ File path / `file:line:col` | Open in VS Code at line, reveal in Finder, copy relative path |
| ★ Stack trace | Every frame clickable to open in VS Code (project frames first) |
| ★ Git SHA / branch / `#123` / `owner/repo` | Open on GitHub, `git show`, checkout branch (in a visible terminal) |
| npm / Swift / Homebrew package name | Open package page, installed version in front project |
| ★ Port number (`:3000`) | What's listening, open in browser, stop it |
| PID | Process name, stop it |
| Docker container ID / name | Logs, stop, shell into it (visible terminal) |
| URL | Clean, QR, open in other browser, `curl -I` headers |

### Colour
| Detected | Actions |
|---|---|
| ★ Hex / rgb / hsl / oklch | Convert between them, SwiftUI / Tailwind / CSS code, nearest Tailwind class |
| Two colours | WCAG contrast ratio, AA / AAA pass or fail |

### Safety
| Detected | Actions |
|---|---|
| ★ Secret (AWS `AKIA…`, GitHub `ghp_…`, Stripe `sk_live_…`, Anthropic `sk-ant-…`, private key block) | Warning in the notch, key type, link to that provider's rotate page. Never stored in history. |

Size: v1 (★ rows) is small–medium. One `detectors` table: each row is a match function and its actions.
One self-test with a sample string per row. ponytail ceiling: regex-based detection, no parser libraries;
add a real parser only where a row keeps misfiring.

## Phase 2: Page-aware buttons

- **GitHub PR**: CI checks (`gh pr checks`), review state, "Checkout + run tests", "Ask about this diff".
- **GitHub / Linear / Jira issue**: "Create branch" (`feat/ABC-123-short-title`), "Start agent on this ticket".
- **Docs page** (MDN, Apple, framework docs): "Ask about this page" with page text attached.
- **Figma**: picked colour as SwiftUI / Tailwind.

Size: small–medium. Extends the existing browser panel.

## Phase 3: Shell hook (shared foundation for 4 and 5)

One line in `~/.zshrc`, added from Settings: `eval "$(islet shell-init zsh)"`.
`preexec` / `precmd` send `{command, cwd, exit code, duration, terminal app, time}` to Islet.
Islet stores them in a local log (`~/Library/Application Support/Islet/commands.jsonl`, capped).
Skips space-prefixed commands (matches your `histignorespace`) and secret-looking lines.

Why needed: `~/.zsh_history` has timestamps but **no folder and no exit code**.

## Phase 4: Command recall ("I ran something like this earlier")

Hotkey → "the command that rebuilt the icon set" → top 3 matches with folder and date → Copy / Paste into terminal / Run.

Sources, searched together:
1. Islet command log (Phase 3): command + folder + exit code. Best source going forward.
2. `~/.zsh_history` (1,892 lines today): everything from the past.
3. **Claude Code transcripts** (`~/.claude/projects/*/*.jsonl`): every Bash command your agents ran. Many "I ran it once" commands live here, not in shell history.
4. **Clipboard history**: Islet watches `NSPasteboard.changeCount` and keeps recent text that looks like a command.
   Skips password-manager items (`org.nspasteboard.ConcealedType`). Only captures from the day it's turned on: macOS has no public API for past clipboard.
5. Project files: `package.json` scripts, `Makefile` targets, README code blocks, `*.sh` in `~/Developer`.
6. Open Terminal / iTerm scrollback via AppleScript.

Search: local fuzzy filter down to ~200 candidates (no network), then Haiku picks the best 3 and says why.
Secrets filtered before anything leaves the machine.

## Phase 5: Failed-command catcher

Uses the Phase 3 hook. Exit code ≠ 0 (ignoring 130 = Ctrl-C) → short notch pulse: **Explain · Fix with agent · Copy error**.
Error output: the hook can't see stdout, so Islet reads the last ~80 lines of the tab via AppleScript
(Terminal, iTerm). Ghostty / Warp: command + exit code only.
Also triggers on a selected stack trace (Phase 1).

## Phase 6: Ask Islet + "fix this on localhost"

Hold hotkey → notch opens a prompt (typing in v1; voice later via on-device `SpeechAnalyzer`, no API key).
Islet builds a **context bundle**:

- App, window title, selected text, focused AX element
- Browser: URL, title; on localhost: port → project folder, window screenshot
- **Element under cursor** (Chrome JS via AppleScript: `elementFromPoint`): CSS selector, outerHTML snippet,
  computed box/styles. Needs Chrome's "Allow JavaScript from Apple Events" (one-time toggle).
  With a dev locator plugin (e.g. LocatorJS / react-dev-inspector) we also get the **component's file:line**.
- Project: branch, `git diff --stat`, last failed command + output

Example: on `localhost:3000`, hover the broken card, hotkey, "this card overflows on narrow widths".
Islet opens Claude Code in that project's folder (visible Terminal) with the bundle + screenshot,
the agent shows in the Agents tab, and on Stop the notch says "Done: reload?" and reloads the tab.

## Phase 7: Native UI targeting (no pixels)

Instead of screenshot coordinates, read the front app's **Accessibility tree**: role, title, `AXIdentifier`,
description, frame. Send a compact tree to Claude; it answers with an element ID; Islet then
**highlights** it (exact outline in an overlay, like Clicky's pointing but survives resizing),
**presses** it (`AXPress`) or **sets its value** (`AXValue`).

Works well: native AppKit/SwiftUI apps, System Settings, Finder, Xcode, most menus.
Partial: Electron / browsers (web content exposed, IDs often missing; use DOM path in Chrome instead).
Doesn't work: canvas apps (Figma canvas, games). Fall back to screenshot there.

Delivered as an MCP server inside the Islet CLI (`islet mcp`) with tools `ax_tree`, `ax_press`, `ax_set_value`,
`highlight`, so any Claude Code session can use it too.

## Phase 8: Task automation with permissions

"Run my Mac cleanup script, dry run first" → Islet finds `~/Developer/.../mac-cleanup.sh`, then:

1. Plan card in the notch: steps it intends to run.
2. **Dry run** in a visible Terminal via `islet run` (`--dry-run` / `-n` if the script supports it; detected from
   its source or `--help`). If it has no dry-run mode, Islet says so and shows the script instead.
3. Notch: "Dry run finished. Would delete 214 files (6.1 GB). Proceed?" **Proceed · Show output · Cancel**.
4. Real run, again visible, result in the notch.

Permission system (enforced by Islet in the `PreToolUse` hook, not by asking the model to behave):

| Tier | Examples | Rule |
|---|---|---|
| Read | ls, cat, git status, ax_tree | Auto |
| Write in project | edit files, git commit | Ask once per task |
| Destructive / system | rm, kill, scripts not run before, git push --force, ax_press in other apps | Ask **every time**, exact command shown, dry run first when possible |
| Never | typing passwords, sudo prompts, deleting outside home | Blocked; user does it |

The existing `islet hook claude` becomes blocking for PreToolUse: it waits for the notch answer and returns
`permissionDecision: allow | deny`. Every action is appended to an audit log.

---

## Phase 9: AI chat watcher (Claude desktop + Claude, ChatGPT, Gemini on the web)

Today "Needs you" only works for Claude Code, because its hooks tell Islet. Chat apps and websites have no hooks,
so Islet watches their UI instead and feeds the **same agent rows, chimes and badges** you already have.

**States**

| State | How it shows on screen | Notch |
|---|---|---|
| Generating | Stop button visible ("Stop response", `stop-button`) | Running row |
| Needs you | Approval buttons ("Allow once", "Always allow", "Approve", "Confirm"), a question card, file picker, sign-in or rate-limit banner | Orange row + chime |
| Done | Stop button gone after generating, tab not in front | Green row + chime |
| Error | "Something went wrong", "Network error", usage-limit banner | Red row |

Only the state and the chat title are read. Message text is never read or stored.
Notifies only when that chat isn't the one in front. Click a row: Islet brings that window and tab forward.

**Where it reads from**

1. **Websites in Chrome / Brave** (claude.ai, chatgpt.com, gemini.google.com): one AppleScript call per poll
   lists matching tabs in every window and runs a tiny script in each (`execute javascript`). The first call
   installs a `MutationObserver` that writes the state to `window.__islet`; later polls only read that value,
   so each poll is cheap. Background tabs work.
   Needs Chrome's **View → Developer → Allow JavaScript from Apple Events** (Islet shows a one-click guide).
   Poll every 2 s, and only while a matching tab exists.
2. **Safari**: same idea with `do JavaScript`; needs **Develop → Allow JavaScript from Apple Events**.
3. **Claude desktop (chat) and ChatGPT desktop**: Accessibility tree, in-process, no extra permission.
   Electron apps hide web content from Accessibility until asked: set `AXManualAccessibility = true` on the
   Claude app, then look for the same buttons by their accessible name. Claude desktop's Code tab is already
   covered by hooks, so matches there are skipped (no double rows).
   Not for browsers: forcing Chrome's full accessibility tree slows it down and makes window resizing laggy.

**Later: browser extension** (replaces 1 and 2). Content script on the three sites, same observer, sends the
state to the `islet` CLI as a Chrome native-messaging host. Push instead of polling, no Developer toggle,
also works in Arc / Edge. Safari needs a Safari Web Extension built into Islet.app.

**Keeping it working when sites change**
- Match buttons by accessible name and visible text, not CSS class names (classes change every deploy).
- Selectors live in a small JSON file inside Islet (`chat-watchers.json`): per site, the text for each state.
  A site redesign means editing that file, not Swift code.
- If a site stops matching anything for a day, the Settings row says "ChatGPT watcher needs an update".

Size: medium. v1 = Chrome + Claude desktop. Then Safari, then the extension.

## Order

1. Phase 1 (quick win)
2. Phase 9 chat watcher v1 (reuses agent rows, standalone)
3. Phase 3 hook → Phase 4 recall → Phase 5 catcher (one foundation, three features)
4. Phase 2 page buttons
5. Phase 6 Ask Islet + localhost fix
6. Phase 8 permissions + automation (needed before anything acts on its own)
7. Phase 7 native UI targeting (uses Phase 8 gate)

## Open questions

- Localhost fix: interactive Claude in Terminal (you watch, approve there) or headless with approvals in the notch?
- Clipboard history: on by default or opt-in?
- Voice in v1, or typing first?
- Command recall: local-only search option for people who don't want history sent to Claude?
- Chat watcher: also watch Perplexity / Copilot, or only Claude, ChatGPT, Gemini?
