# Codex subscription support

RevvyTach can monitor Claude and Codex profiles side by side. Codex
profiles use the official Codex app-server interface and the authentication
state already owned by a linked `CODEX_HOME`.

## Prerequisites and supported accounts

- macOS 14 or later.
- The official `codex` executable must be installed, executable, and available
  through `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`.
- Codex must support its `app-server` interface.
- Usage monitoring requires a ChatGPT subscription account exposed by Codex.

API-key, Amazon Bedrock, unknown provider-hosted, and accounts that do not
expose an OpenAI/ChatGPT subscription are reported as unsupported. OpenAI
Platform API billing, organization spend, invoices, and prepaid API credits
are not part of Codex subscription support.

## Link a Codex home

During first run, choose **Codex**, select the existing home directory used by
Codex, and choose **Verify Home**. To add another account later:

1. Open **Settings → Manage Profiles**.
2. Create a Codex profile and choose its existing `CODEX_HOME`.
3. Open **Provider Account**, verify the home, and refresh account status.
4. If the home is signed out, use browser or device-code sign-in.

The link is specific to the physical directory. If that directory is moved,
replaced, or restored as a different filesystem object, relink it before
refreshing. Symlink aliases and duplicate links to the same physical home are
rejected to prevent two profiles from silently controlling one account.

Multiple Codex homes are supported: create one profile per distinct home and
activate the profile you want to view. Claude profiles continue to use their
existing credential and Claude Code integration paths.

## What is displayed

The app shows the data Codex makes available for the linked subscription:

- Account and plan status.
- One or more rate-limit windows and their reset times.
- Available read-only credit balances, including rate-limit reset-credit
  counts when supplied by Codex.
- Provider-reported summary metrics and daily token buckets.
- Local usage history and JSON/CSV export.

Reset credits are display-only. RevvyTach cannot redeem, consume,
or modify them. Missing optional fields are shown as unavailable rather than
inferred. Codex API Platform billing is intentionally excluded.

## Privacy and process boundary

RevvyTach never reads, parses, copies, uploads, or stores
`CODEX_HOME/auth.json` or any Codex access token. For each operation it:

1. Resolves one absolute `codex` executable.
2. Starts a bounded `codex app-server` process with the linked home.
3. Requests only account, rate-limit, usage, health, or interactive-login
   operations.
4. Closes the request-scoped process.

The app stores only its profile association, provider-neutral usage snapshots,
history, and settings in its own local storage. It has no telemetry or cloud
sync. Signing out of Codex remains a Codex operation.

## Unlink or reset

Choose **Settings → Provider Account → Unlink** to remove the app's association
with that home. Unlinking does not delete the directory, change its files,
revoke credentials, or log Codex out.

Deleting a Codex profile removes that profile's app-owned settings, current
usage snapshot, and local history. It does not modify the linked home. To start
again without deleting the profile, unlink it and link the desired home.

## Troubleshooting

### Codex executable not found

Run `command -v codex` in a terminal. If Codex is installed in another
location, ensure the GUI app receives an absolute `PATH` entry or install it in
one of the supported fallback locations. Relative and empty `PATH` entries are
ignored.

### Home unavailable or changed

Confirm that the linked directory still exists and is readable. If it was
moved, replaced, restored, or mounted differently, use **Relink** and select
the current directory.

### Sign-in required

Open **Provider Account** and choose browser or device-code sign-in. The login
is performed by Codex. If sign-in succeeds but usage remains unsupported,
confirm that Codex is using a ChatGPT subscription rather than API-key or
provider-hosted authentication.

### Refresh or app-server error

Update Codex, verify that `codex app-server` starts, and retry **Refresh**. The
app applies bounded startup, request, output, and shutdown limits; a stalled or
malformed process is stopped and reported without exposing raw credentials or
protocol bodies.

### Data differs from OpenAI Platform billing

This feature tracks the ChatGPT subscription usage Codex reports. It does not
read OpenAI Platform billing or API organization data, so those values are not
expected to match.
