# Multi-account and CLI switching

How to run several Claude and Codex accounts side by side, and how to make your terminal follow
whichever one you activate.

- [The model](#the-model)
- [Claude Code accounts](#claude-code-accounts)
- [Codex homes](#codex-homes)
- [Shell setup](#shell-setup)
- [Keeping accounts consistent](#keeping-accounts-consistent)
- [Troubleshooting](#troubleshooting)

---

## The model

Each account you track is a **profile**, and every profile belongs to one provider — Claude or
Codex. You can have as many of each as you want.

**One Claude profile and one Codex profile are active at the same time.** They are independent
slots. Activating a Claude profile never touches Codex credentials, environment, or CLI state,
and vice versa.

**Viewing is not activating.** Clicking any account in the popover shows you its usage without
switching to it. Activation is only ever the explicit **Make Active** button. This matters
because checking whether another account has headroom is something you do all the time, and it
must not move your CLI out from under a session that's mid-task.

Activating a profile does the following, depending on what that profile has linked:

1. Selects its credentials for usage fetching.
2. Points the CLI at its config directory or home, if one is linked.
3. Propagates that change to running `tmux` sessions.

---

## Claude Code accounts

Claude Code reads its configuration from `CLAUDE_CONFIG_DIR`, defaulting to `~/.claude`. The app
gives each linked profile its own directory under `~/.claude-accounts/` and switches between
them.

### Linking

Settings → **CLI Account** → **Link Account**.

The app creates `~/.claude-accounts/<name>/` for the active profile and shows you the `claude`
login command to run against it. Log in there, and the profile now owns its own credentials
independent of `~/.claude`.

An existing directory for that name is reused rather than replaced, so relinking a profile you
previously unlinked picks up the login it already had.

### What activation writes

Activating a linked Claude profile:

- writes the directory name to `~/.claude-tokens/.last-account`
- runs `tmux set-environment -g CLAUDE_CONFIG_DIR …` so existing tmux sessions follow

New shells pick it up from the rc snippet below.

### Syncing from an existing login

If you'd rather keep using your system login, **Sync from Claude Code** copies the currently
logged-in account's credentials into the profile. Credentials are re-read immediately before a
profile switch so a fresh `claude login` isn't missed.

### Unlinking

Unlinking removes the account directory and clears `.last-account` if it pointed there. The
credentials in that directory go with it, so log in again after relinking.

---

## Codex homes

Codex reads its configuration from `CODEX_HOME`, defaulting to `~/.codex`. Unlike Claude Code,
the app does **not** create these — you link homes that already exist and are already signed in.

### Linking

Settings → **Provider Account** → choose the home directory → **Verify Home**.

The field prefills `~/.codex` when it exists and isn't already linked to another profile.

**The link is to a physical directory, not a path string.** The app records the directory's
filesystem identity, so a home that gets moved, replaced, or restored as a different object is
detected as changed and must be relinked rather than silently tracking the wrong thing. Symlink
aliases and two profiles pointing at the same physical home are both rejected — otherwise two
profiles would be quietly driving one account.

### What activation writes

Activating a linked Codex profile:

- writes the absolute home path to `~/.claude-tokens/.last-codex-home`
- runs `tmux set-environment -g CODEX_HOME …`

If the linked directory no longer exists, activation clears the pointer rather than leaving your
terminals on the previous profile's home. A stale pointer left by an earlier version is
discarded at startup.

### What the app never does

It never reads, parses, copies, uploads, or stores `CODEX_HOME/auth.json` or any Codex token.
Authentication and usage reads go through a bounded `codex app-server` process. See
[Codex subscription support](codex-subscriptions.md) for the full process boundary.

---

## Shell setup

The pointer files above are how a **new** shell learns which account to use. Existing tmux
sessions are updated directly; anything else needs one snippet in your shell rc.

Settings shows the snippet for your detected shell with a copy button, and labels it **Optional**
or **Required** based on your actual configuration. You do not need it when:

- you have a single Claude Code account, or
- you have a single Codex home and it is Codex's own `~/.codex` default.

In those cases the snippet resolves to what your shell already does. It becomes **Required** the
moment you link a second home, or move your single home outside `~/.codex`.

**zsh / bash** — `~/.zshrc`, or `~/.bashrc` / `~/.bash_profile`:

```bash
# Claude CLI account auto-switch (one-time setup, applies to all accounts)
if [ -f ~/.claude-tokens/.last-account ]; then
  export CLAUDE_CONFIG_DIR="$HOME/.claude-accounts/$(cat ~/.claude-tokens/.last-account)"
fi

# Codex CLI home auto-switch (one-time setup, applies to all profiles)
if [ -f ~/.claude-tokens/.last-codex-home ]; then
  export CODEX_HOME="$(cat ~/.claude-tokens/.last-codex-home)"
fi
```

**fish** — `~/.config/fish/config.fish`:

```fish
# Claude CLI account auto-switch (one-time setup, applies to all accounts)
if test -f ~/.claude-tokens/.last-account
    set -gx CLAUDE_CONFIG_DIR "$HOME/.claude-accounts/"(cat ~/.claude-tokens/.last-account)
end

# Codex CLI home auto-switch (one-time setup, applies to all profiles)
if test -f ~/.claude-tokens/.last-codex-home
    set -gx CODEX_HOME (cat ~/.claude-tokens/.last-codex-home)
end
```

Add it once. It applies to every account, and nothing needs changing when you add more.

**The app never edits your shell configuration files.** The snippet is display-and-copy only.

---

## Keeping accounts consistent

Separate config directories mean anything you add to one account doesn't exist in the others.
Both syncs live in Settings → **CLI Account**.

### MCP servers

`claude mcp add` writes into the *active* account's `.claude.json`, so an MCP server added under
one account is missing under every other one.

The sync performs a bidirectional merge:

1. Collects `mcpServers` from `~/.claude.json` and every linked account's `.claude.json`.
2. Builds the union.
3. Writes back only the entries a given source is missing.

Existing per-account configuration is never overwritten — the sync only adds. Project-scoped MCP
servers are unaffected.

**Auto-sync is on by default** and runs on every profile switch, so adding an MCP server to any
account propagates to all of them. **Sync MCP Servers Now** runs it on demand and reports
exactly which servers went to which accounts.

> **Trust model.** Because the merge is bidirectional, configuration from any linked account can
> reach every other account and `~/.claude.json`. If you need strict isolation, turn off
> auto-sync and sync manually and selectively.

### Skills

Every account directory already has `skills/` pointing at `~/.claude/skills/`, so keeping that
one directory current keeps every account current.

The sync links entries from a source directory into `~/.claude/skills/`, then ensures each
account directory's symlink is present and not stale. Choose the source directory in the same
screen. If you don't set one, it falls back to `~/dotfiles/.claude/skills` when that path exists,
and otherwise does nothing.

Skills sync runs alongside MCP sync — from the same button, and on the same auto-sync-on-switch
path.

---

## Troubleshooting

**`codex` fails with "CODEX_HOME points to … but that path does not exist".**
The linked home was deleted, unmounted, or moved. Relink it in Provider Account. Current
versions clear a stale pointer at startup and re-validate before writing one, so this should
self-correct on the next launch.

**Switching profiles logged me out of Claude Code.**
Fixed in 3.3.7. The credential write no longer deletes the existing login before rewriting it,
so a refused Keychain write can no longer leave you with no login at all. Update, then
`claude login` once to restore.

**A new terminal is on the wrong account.**
The rc snippet isn't installed, or is installed in a file your shell doesn't read for that
invocation — on macOS, bash login shells read `~/.bash_profile`, not `~/.bashrc`. Check
`echo $CLAUDE_CONFIG_DIR` and compare against `cat ~/.claude-tokens/.last-account`.

**A tmux pane is on the wrong account.**
`tmux set-environment -g` updates the global environment for *new* panes. Existing panes keep
the environment they were created with; open a new one.

**Two profiles claim the same Codex home.**
Rejected by design. One physical home means one profile — otherwise both would be driving the
same account with no way to tell them apart. Unlink one.
