# PRPeek

macOS menubar watcher for open GitHub PRs. Shows a color-coded "waiting on me"
count, notifies on review requests / CI failures, opens PRs in the browser.

## Build & run

```bash
swift test                       # 41 tests
bash Scripts/make-app.sh         # builds PRPeek.app (ad-hoc signed)
open PRPeek.app                  # menubar icon appears (top-right)
```

Sign in two ways:

### Option A — Paste a token (works immediately)
Menubar ▸ **Paste token…** → paste a PAT with `repo` + `read:org`
(fine-grained or classic). Done.

### Option B — Sign in with GitHub (device flow)
Requires a one-time OAuth App registration (the client id is public — device
flow needs no secret):

1. github.com ▸ **Settings ▸ Developer settings ▸ OAuth Apps ▸ New OAuth App**
2. Fill in:
   - Application name: `PRPeek`
   - Homepage URL: anything (e.g. `https://github.com/you/prpeek`)
   - Authorization callback URL: same as homepage (device flow ignores it, but the field is required)
3. **Register application**, then on the app page check **Enable Device Flow** and Save.
4. Copy the **Client ID** (looks like `Ov23li…`).
5. Rebuild with it baked in:
   ```bash
   PRPEEK_CLIENT_ID=Ov23li... bash Scripts/make-app.sh
   open PRPeek.app
   ```
6. Menubar ▸ **Sign in with GitHub** → the code is copied to your clipboard and
   the pre-filled GitHub page opens → click **Authorize**. The app polls and
   signs in automatically (watch the menu status row).

Scopes requested: `repo read:org`.

## Architecture
- `PRPeekCore` — all logic, fully unit-tested (`swift test`):
  `GitHubClient` (ETag/304/pagination/typed errors), `JSONStore` (atomic +
  schema recovery), `Auth` (device flow + Keychain), `SearchService`
  (`involves:@me` backbone), `Classifier` (waiting-on-me + CI), `RefreshEngine`
  (coalesced pass + concurrency cap), `NotificationPlanner` (edge-fire + dedup).
- `PRPeek` — AppKit menubar app: badge, menu, lifecycle (sleep/wake +
  NWPathMonitor), notifications.

## Deferred (v1.1+)
Approve/comment write-actions; pinned-repo `[All]` for repos you're not involved
in; live search box; Developer ID notarization + Homebrew cask.
