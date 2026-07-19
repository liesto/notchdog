# notchdog

A native macOS app that shows every Claude Code session — on the laptop **or** the Studio — that currently needs your attention, presented in the **notch**. Claude Code hooks push events over the tailnet to an embedded HTTP server inside the app; a pure in-memory registry turns them into the current "who needs me" state.

## What it looks like

- **Idle:** just the notch — nothing added.
- **Alert:** a black island drops from the notch, centered, growing left/right and downward as needed. Content sits just below the physical camera cutout so it's never occluded. One line per session: a colored dot + `machine · project` (yellow = waiting/idle, red = error). A single **×** clears all. Alerts clear automatically when the session goes back to work.

## Build & run

Requires the Swift toolchain (Command Line Tools is enough — the app has no Xcode-only dependencies).

```
bash scripts/make-app.sh release
```
```
open build/SessionNotch.app
```

The app auto-generates a shared secret at `~/.sessionnotch/secret` on first launch and listens on port **47823**.

## Wire up Claude Code hooks

On each machine that runs Claude Code, point its hooks at the machine running the app. On the machine running the app use loopback; on the other, use the app machine's Tailscale address, and share the **same** `~/.sessionnotch/secret` between them.

App machine (e.g. the laptop):
```
bash hooks/install-hooks.sh laptop "http://127.0.0.1:47823/event"
```
Other machine (e.g. the Studio, pointing at the laptop over the tailnet):
```
bash hooks/install-hooks.sh studio "http://<app-machine-tailscale-ip>:47823/event"
```

Hooks wired: `Notification` (permission / idle), `Stop` (finished), `UserPromptSubmit` + `PreToolUse` (working → clears), `SessionEnd` (error / removed). `install-hooks.sh` backs up `~/.claude/settings.json` first and is idempotent.

## Auto-start on login

A LaunchAgent at `~/Library/LaunchAgents/com.buildabonfire.sessionnotch.plist` (RunAtLoad) launches the app at login.

## Layout

- `Sources/SessionNotchCore/` — pure library: `Event`, `SessionRegistry`, `HTTPRequest` parser, `Config`/`Secret`/`TailscaleIP`, `EventServer` (Network framework). Zero external dependencies.
- `Sources/SessionNotchApp/` — the AppKit/SwiftUI app: notch panel, status item, notifier, server wiring.
- `Sources/SessionNotchTests/` — executable test harness (`swift run SessionNotchTests`; 28 tests). This machine is Command-Line-Tools-only, so XCTest isn't available — see `docs/superpowers/plans/2026-07-18-sessionnotch.md`.
- `hooks/` — bash Claude Code hook client + `install-hooks.sh`.
- `docs/superpowers/` — design spec and implementation plan.

## Tests

```
swift run SessionNotchTests
```
```
bash tests/hooks/run.sh
```
