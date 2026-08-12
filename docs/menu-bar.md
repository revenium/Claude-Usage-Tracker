# Menu bar behaviour

What the app puts in your menu bar, how it behaves when you're tracking more accounts than fit,
and how it interacts with menu bar managers.

- [Display modes](#display-modes)
- [Icon styles and appearance](#icon-styles-and-appearance)
- [When accounts don't fit](#when-accounts-dont-fit)
- [Menu bar managers](#menu-bar-managers)
- [Arrangement across restarts](#arrangement-across-restarts)
- [Troubleshooting](#troubleshooting)

---

## Display modes

Settings → **Manage Profiles** → display mode.

| Mode | Behaviour |
|---|---|
| **Single** | One item, showing the active profile |
| **Multi** | One item per selected profile, all visible at once |

In multi mode each profile carries its own icon style, color mode, and refresh interval, and
clicking any item opens that profile's usage. Clicking never changes which profile is active —
see [viewing vs. activating](multi-account-cli.md#the-model).

An item can also show more than one metric at a time — session, weekly, and API usage as
separate icons.

---

## Icon styles and appearance

Five styles, set per profile in Settings → **Appearance**:

| Style | |
|---|---|
| **Battery** | Classic battery indicator with fill |
| **Progress Bar** | Horizontal bar with percentage |
| **Percentage** | Text only |
| **Icon with Bar** | Claude icon plus progress |
| **Compact** | Space-efficient |

Three color modes: **Multi-Color** (threshold-based), **Greyscale** (follows system appearance),
and **Single Color** (a hex value you choose).

**Pace markers** put a colored marker on progress bars showing whether you're on track to
exhaust the window before it resets, across six tiers from comfortable to runaway.

**Percentage direction** toggles between "75% used" and "25% remaining". Color coding follows
the meaning, not the number.

**Provider badges** — two independent toggles, both off by default — distinguish Claude from
Codex at a glance: a monochrome provider glyph drawn to the left of the item, and a muted
provider-colored background tint. They composite onto every icon style.

---

## When accounts don't fit

Past a certain number of profiles, the menu bar runs out of room — and macOS gives items no
warning before it starts truncating them. The app collapses extras into a single `+N` item with
its own popover.

Settings → **Manage Profiles** → overflow mode:

| Mode | Behaviour |
|---|---|
| **Automatic** (default) | Collapse only when there is genuinely no room |
| **Never** | Always show every profile, whatever the consequences |
| **After N** | Collapse past a fixed count, default 4 |

Automatic mode measures free space against the display the status items are actually on — not a
global minimum across every attached screen, which produces the wrong answer on multi-monitor
setups. It plans from what each item is *about to* be drawn as, asking the renderer directly,
rather than from the previous render or a fixed guess. Item width varies more than it looks:
icon style, whether the weekly window is shown, the number of percentage digits, and the pace
marker all move it, so a profile crossing 99% → 100% genuinely resizes itself.

Collapsing is immediate; re-expanding requires a full item's worth of slack, so the bar doesn't
oscillate at the boundary.

---

## Menu bar managers

If you run one of these, automatic mode detects it and **stands down** — it stops collapsing
entirely:

Ice · Thaw · Bartender · Hidden Bar · Dozer · Vanilla

The reason is that under a manager, automatic mode measures *correctly* and still does the wrong
thing. The bar really does have no free space, because the manager is occupying it by design and
already solving overflow through its own expandable region. Collapsing on top of that consumes
the space the manager set aside and hides accounts behind exactly the extra click the manager
exists to remove.

Settings names the manager it detected, so the change in behaviour reads as deliberate rather
than as the feature being broken.

Detection is by bundle identifier, and it fails safe: a manager that isn't recognised is simply
invisible to the check and automatic mode behaves as it otherwise would. If yours isn't
recognised, open an issue with its bundle identifier and we'll add it.

`Never` and `After N` are unaffected — they don't measure anything.

---

## Arrangement across restarts

Menu bar managers hide and show items by position, and AppKit persists that position in the
owning app's own preferences. Earlier versions discarded it on every quit, so anyone using a
manager had to re-place the app's items after each restart and each update.

Current versions preserve it. Items are also toggled hidden and shown as they cross the overflow
boundary rather than destroyed and recreated, which keeps both the saved position and the window
identity a manager tracks.

---

## Troubleshooting

**Accounts collapsed into `+N` and there's obviously room.**
Switch overflow mode to **Never**. If you run a manager, check whether Settings names it — if
not, it isn't recognised, and an issue with the bundle identifier will fix that.

**My manager can't move the app's items, and its rearrange UI locks up.**
Fixed in 3.3.3. Earlier versions did synchronous Accessibility work on the main thread on every
replan — at the same moment the manager was driving those same status item windows — and threw
the answer away. Update.

**An item is off-screen, invisible, or rejected as invalid by my manager.**
Fixed in 3.2.1. Items could strand themselves at coordinates outside every attached display.
Update; positions outside all screens are now discarded at launch.

**No icon at all.**
Check System Settings → Desktop & Dock → Menu Bar, restart the app, and check Console.app. If
you are on 3.3.0 specifically, that release could not launch on any machine — update.

**Everything is one item and I expected several.**
You're in Single display mode. Settings → Manage Profiles → switch to Multi, and confirm the
profiles you want are selected for display.
