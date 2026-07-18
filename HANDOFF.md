# SessionNotch — Laptop Handoff

The Studio build (this machine, Command Line Tools only) is done: the whole Swift
Core library, event server, hook client, and the menu-bar baseline app are built,
tested, and reviewed. What remains needs **full Xcode** and/or **both machines
running**, so it happens on the laptop.

## Status

| Piece | State |
|---|---|
| `SessionNotchCore` (Event, SessionRegistry, HTTP parser, Config/Secret/Tailscale, EventServer) | Done, 28 tests green |
| Bash hook client + `install-hooks.sh` + hook tests | Done, 6 cases + idempotency green |
| Menu-bar baseline app (status item, popover, notifier, server) + `make-app.sh` | Done, builds clean (`make-app.sh release` works) |
| Notch overlay (DynamicNotchKit) — **Task 7** | Not started (needs Xcode; code + steps in the plan) |
| GUI smoke test + cross-machine E2E — **Task 6 step 8, Task 9** | Not started (needs the running app + both machines) |

Branch: `feat/sessionnotch-v1`. Plan (all remaining steps, with code):
`docs/superpowers/plans/2026-07-18-sessionnotch.md`.

## Prerequisites on the laptop

- Full **Xcode** (not just Command Line Tools) — DynamicNotchKit's SwiftUI macros
  require it, and running a GUI app needs a window server.
- **Tailscale** up on both laptop and Studio (already the case).

## Step 1 — Get the repo onto the laptop

The repo currently lives only on the Studio (no git remote yet). Two options:

- **Rsync over the tailnet** (quickest, no remote):
  from the laptop, pull the Studio copy (exclude build artifacts):
  ```
  rsync -av --exclude .build --exclude build studio:Agent/SessionNotch/ ~/Agent/SessionNotch/
  ```
- **Or create a GitHub remote** on the Studio, push `feat/sessionnotch-v1`, and clone
  on the laptop. Preferable if you want the app version-controlled long-term.

## Step 2 — Build and run the menu-bar baseline (Task 6 smoke test)

On the laptop, in the repo root:
```
bash scripts/make-app.sh release
```
```
open build/SessionNotch.app
```
On first launch, grant notification permission. The menu bar shows `SN`. Then, from
another terminal, post a fake event and confirm the UI reacts:
```
SECRET=$(cat ~/.sessionnotch/secret)
```
```
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:47823/event -H "X-SessionNotch-Secret: $SECRET" --data '{"machine":"laptop","session_id":"demo","project":"smoke","cwd":"/tmp","event":"waiting_permission","message":"approve npm test","ts":"2026-07-18T18:00:00Z"}'
```
Expect `204`, the menu-bar title to become `SN 1`, a banner, and the row
`laptop - smoke` in the popover. Post again with `"event":"working"` and confirm it
clears. (The app auto-generates `~/.sessionnotch/secret` on first run.)

## Step 3 — Add the notch overlay (Task 7)

Follow **Task 7** in the plan. It re-adds the `DynamicNotchKit` package dependency to
the `SessionNotchApp` target (removed on the Studio because it can't compile under
CLT), then adds `NotchPresenter.swift` and wires it in `AppDelegate`. The plan's
Task 7 Step 1 has you read the resolved DynamicNotchKit source first to confirm its
exact `show`/`hide` API before wiring — do that; the `NotchPresenting` protocol
isolates any API drift to one file.

## Step 4 — Cross-machine install + end-to-end (Task 9)

Follow **Task 9** in the plan:
1. Install hooks on the laptop pointing at loopback:
   ```
   bash hooks/install-hooks.sh laptop "http://127.0.0.1:47823/event"
   ```
2. On the Studio, install hooks pointing at the laptop's MagicDNS name/Tailscale IP,
   and copy the **same** `~/.sessionnotch/secret` to the Studio (both machines must
   share it):
   ```
   bash ~/Agent/SessionNotch/hooks/install-hooks.sh studio "http://<laptop-magicdns-or-100.x>:47823/event"
   ```
3. Trigger a permission prompt in a laptop Claude Code session, then in a Studio
   session; confirm each lights up the app on the laptop within ~1s.
   Verify the hook event names against the installed Claude Code version first
   (`install-hooks.sh` backs up `~/.claude/settings.json` before editing).

## Post-merge follow-ups (from the final review — none blocking)

- Hook `ts` has 1-second resolution → same-second events sort nondeterministically.
- Malformed HTTP (bad request line / Content-Length) drops the connection with no
  400 response (only bad JSON returns 400). Cosmetic for the curl-only client.
- The "don't start without a non-empty secret" guard lives in `AppDelegate`, not in
  `EventServer` itself — move it into `EventServer` for defense-in-depth.
- `install-hooks.sh` `strip` assumes every existing hook entry has a string
  `.command`; harden with `.command // ""`.
- `config.json` carries a `port` field that nothing reads (app hardcodes 47823);
  either honor it in the app or drop it to avoid a silent host/port mismatch.
- v2 (from the design): `claude` wrapper for true crash detection; jump-to-session.
