# SessionNotch — Design

**Date:** 2026-07-18
**Status:** Approved (design), pending implementation plan
**Location:** `~/Agent/SessionNotch/`

## Problem

I run Claude Code across many projects, but on two machines: I physically sit at the
**laptop** (VS Code) while Claude Code actually runs on the **Studio** over Remote-SSH.
Sessions frequently stall waiting on me — a permission prompt, a question, a finished
turn — and I have no single glanceable place that tells me *which* session on *which*
machine needs me right now. Vibe Island solves the glance problem but only for a single
Mac; it can't see sessions running on a different machine.

## Goal

A native macOS notch/floating-bar app on the laptop that shows, in one place, every
Claude Code session — on the laptop **or** the Studio — that currently needs my
attention, and posts a banner when a new one flips to "needs me."

## Non-goals (v1)

- Watching non–Claude Code tools (Codex, Gemini CLI, plain terminals).
- Jumping to / focusing the exact terminal or VS Code window. VS Code integrated
  terminals over Remote-SSH don't expose a reliable focus API; v1 only tells me the
  machine + project so I know where to look.
- Persistent history / event log. This is a live board, not a ledger.
- True nonzero-exit crash detection via a `claude` wrapper (see Error detection).

## Environment (givens)

- Laptop ↔ Studio are joined by **Tailscale** (stable MagicDNS names; raw IP
  `100.90.12.34` seen previously — use MagicDNS, not the raw IP).
- Both machines run Claude Code with `~/.claude/settings.json` hooks.
- Existing `~/Agent/relay-linear/` kit is the reference pattern for a `private/`
  secret file (mode 600, uncommitted) and launchd/state conventions.

## Architecture — push over tailnet

```
 STUDIO (Claude runs here)            LAPTOP (I sit here)
 ┌─────────────────────────┐         ┌──────────────────────────────┐
 │ Claude Code             │         │  Claude Code                 │
 │  └ hooks ──POST──┐      │         │   └ hooks ──POST──┐          │
 └──────────────────┼──────┘         │                   ▼          │
                     │  tailnet       │   ┌──────────────────────┐   │
                     └──POST─────────────▶│  SessionNotch.app    │   │
   (studio posts to                   │   │  • EventServer       │   │
    laptop.<tailnet>.ts.net)          │   │  • SessionRegistry   │   │
                                      │   │  • Notch UI + banners│   │
                                      │   └──────────────────────┘   │
                                      └──────────────────────────────┘
```

Each machine's Claude Code hooks fire an event and `POST` it to the app's embedded
HTTP server. The laptop's hooks post to `http://127.0.0.1:<port>`; the Studio's hooks
post to `http://laptop.<tailnet>.ts.net:<port>`. The app is the single source of truth
for current attention state. Fire-and-forget: if the app is down the event is lost,
which is acceptable for a live board (mitigated by the fallback state file, below).

**Port:** `47823` (non-default, per port-hygiene rules — not a common dev port).

## Components

Each is independently understandable and testable.

### 1. Hook scripts (bash)
One small script per hook type, installed on **both** machines and wired into
`~/.claude/settings.json`. Each script:
- Reads Claude Code's hook payload JSON from stdin.
- Extracts `session_id`, `cwd`, `transcript_path`, and (for Notification/SessionEnd)
  the message/reason.
- Derives `project` from `cwd` (basename, or matched against `~/Agent/*`).
- Reads `machine` + endpoint URL + shared secret from a local config file.
- Builds the event JSON and `POST`s it with an `X-SessionNotch-Secret` header,
  short timeout, failure ignored (`curl --max-time 2 || true`).
- Writes the machine's current per-session state to a fallback file
  (`~/.sessionnotch/state.json`) so a restarted app can request a re-sync.

Classification of `Notification` events (permission vs idle) is done by matching the
message text Claude Code provides (e.g. contains "permission" / "waiting for your
input"); the raw message is always forwarded so the app can re-classify if needed.

### 2. EventServer (Swift)
A minimal embedded HTTP server (`Swifter` SPM package, or raw `Network` framework if
we want zero deps). Responsibilities:
- Bind to loopback **and** the Tailscale interface only (never `0.0.0.0` on a public
  interface).
- Require a valid `X-SessionNotch-Secret` header; reject otherwise.
- Accept `POST /event` (single event) and `GET /health`.
- Decode + validate the event, hand it to `SessionRegistry`.

### 3. SessionRegistry (Swift, pure model — no I/O)
The heart of the app; gets the bulk of unit tests.
- Holds a map keyed by `{machine, session_id}` → `Session`.
- `apply(_ event:)` transitions the session's state per the lifecycle table below.
- Exposes `sessionsNeedingAttention` (sorted) as observable state for the UI.
- Expires sessions with no event for `staleAfter` (default 15 min).
- Emits a signal when a session **newly** enters an attention state (drives the
  Notifier — no repeat banners for the same standing state).

### 4. Notch UI (SwiftUI + AppKit)
- `DynamicNotchKit` (SPM) for the notch/floating-pill presentation on macOS 14+.
- Collapsed: a badge with the count of sessions needing attention.
- Expanded: one row per waiting session — machine glyph, project name, state
  (color-coded), and age ("3m").
- Bound to `SessionRegistry` via `ObservableObject`.

### 5. Notifier (Swift)
- `UserNotifications` banner when the registry signals a new attention event.
- Text: `<machine> · <project> — <what it wants>`.

### 6. Menu / control (AppKit)
- `NSStatusItem` for Quit, Open settings, and showing the listen address for
  copying into the Studio hook config.

## Event model

```json
{
  "machine": "studio",
  "session_id": "abc123",
  "project": "usms-event-results",
  "cwd": "/Users/workhorse/Agent/USMS/Event Results",
  "event": "waiting_permission",
  "message": "Claude needs your permission to run: npm test",
  "ts": "2026-07-18T17:05:22Z"
}
```

`event` ∈ `waiting_permission | idle | done | working | error | session_end`.

## Event lifecycle

| Claude Code hook            | Emitted `event`       | Resulting state       | Attention? |
|-----------------------------|-----------------------|-----------------------|------------|
| `Notification` (perm text)  | `waiting_permission`  | waiting-permission 🔴 | yes        |
| `Notification` (idle text)  | `idle`                | idle-input 🟡         | yes        |
| `Stop`                      | `done`                | done 🔵               | yes        |
| `UserPromptSubmit`          | `working`             | working               | no (clears)|
| `SessionEnd` (abnormal reason)| `error`             | error 🔴              | yes        |
| `SessionEnd` (normal)       | `session_end`         | removed               | no         |
| (no events for staleAfter)  | —                     | expired → removed     | no         |

Attention states: waiting-permission, idle-input, done, error. A session clears when
I submit a prompt (`UserPromptSubmit`), the session ends normally, or it goes stale.

## Error detection (v1 decision)

Claude Code has **no dedicated crash hook**. v1 detects errors only via the
`SessionEnd` hook's `reason` field (covers many abnormal exits). True nonzero-exit
detection would require wrapping the `claude` binary in a shell function — explicitly
**deferred to v2**.

## Config & secrets

- `~/.sessionnotch/config.json` on each machine: `{ machine, endpoint, port }`.
- `~/.sessionnotch/secret` (mode 600, **never committed**): the shared secret. Same
  discipline as `relay-linear/private/`.
- The app generates the secret on first run and displays the value + Studio endpoint
  in the status-item menu for one-time copy into the Studio's config.

## Testing strategy

- **SessionRegistry** — XCTest unit tests over the full lifecycle table: each
  transition, attention computation, dedup of banner signals, staleness expiry. No I/O.
- **EventServer** — integration test: `POST` fixture events via `curl`/URLSession,
  assert registry state; assert secret rejection and interface binding.
- **Hook scripts** — feed recorded Claude Code hook JSON fixtures on stdin, assert the
  emitted event JSON and that a missing/unreachable endpoint fails soft.
- **Manual E2E** — run a real Claude Code session on each machine, trigger a permission
  prompt, confirm the notch lights up and a banner fires.

## Build / project conventions

- New local git repo at `~/Agent/SessionNotch/`; author email
  `jbw@buildabonfire.com` (personal). No remote yet.
- `PROJECT.json`: group `Personal`, stage `building`, native macOS (no frontend/backend
  ports; the `47823` listener is internal, documented here not in the port registry).
- `private/` git-ignored for the secret; `.gitignore` from the start.

## Open questions (none blocking)

- Exact `DynamicNotchKit` API surface / macOS version floor — pin during planning.
- Whether to ship `Swifter` as a dep or use raw `Network` — decide in the plan based on
  how much HTTP surface we need (currently just two routes → `Network` may suffice).
