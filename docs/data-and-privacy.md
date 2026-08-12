# Data and privacy

A complete account of what the app stores, where, what it sends over the network, and what it
deliberately never touches.

- [Credentials](#credentials)
- [Files on disk](#files-on-disk)
- [Usage history](#usage-history)
- [Network](#network)
- [The Codex process boundary](#the-codex-process-boundary)
- [What it never does](#what-it-never-does)

---

## Credentials

**Session keys and API keys live in the macOS Keychain.** They are never written to disk in
plaintext.

macOS offers two Keychains, and the app probes the Security framework at runtime to decide which
it can actually use: the data-protection Keychain when the process carries a Keychain access
group, and the login Keychain otherwise. **Shipped releases currently land on the login
Keychain.** The data-protection path requires an embedded provisioning profile the release
signing chain doesn't yet have; it was attempted in 3.3.0 and withdrawn in 3.3.1 when it turned
out to prevent the app launching at all. The resolver decides by probing rather than by reading
its own entitlements, so nothing is migrated, moved, or deleted while that remains true.

**The credential store fails closed.** If the Keychain refuses a write:

- the credential is held in memory and works for the rest of the session
- nothing is written to disk
- the app tells you the credential is memory-only rather than degrading silently
- if secure storage never accepts it, it's gone at quit and you re-authenticate

Versions before 3.2.0 could park a session key in cleartext in the app's preferences file when
the Keychain was unavailable. That field is no longer written under any circumstance, and any
value an older version left behind is migrated into the Keychain and cleared on first read.

**Claude Code credentials** are read from the CLI's own Keychain item and its
`.credentials.json`, and written back only when you link or switch a profile. Attribute lookups
use the Security framework directly; the credential read itself goes through `/usr/bin/security`,
because the item's access control trusts that binary rather than this app.

---

## Files on disk

| Path | Contents | Secrets? |
|---|---|---|
| `~/Library/Application Support/Claude Usage/profile-data/<profile-uuid>/current-v1.json` | Latest usage snapshot for that profile | No |
| `~/Library/Application Support/Claude Usage/profile-data/<profile-uuid>/history-v1.json` | Usage history for that profile | No |
| `~/Library/Preferences/HamedElfayome.Claude-Usage.plist` | Every setting and preference | No |
| macOS Keychain | Session keys, API keys | Yes |
| `~/.claude-accounts/<name>/` | A Claude Code config directory, created only for profiles you explicitly link | Yes — the CLI's own |
| `~/.claude-tokens/.last-account` | Name of the active Claude account directory | No |
| `~/.claude-tokens/.last-codex-home` | Absolute path of the active Codex home | No |

The preferences file keeps the upstream project's bundle identifier (`HamedElfayome.Claude-Usage`)
so that upgrading from the original app preserves your settings.

Writes to the JSON stores are atomic — written to a temporary file, then renamed — with a `.bak`
alongside, because an interrupted write on a large history file is not hypothetical. Stale
fragments from interrupted writes are swept automatically, restricted to files this app owns.

Nothing outside these paths is written. The app does not edit your shell configuration, your
`settings.json`, or any Codex file.

---

## Usage history

History is recorded per profile and used for the charts and the JSON/CSV export. Each record type
is capped and pruned automatically, so history stays bounded without any attention from you —
roughly a week of session history and several weeks of weekly history are retained. The exact
caps live in `HistoryRetentionPolicy`.

### The one-time repair on upgrade

If you're upgrading from a version older than **3.3.6**, expect a one-time repair the first time
each profile writes history — roughly a second, once, per profile.

Earlier versions declared a "reset" whenever the provider's reset instant moved. Claude anchors
its session window to your first message, so that instant moves constantly without any reset
occurring, hundreds of times a day. Each false positive wrote a snapshot dated ahead of itself,
which every chart, view, and export then correctly filtered out — forever. On long-running
profiles those unreachable records reached roughly **97% of all stored history**, with files
growing past 20MB.

3.3.5 stopped new ones being written. 3.3.6 removes the ones already stored:

- Every removed record is **first copied to an archive file kept beside the history file**.
  Nothing is discarded outright.
- Only unreachable records are removed. Everything the app can display is preserved — the charts
  and exports are identical before and after.
- If archiving fails, nothing is removed and the repair simply retries on the next write.

You may notice history files shrinking substantially and an archive file appearing next to them.
That is the repair, and it runs once.

---

## Network

| Host | Why |
|---|---|
| `claude.ai` | Subscription usage for Claude profiles |
| `console.anthropic.com` | Anthropic Console usage, spend, and credits, if you configure it |
| `status.claude.com` | Claude service status shown in the popover |
| `github.com` | Update checks and downloads (Sparkle, over HTTPS with signature verification) |

All communication is HTTPS. Requests carry your credential to the provider that issued it and
nowhere else.

Refreshes are staggered across profiles rather than fired simultaneously, and back off
exponentially on rate limiting, honouring `Retry-After`. Polling pauses while the display is
asleep.

Settings → **Debug** offers a timed network capture with full request and response detail, if you
want to see exactly what's being sent.

---

## The Codex process boundary

Codex usage does not come from a network call this app makes. For each operation the app:

1. Resolves one absolute `codex` executable.
2. Starts a bounded `codex app-server` process against the linked `CODEX_HOME`.
3. Reads the response over that process's interface.
4. Terminates the process.

It never reads, parses, copies, uploads, or stores `CODEX_HOME/auth.json` or any Codex access
token. Authentication is entirely the Codex CLI's, using the state that home already holds.

See [Codex subscription support](codex-subscriptions.md) for what is and isn't reported.

---

## What it never does

- **No telemetry.** No analytics, no crash reporting, no usage statistics, no phone-home.
- **No cloud sync.** Everything stays on your machine.
- **No third-party services.** The only hosts contacted are the ones listed above.
- **No credential exfiltration.** Credentials go to the provider that issued them, over HTTPS,
  and nowhere else.
- **No account access beyond reading usage.** The app cannot send messages, spend credits, or
  redeem anything. Codex reset credits are display-only.

The app is open source under the MIT license — all of the above is verifiable in this
repository.
