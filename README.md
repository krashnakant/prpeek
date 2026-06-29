# PRPeek

A native macOS menubar app that watches your open GitHub pull requests — across
your personal repos **and** every org you're in — and tells you, at a glance,
which ones are **waiting on you**.

![CI](https://github.com/krashnakant/prpeek/actions/workflows/ci.yml/badge.svg)
&nbsp;macOS 26 (Tahoe)+ · Swift 6 · MIT

PRs scatter across tabs and orgs. PRPeek puts a single color-coded count in your
menu bar: red with a number when something needs your review or your CI is red,
calm when you're at inbox zero. No browser tab-hopping.

> Prior art, honestly: [Trailer](https://github.com/ptsochantaris/trailer) covers
> this category and is excellent. PRPeek is smaller and opinionated — it makes
> "waiting on me" the headline, not a setting.

## Features

- **Glanceable menubar badge** — a red pill with the count of PRs waiting on you;
  monochrome count when none; checkmark at inbox zero.
- **Three views** — `Needs me` (review requested of you, or your PR with failing
  CI), `Mine` (you authored), `Others` (involved but neither).
- **Precise "waiting on me"** — excludes drafts, honors live review requests
  (incl. team requests via your team memberships), and your own PRs with a failed
  required/any check. The badge doesn't lie.
- **Native notifications** — fires only on the transition (review requested, your
  CI fails), deduped, no storm on launch. Click → opens the PR.
- **Two ways to sign in** — paste a PAT, or OAuth device flow (no client secret).
  Token stored in the Keychain.
- **Cheap polling** — one GitHub Search query (`involves:@me`) covers all repos
  with zero enumeration; ETag conditional requests make idle polls nearly free;
  a concurrency cap keeps the per-PR checks fan-out under the secondary rate limit.
- **Laptop-aware** — pauses on sleep, refreshes once on wake (no backlog burst),
  holds when offline and shows cached PRs, backs off when rate-limited.
- **Instant launch** — last PRs restored from an atomic JSON cache before the
  first poll returns.

## How it works

Logic lives in a fully-tested `PRPeekCore` library; the AppKit shell is thin.

```
 GitHub REST API
        ▲  │ ETag / 304 (idle polls ~free)
        │  ▼
 GitHubClient (actor) ──► SearchService  is:pr is:open involves:@me
   token in Keychain          │
        ▲                     ▼
        │            RefreshEngine ──► per-PR enrich (detail + check-runs)
        │              (one coalesced     │  concurrency-capped
        │               pass)             ▼
        │                         Classifier → waiting-on-me + CI rollup
        │                                 │
   JSONStore (atomic cache) ◄── persist ──┤
                                          ▼
                       @MainActor AppModel  ──►  NotificationPlanner (edge-fire)
                            │  (state + epoch guard + backoff)
              ┌─────────────┼──────────────┐
              ▼             ▼               ▼
        menubar badge   dropdown menu   macOS notifications
        (NSImage)       (3 sections)

 LifecycleMonitor: NSWorkspace sleep/wake + NWPathMonitor → drives the poll loop
```

Key design decisions (full record in `CONTRIBUTING.md` + the design doc):
- **Search backbone, not an org crawler.** `involves:@me` returns your PRs across
  everything the token sees — no per-repo/org enumeration.
- **Codable JSON file, not SwiftData.** Avoids the actor/`ModelContext` threading
  trap for a small dataset; schema-versioned with corrupt-file recovery.
- **Account-scoped correctness.** The ETag cache flushes on token change and an
  epoch guard discards in-flight refreshes after sign-out, so no data leaks across
  accounts.

## Install

**From a release:** download `PRPeek.dmg` from
[Releases](https://github.com/krashnakant/prpeek/releases), drag to Applications.
The DMG is ad-hoc signed (not notarized) — Gatekeeper blocks first launch.
Two ways past it:

- **Right-click ▸ Open** on `PRPeek.app`, then **Open** in the dialog (once).
- Or strip the quarantine flag from a terminal:
  ```bash
  xattr -dr com.apple.quarantine /Applications/PRPeek.app
  ```

Notarization (Developer ID, friction-free install) needs a paid Apple Developer
account — skipped until download volume justifies it.

**From source:**
```bash
git clone https://github.com/krashnakant/prpeek.git
cd prpeek
bash Scripts/make-app.sh && open PRPeek.app
```

Requires macOS 26 (Tahoe)+ and Xcode 26+.

## Usage

Click the menubar icon → sign in:
- **Paste token…** — a GitHub PAT (classic with `repo` + `read:org`, or a
  fine-grained token with PR read + org read). Works immediately.
- **Sign in with GitHub** — register an OAuth App (Settings ▸ Developer settings,
  enable Device Flow), then build with `PRPEEK_CLIENT_ID=<id>`. Device flow copies
  a code and opens the pre-filled GitHub page.

The badge turns red with your "needs me" count; click any PR to open it.

## Roadmap

- Approve / comment actions from the menu (with confirm) — v1.1
- Pinned-repo `[All]` coverage for repos you're not involved in — v1.1
- Notarized DMG (Developer ID) for friction-free install
- Live filter/search box in the dropdown

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). `swift test` must stay green; CI runs it
on every PR.

## License

MIT — see [LICENSE](LICENSE).
