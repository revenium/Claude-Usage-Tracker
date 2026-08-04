# Claude Usage Tracker

![Revenium Labs](https://img.shields.io/badge/Revenium-Labs-6f42c1?style=for-the-badge)
![Status: Beta](https://img.shields.io/badge/status-beta%20(best--effort)-f0a020?style=for-the-badge)

> ### 🧪 This is a Revenium Labs project
> **Revenium Labs** projects are field-developed, best-effort solutions. They are working,
> beta-quality software, built to solve real customer problems and shared in the open. They are
> **not** part of Revenium's officially supported products.
>
> - It works and solves a real problem, but may need adaptation to fit your exact environment.
> - It's provided as-is, without the versioned-release guarantees, SLAs, or formal support
>   that back our core products.
> - We welcome your issues, feedback, and PRs, and **we're happy to work with you** to make it
>   fit your use case. [Come talk to us on Discord](https://discord.gg/J2DbmjZ2nA).
>
> → **[What is Revenium Labs?](https://github.com/revenium/.github/blob/main/LABS.md)**

<div align="center">
  <img src=".github/cover.jpg" alt="Claude Usage Tracker" width="100%">

  **A native macOS menu bar application for monitoring Claude and Codex subscription usage**

  ![macOS](https://img.shields.io/badge/macOS-14.0+-black?style=flat-square&logo=apple)
  ![Swift](https://img.shields.io/badge/Swift-5.0+-orange?style=flat-square&logo=swift)
  ![SwiftUI](https://img.shields.io/badge/SwiftUI-5.0+-blue?style=flat-square&logo=swift)
  ![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
  ![Version](https://img.shields.io/badge/version-3.0.5-blue?style=flat-square)
  ![Languages](https://img.shields.io/badge/languages-9-purple?style=flat-square)

  <sub>🇬🇧 English • 🇪🇸 Español • 🇫🇷 Français • 🇩🇪 Deutsch • 🇮🇹 Italiano • 🇵🇹 Português • 🇯🇵 日本語 • 🇰🇷 한국어 • 🇨🇳 简体中文</sub>

  ### [Download Latest Release](https://github.com/revenium/Claude-Usage-Tracker/releases/latest/download/Claude-Usage.dmg)

  <sub>macOS 14.0+ (Sonoma) | ~6 MB | Native Swift/SwiftUI | Officially Signed</sub>

</div>

---

## Overview

Claude Usage Tracker is a lightweight, native macOS menu bar application for
monitoring Claude and Codex subscription usage. Provider-specific data is
normalized into one profile, menu bar, popover, settings, and history
experience.

### Key Capabilities

- **Claude and Codex Subscriptions**: Track supported usage windows, credits, account health, and history
- **Multi-Profile Support**: Manage Claude and Codex profiles with isolated settings
- **Multi-Profile Display**: Monitor all profiles simultaneously in the menu bar
- **Claude Code Integration**: Sync CLI accounts and auto-switch credentials when changing profiles
- **Real-Time Monitoring**: Track session, weekly, API console usage, and API costs per profile
- **Usage History**: Interactive charts tracking session, weekly, and billing data over time
- **Global Shortcuts**: System-wide keyboard shortcuts (no Accessibility permission)
- **Headless Mode**: Works on headless Macs via Remote Desktop
- **Customizable Interface**: 5 icon styles + 3 color modes (Multi-Color/Greyscale/Single Color) + remaining/used percentage toggle
- **Smart Automation**: Auto-start sessions, auto-switch profiles, threshold notifications
- **Privacy-First**: Local storage, no telemetry, no cloud sync
- **Native Performance**: Lightweight Swift/SwiftUI design for macOS

<div align="center">
  <img src=".github/settings.gif" alt="Quick Walkthrough" width="600">
  <img src=".github/icon.jpg" alt="Menu Bar Icon" height="180">
  <img src=".github/popover.png" alt="Popover Interface" width="200">

  <sub>Menu bar icon and detailed usage popover</sub>
</div>

---

## What's New

- **v3.1.0 (2026-08-02)**: Redesigned menu bar popover — native vibrancy material, grouped cards with uppercase section headers, usage for the account you clicked shown first, a complete Accounts list grouped by provider (green dot = active, accent = viewing), and an explicit "Make Active" button so browsing an account never changes the active one

- **v3.0.5 (2026-08-02)**: Releases now ship a single notarized disk image — download `Claude-Usage.dmg`, open it, drag the app to Applications. This replaces the zip, which macOS Archive Utility could corrupt on extraction (breaking the embedded framework's code signature and triggering a false "Apple could not verify this app" warning)

- **v3.0.4 (2026-08-01)**: Menu bar provider badges — two independent Appearance toggles (both off by default) that distinguish Claude and Codex accounts at a glance: a monochrome provider glyph and/or a muted provider-colored background tint

- **v3.0.3 (2026-03-10)**: 6-tier pace system (Comfortable → Runaway) with colored pace markers on progress bars, 3 color modes (Multi-Color/Greyscale/Single Color) for menu bar and statusline, label toggles (Ctx/Usage/Reset), 24-hour time format, terminal-matching preview colors, CPU spin-loop fix in menu bar rendering

- **v3.0.2 (2026-03-10)**: API cost tracking with daily chart, browser-based authentication (WKWebView sign-in), rate limit header usage for CLI OAuth, auto-sizing popover, 3-way time display picker, adaptive green color, session key expiry tracking & notifications

- **v3.0.1 (2026-03-08)**: Popover settings tab (remaining time toggle), multi-display CPU fix

- **v3.0.0 - Major Release (2026-03-08)**:
  - **Headless mode**: Remote Desktop support for headless Mac environments
  - **Usage history**: Interactive timeline charts with export to JSON/CSV
  - **Global keyboard shortcuts**: Configurable hotkeys (no Accessibility permission needed)
  - **Auto-switch profiles**: Automatically switch when session limit reached
  - **Borderless settings window**: Full vibrancy design with custom traffic lights
  - **6 new statusline components**: Model name, context window, profile name, and more
  - **Time-elapsed markers & pace-aware coloring**: Smart progress indicators
  - **Network debug view**: Timed capture with request/response detail viewer
  - **Simplified Chinese** (9th language)
  - **12 ported improvements** from novastate fork including CLI auto-detection, wake-from-sleep refresh, and custom notification thresholds

- **v2.3.0** – Multi-profile menu bar display, remaining percentage toggle
- **v2.2.0** – Multi-profile management, CLI integration, Korean language
- **v2.1.0** – 3-step setup wizard, smart organization preservation
- **v2.0.0** – Apple code signing, automatic updates, Keychain security

**[View Full Release History](CHANGELOG.md)**

---

## Getting Started

### Prerequisites

Before installing Claude Usage Tracker, ensure you have:

- **macOS 14.0 (Sonoma) or later** - Check: Apple menu → About This Mac
- An active Claude account, a ChatGPT subscription used by Codex, or both
- For Codex: the official `codex` CLI installed and able to run `codex
  app-server` from the app's environment

See **[Codex subscription support](docs/codex-subscriptions.md)** for account
eligibility, setup, privacy boundaries, troubleshooting, and exclusions.

**Authentication** (choose one method):
- **Easiest**: [Claude Code](https://claude.com/claude-code) installed and logged in - App automatically uses CLI credentials (v2.2.2+)
- **Browser Sign-In**: Sign in via the built-in browser — session key extracted automatically (v3.0.2+)
- **Manual**: Web browser access to extract session key from claude.ai (Chrome, Safari, Firefox, etc.)

### Installation

#### Option 1: Homebrew (Recommended)

```bash
brew install --cask revenium/tap/claude-usage
```

Or tap first, then install:

```bash
brew tap revenium/tap
brew install --cask claude-usage
```

**Note**: Starting with v2.0.0, the app is officially signed with an Apple Developer certificate. No security workarounds needed!

**To update**:
```bash
brew upgrade --cask claude-usage
```

Or use the built-in automatic update feature (Settings → Updates).

**To uninstall**:
```bash
brew uninstall --cask claude-usage
```

#### Option 2: Direct Download

**[Download Claude-Usage.dmg](https://github.com/revenium/Claude-Usage-Tracker/releases/latest/download/Claude-Usage.dmg)**

1. Download the `.dmg` file from the link above
2. Open the disk image (double-click)
3. Drag `Claude Usage.app` to the `Applications` shortcut in the window
4. Eject the disk image, then launch the app from Applications - that's it!

**v2.0.0+ Note**: The app is now officially signed with an Apple Developer certificate. You can install and run it like any other Mac application - no security warnings or workarounds needed.

**Automatic Updates**: Once installed, the app will automatically check for updates and notify you when new versions are available (Settings → Updates).

#### Option 3: Build from Source

```bash
# Clone the repository
git clone https://github.com/revenium/Claude-Usage-Tracker.git
cd Claude-Usage-Tracker

# Open in Xcode
open "Claude Usage.xcodeproj"

# Build and run (⌘R)
```

### Quick Start Guide

#### Codex Subscription Setup

1. Install Codex, then sign in with the ChatGPT subscription you want to
   monitor.
2. Launch Claude Usage Tracker and choose **Codex** in first-run setup, or add
   a Codex profile in **Settings → Manage Profiles**.
3. Choose the existing `CODEX_HOME` directory used by that Codex installation,
   verify it, and select **Start Tracking**.
4. Use **Provider Account** to refresh health, sign in, relink, or unlink.

The app delegates authentication and usage reads to the official Codex
app-server process. It does not read or copy Codex authentication files.

#### Option A: Automatic Setup with Claude Code (Easiest)

**New in v2.2.2**: If you have Claude Code installed and logged in, the app works automatically!

1. **Install Claude Code** (if not already installed)
   - Download from [claude.com/claude-code](https://claude.com/claude-code)
   - Open Claude Code and type `/login` to authenticate

2. **Launch Claude Usage Tracker**
   - The app automatically detects your Claude Code Account
   - No manual configuration needed!

3. **Verify It's Working**
   - Click the menu bar icon
   - You should see your usage statistics immediately

#### Option B: Browser Sign-In (v3.0.2+)

If you don't use Claude Code, sign in directly through the app:

1. **Click the menu bar icon** and select "Settings"
2. **Navigate to "Personal Usage"** tab
3. **Click "Sign in to Claude.ai"** — an embedded browser opens
4. **Log in** with your Claude.ai credentials (email, Google SSO, etc.)
5. **Session key is extracted automatically** — the app validates and saves it
6. **Select your organization** from the list and confirm

#### Option C: Manual Setup with Session Key

If you prefer manual configuration:

**Step 1: Extract Your Session Key**

1. **Open Claude AI**
   - Navigate to [claude.ai](https://claude.ai) in your browser
   - Make sure you're logged in

2. **Open Developer Tools**
   - **Chrome/Edge**: Press `F12` or `Cmd+Option+I` (macOS) / `Ctrl+Shift+I` (Windows)
   - **Safari**: Enable Developer menu in Preferences → Advanced, then press `Cmd+Option+I`
   - **Firefox**: Press `F12` or `Cmd+Option+I` (macOS) / `Ctrl+Shift+I` (Windows)

3. **Navigate to Cookies**
   - Go to: **Application** tab (Chrome/Edge) or **Storage** tab (Firefox)
   - Expand: **Cookies** → **https://claude.ai**
   - Find: `sessionKey` cookie
   - Copy: The value (starts with `sk-ant-sid01-...`)

**Step 2: Configure Session Key**

1. **Click the menu bar icon** and select "Settings"
2. **Navigate to "Personal Usage"** tab
3. **Expand "Advanced: Manual Session Key"**
4. **Paste your session key** and click "Test Connection"
5. **Select your organization** from the list
6. **Review and click "Save Configuration"**

**Step 3: Verify It's Working**

1. **Check Menu Bar**: You should see the Claude Usage icon in your menu bar
2. **Click the Icon**: Popover appears showing your usage statistics
3. **View Data**: Session usage, weekly usage, and reset timers should display

**Success!** The app is now monitoring your Claude usage.

#### Next Steps

- **Customize Icon**: Go to Settings → Appearance to choose your preferred menu bar style
- **Enable Notifications**: Settings → Notifications to get threshold alerts
- **Auto-Start Sessions**: Settings → Session Management to enable automatic session initialization
- **Keyboard Shortcuts**: Settings → Shortcuts to configure global hotkeys

---

## Advanced Configuration

### Manual Session Key Setup

If you prefer to configure the session key manually instead of using the setup wizard:

```bash
# Create session key file
echo "sk-ant-sid01-YOUR_SESSION_KEY_HERE" > ~/.claude-session-key

# Set secure permissions (important for security)
chmod 600 ~/.claude-session-key
```

After creating the file, launch the app and it will automatically detect the session key.

---

## Multi-Profile Management

**New in v2.2.0**: Claude Usage Tracker now supports unlimited profiles, allowing you to manage multiple Claude accounts seamlessly with automatic credential switching.

**New in v3.0.0**: Auto-switch profiles when session limit reached, usage history tracking, and global keyboard shortcuts!

### Features

#### Profile Management
- **Unlimited Profiles**: Create as many profiles as needed for different Claude accounts
- **Multi-Profile Display**: Show all profiles in the menu bar at once
  - Toggle between Single mode (active profile only) and Multi mode (all profiles)
  - Each profile displays with its own icon style and settings
  - Click any profile icon to view its usage details
  - Independent refresh rates per profile
- **Fun Auto-Names**: Profiles auto-generate with names like "Quantum Llama", "Sneaky Penguin", "Turbo Sloth"
- **Custom Names**: Rename profiles to whatever you prefer
- **Quick Switching**: Switch profiles instantly via popover dropdown or settings sidebar
- **Profile Badges**: Visual indicators show which profiles have Claude.ai credentials and CLI accounts

#### Claude Code CLI Integration
- **One-Click Sync**: Sync your currently logged-in Claude Code account to a profile
- **Automatic Switching**: When you switch profiles, CLI credentials automatically update
- **Credential Display**: View masked access tokens and subscription type
- **Smart Re-Sync**: Credentials automatically refresh before profile switches to capture CLI changes
- **Per-Profile CLI**: Each profile can have its own Claude Code account or share the system account

#### Per-Profile Settings
Each profile has isolated settings:
- **Credentials**: Separate Claude.ai session keys, API keys, and organization IDs
- **Appearance**: Independent icon styles and monochrome mode
- **Refresh Interval**: Custom refresh rates (5-300 seconds)
- **Auto-Start Sessions**: Enable/disable per profile
- **Notifications**: Independent threshold alerts (75%, 90%, 95%)
- **Usage Data**: Tracked separately per profile

#### Profile Switcher
Access profile switcher in multiple places:
- **Popover Header**: Dropdown menu with profile badges
- **Settings Sidebar**: Active profile picker with visual indicators
- **Manage Profiles Tab**: Full profile management interface

#### How to Use

1. **Create Profiles**:
   - Go to Settings → Manage Profiles
   - Click "Create New Profile"
   - Auto-generates a fun name or enter your own

2. **Configure Credentials**:
   - Switch to desired profile in sidebar
   - Go to Claude.AI / API Console / CLI Account tabs
   - Enter credentials (isolated per profile)

3. **Sync Claude Code** (Optional):
   - Log in to Claude Code in terminal
   - Open Settings → CLI Account
   - Click "Sync from Claude Code"
   - Now when you switch profiles, CLI credentials auto-update!

4. **Switch Profiles**:
   - Click popover dropdown
   - Or use settings sidebar picker
   - CLI credentials apply automatically

### MCP Server Sync

When using multi-account CLI switching, MCP servers configured via `claude mcp add` are stored in the active account's `.claude.json`. This means an MCP added while one account is active won't be available when you switch to another account. MCP Server Sync solves this by keeping MCP configurations consistent across all linked accounts.

#### How It Works

The sync performs a **bidirectional merge**:
1. Collects `mcpServers` from `~/.claude.json` (home config) and every linked account's `.claude.json`
2. Builds the union of all MCP servers found across all sources
3. Writes any missing servers back to each source that doesn't have them

Existing per-account MCP configurations are never overwritten — the sync only adds servers that are missing from a given account. Project-scoped MCPs (added with `claude mcp add` to a specific project) are not affected.

#### Auto-Sync (Default: Enabled)

When enabled, MCP servers are automatically synced across all accounts every time you switch profiles. This means:
- Add an MCP to any account → switch profiles → all accounts have it
- No manual intervention needed

To disable: Settings → CLI Account → toggle off "Auto-sync on account switch"

#### Manual Sync

A "Sync MCP Servers Now" button is always available in Settings → CLI Account. After syncing, the app shows exactly what changed:
- Which MCP servers were added
- Which accounts received them

This is useful after adding multiple MCPs or when you want to verify all accounts are in sync without switching profiles.

#### Trust Model

Bidirectional sync means MCP configs from any linked account can propagate to all other accounts and to `~/.claude.json`. If you need strict isolation between accounts' MCP configurations, disable auto-sync and use manual sync selectively.


---

## Features

### Installation & Updates
- **Official Apple Code Signing**: Professionally signed application - installs like any Mac app
- **Automatic Updates**: Built-in update system powered by Sparkle framework
- **One-Click Installation**: No security workarounds or manual approvals needed
- **Update Notifications**: Get notified when new versions are available

### Usage Tracking & Monitoring
- Real-time monitoring of 5-hour session, weekly limits, and Opus-specific usage
- API console usage tracking with monthly cost dashboard and daily cost chart
- Per-API-key cost breakdown with model-level detail
- Extra usage cost tracking for Claude Extra subscribers
- Color-coded indicators (adaptive green/orange/red) based on consumption levels
- Smart countdown timers for session and weekly resets with 3-way display (time, remaining, or both)

### Menu Bar & Interface
- **5 Customizable Icon Styles**: Battery, Progress Bar, Percentage Only, Icon with Bar, Compact
- **Multi-Metric Icons**: Display separate icons for session, weekly, and api usage simultaneously
- **3 Color Modes**: Multi-Color (threshold-based), Greyscale (adapts to appearance), Single Color (custom hex)
- **6-Tier Pace System**: Pace markers colored by projected usage (green/teal/yellow/orange/red/purple)
- **Interactive Popover**: One-click access with detachable floating window capability
- **Live Status Indicator**: Real-time Claude system status from status.claude.com
- **Multi-Language Support**: 9 languages (English, Spanish, French, German, Italian, Portuguese, Japanese, Korean, Simplified Chinese)
- Adaptive colors for light/dark mode

### Automation & Intelligence
- **Auto-Start Sessions**: Automatically initialize new sessions when usage resets to 0%
- **Auto-Switch Profiles**: Automatically switch to next profile at session limit
- **Wake-from-Sleep Refresh**: Auto-refresh after waking with debounce
- **Smart Notifications**: Threshold alerts at 75%, 90%, 95% + custom thresholds with sound picker
- **Network Monitoring**: Auto-detect connectivity changes and handle offline scenarios
- **Launch at Login**: System-level auto-start option
- **Configurable Refresh**: Set intervals from 5 to 120 seconds
- Session reset and auto-start confirmations

### Security & Privacy
- **macOS Keychain Storage**: Session keys stored in macOS Keychain (most secure option)
- **Automatic Migration**: Seamless migration from old storage methods
- **Apple Code Signed**: Verified by Apple for enhanced security and trust
- **Advanced Error Handling**: Professional error system with user-friendly recovery
- **Robust Validation**: Session key and API endpoint validation
- Local storage with no cloud sync
- Zero telemetry or tracking
- HTTPS-only communication with Claude API

### Advanced Capabilities
- Multi-screen support
- First-run guided setup wizard
- Protocol-based modular architecture
- Persistent settings with App Groups
- Comprehensive test coverage

---

## Usage

### Menu Bar Interface

Click the menu bar icon to access:

- **Session Usage**: 5-hour rolling window percentage and reset time
- **Weekly Usage**: Overall weekly consumption across all models
- **Opus Usage**: Weekly Opus-specific usage (if applicable)
- **API Cost**: Monthly cost with daily chart and per-key breakdown (if Console configured)
- **Quick Actions**: Refresh and Settings

### Settings

Access comprehensive settings through the menu bar popover → Settings button. The app features a modern sidebar interface with profile switcher and organized tabs:

### Profile-Specific Settings

#### Profile Switcher (Sidebar)
- **Quick Profile Selection**: Dropdown to switch between profiles instantly
- **Profile Badges**: Visual indicators for Claude.ai 🔵 and CLI ✅ credentials
- **Active Profile Display**: Shows currently selected profile

#### Claude.AI (Credentials)
Configure your Claude.ai personal account:
- **Browser Sign-In**: Sign in via embedded browser to extract session key automatically (v3.0.2+)
- **3-Step Setup Wizard**: Guided session key configuration
  - Non-destructive connection testing
  - Visual organization selector
  - Configuration summary with preview
- **Manual Key Entry**: Advanced option under disclosure group for direct session key input
- **Smart Updates**: Organization preserved when re-entering same key

#### API Console (Credentials)
Configure API console usage tracking:
- **Browser Sign-In**: Sign in via embedded browser for Anthropic Console (v3.0.2+)
- **API Session Key**: Set your API authentication key (manual fallback)
- **Organization ID**: Configure organization for API tracking
- **Dual Tracking**: Monitor both web and API usage simultaneously
- **API Billing**: View API console spend, prepaid credits, and monthly cost breakdown
- **Session Key Expiry**: Visual status indicator showing when your session key expires

#### CLI Account (Credentials)
Sync Claude Code CLI credentials:
- **One-Click Sync**: Copy currently logged-in Claude Code account to profile
- **Credential Display**: View masked access token and subscription type
- **Auto-Switch**: Credentials automatically update when changing profiles
- **Remove Sync**: Unlink CLI account from profile

#### Appearance
Customize menu bar icon per profile:
- **Icon Style Selection**: Choose from 5 different display modes
  - Battery Style (classic indicator with fill)
  - Progress Bar (horizontal bar with percentage)
  - Percentage Only (text-only minimalist)
  - Icon with Bar (Claude icon + progress)
  - Compact (space-efficient)
- **3 Color Modes**: Multi-Color (threshold-based), Greyscale (adapts to appearance), Single Color (custom hex)
- **Pace Marker**: Colored time marker on progress bars showing projected usage pace (6 tiers)
- **Percentage Display Mode**: Toggle between used/remaining percentage
  - Show "75% used" or "25% remaining" - your choice
  - Color coding automatically adapts (green for high remaining, red for low)
  - Helps focus on budget left rather than budget spent
- **Live Preview**: See changes in real-time before applying

#### General (Profile Settings)
Per-profile behavior configuration:
- **Refresh Interval**: Configure auto-refresh rate (5-300 seconds)
- **Auto-Start Sessions**: Enable/disable automatic session initialization on reset
- **Model Selection**: Uses the most cost-effective model available
- **Notifications**: Per-profile threshold alerts (75%, 90%, 95%) + custom thresholds with sound picker

### App-Wide Settings

#### Manage Profiles
Create and manage multiple profiles:
- **Create Profiles**: Add new profiles with fun auto-generated names
- **Rename Profiles**: Customize profile names
- **Delete Profiles**: Remove unused profiles (minimum 1 required)
- **Profile List**: View all profiles with credential status indicators
- **Display Mode Toggle**: Switch between Single and Multi mode
  - Single Mode: Show only the active profile in menu bar
  - Multi Mode: Show all profiles simultaneously in menu bar
- **Auto-Switch Profile**: Automatically switch to next available profile when session limit reached

#### Language
Application language preferences:
- **Language Selection**: Choose from 9 supported languages
- **Live Updates**: Interface updates immediately when language changes
- Supported: English, Spanish, French, German, Italian, Portuguese, Japanese, Korean, Simplified Chinese

#### Updates
Automatic update configuration:
- **Automatic Update Checking**: Configure how often to check for updates
- **Update Notifications**: Get notified when new versions are available
- **One-Click Installation**: Download and install updates with a single click
- **Release Notes**: View what's new in each update

#### About
Application information:
- **Version Information**: Current app version
- **Credits**: Contributors and acknowledgments
- **Links**: GitHub repository, issue tracker, documentation

## Architecture

### Technology Stack

- **Language**: Swift 5.0+
- **UI Framework**: SwiftUI 5.0+
- **Platform**: macOS 14.0+ (Sonoma)
- **Architecture**: MVVM with Protocol-Oriented Design
- **Storage**: UserDefaults with App Groups
- **Networking**: URLSession with async/await
- **Design Patterns**: Coordinator pattern, Protocol-based services, Modular components

## API Integration

The application integrates with multiple Claude API endpoints for comprehensive usage tracking:

### Web Usage Endpoint

```
GET https://claude.ai/api/organizations/{org_id}/usage
```

**Authentication**: Session cookie (`sessionKey`) from claude.ai

**Response Structure**:
- `five_hour`: 5-hour session usage data
  - `utilization_pct`: Usage percentage (0-100)
  - `reset_at`: ISO 8601 timestamp for next reset
- `seven_day`: Weekly usage across all models
  - `utilization_pct`: Weekly usage percentage
- `seven_day_opus`: Opus-specific weekly usage
  - `utilization_pct`: Opus weekly percentage
- `extra_usage`: Claude Extra cost tracking (if applicable)
  - `current_spending`: Amount spent
  - `budget_limit`: Maximum allowed spending

### API Console Endpoint

```
GET https://api.anthropic.com/v1/organization/{org_id}/usage
```

**Authentication**: API Key (`x-api-key` header)

**Response Structure**:
- API console usage statistics
- Billing information
- Rate limits and quotas

### Dual Tracking

The app can simultaneously monitor both web (claude.ai) and API console usage, providing complete visibility into your Claude consumption across all access methods.

## Security

- **macOS Keychain**: Session keys stored securely in macOS Keychain (most secure storage available)
- **Automatic Migration**: v2.0+ automatically migrates session keys from older storage methods to Keychain
- **Apple Code Signed**: Officially signed with Apple Developer certificate for verified authenticity
- **Secure Updates**: Automatic updates delivered over HTTPS with code signature verification
- **No Cloud Sync**: All data remains local to your machine
- **No Telemetry**: Zero tracking or analytics
- **Advanced Error Handling**: Robust error system with user-friendly recovery
- **Session Key Validation**: Comprehensive validation of API credentials
- **Network**: HTTPS-only communication with claude.ai and Anthropic API

## Troubleshooting

### Application Not Connecting

1. Verify your session key is valid
2. Check that you're logged into claude.ai in your browser
3. Try extracting a fresh session key
4. Ensure you have an active internet connection

### 403 Permission Errors

If you see "Unauthorized" or 403 errors:
1. Open Settings → Personal Usage
2. Use the 3-step wizard to reconfigure:
   - Test your session key
   - Select the correct organization
   - Save configuration
3. The wizard will preserve your organization selection when updating keys

### Menu Bar Icons Showing Zero

If icons briefly flash to zero during refresh:
- This has been fixed in v2.1.0+
- Update to the latest version for smooth refresh experience
- Old data now stays visible until new data arrives

### Menu Bar Icon Not Appearing

1. Check System Settings → Desktop & Dock → Menu Bar
2. Restart the application
3. Check Console.app for error messages

### Session Key Expired

Session keys may expire after a period of time. You'll receive a notification 24 hours before expiry (v3.0.2+). To refresh:
1. Go to Settings → Personal Usage (or API Console)
2. Click "Sign in to Claude.ai" (or "Sign in to Anthropic Console") to re-authenticate via the built-in browser
3. Or expand "Advanced: Manual Session Key" to paste a new key manually

### Updates Not Working

If automatic updates aren't working:

1. Check Settings → Updates to ensure automatic checking is enabled
2. Verify you're running v2.0.0 or later (earlier versions don't have auto-update)
3. Check your internet connection
4. Manually download the latest version from GitHub if needed

## Contributors

<img src="https://contrib.rocks/image?repo=revenium/Claude-Usage-Tracker" alt="Contributors" height="30px" />

This project is built for the community — everyone is welcome

### Special Thanks

A huge thank you to everyone who opened pull requests. Many features in v3.0.0 were inspired by or ported from community PRs that couldn't be merged directly due to the scale of this release and resulting conflicts. Your code, ideas, and effort made this release possible:

<a href="https://github.com/novastate"><img src="https://github.com/novastate.png" width="40" height="40" alt="novastate" title="novastate"></a>
<a href="https://github.com/heathdutton"><img src="https://github.com/heathdutton.png" width="40" height="40" alt="heathdutton" title="heathdutton"></a>
<a href="https://github.com/tsvikas"><img src="https://github.com/tsvikas.png" width="40" height="40" alt="tsvikas" title="tsvikas"></a>
<a href="https://github.com/kynoptic"><img src="https://github.com/kynoptic.png" width="40" height="40" alt="kynoptic" title="kynoptic"></a>
<a href="https://github.com/bezlant"><img src="https://github.com/bezlant.png" width="40" height="40" alt="bezlant" title="bezlant"></a>
<a href="https://github.com/trickart"><img src="https://github.com/trickart.png" width="40" height="40" alt="trickart" title="trickart"></a>
<a href="https://github.com/Ali-Aldahmani"><img src="https://github.com/Ali-Aldahmani.png" width="40" height="40" alt="Ali-Aldahmani" title="Ali-Aldahmani"></a>
<a href="https://github.com/cuvitx"><img src="https://github.com/cuvitx.png" width="40" height="40" alt="cuvitx" title="cuvitx"></a>

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Development Setup

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

For Codex subscription changes, run the package, localization, app, and native
UI suites before opening a pull request:

```bash
swift test --package-path Packages/UsageKit
./scripts/tests/test_validate_localizations.sh
./scripts/validate_localizations.sh
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -configuration Debug -destination "platform=macOS"
xcodebuild test -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage UI Tests" -configuration UITesting \
  -destination "platform=macOS,arch=arm64"
```

The native UI suite uses a temporary app-owned store, temporary `CODEX_HOME`,
and a deterministic fake Codex app-server. It does not need an account or
network access. Local macOS runs do require UI automation authorization. If
Xcode stalls at `enabling automation mode`, enable Developer Mode and grant
the launching Xcode or terminal process the requested Accessibility permission
in System Settings, then rerun. Do not script or bypass macOS TCC permissions.
CI runs the same UI scheme as the required runtime gate.

### Code Style

- Follow Swift API Design Guidelines
- Use SwiftUI best practices
- Maintain MVVM architecture
- Add comments for complex logic
- Write descriptive commit messages

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with Swift and SwiftUI
- Designed for macOS Sonoma and later
- Uses Claude AI's usage API
- Inspired by the need for better usage visibility

## Disclaimer

This application is not affiliated with, endorsed by, or sponsored by Anthropic PBC. Claude is a trademark of Anthropic PBC. This is an independent third-party tool created for personal usage monitoring.

## AI Transparency

This project is developed using AI-assisted workflows (primarily Claude Code via Happy). We believe in transparent collaboration between human developers and AI tools.

---

<div align="center">
  <sub>Built for the Claude AI community</sub>
</div>
