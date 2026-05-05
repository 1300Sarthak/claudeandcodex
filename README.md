# Claude + Codex Usage Tracker

> Track your Claude.ai **and** ChatGPT Codex usage right from your Mac menu bar — with themes, side-by-side views, and full customization.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-12.0+-blue.svg)](https://www.apple.com/macos/)
[![Built on](https://img.shields.io/badge/built%20on-ClaudeUsageBar-orange)](https://github.com/Artzainnn/ClaudeUsageBar)

A heavily extended fork of [ClaudeUsageBar by Maxime B.](https://github.com/Artzainnn/ClaudeUsageBar) — a lightweight, open-source macOS menu bar app that started as a simple Claude usage tracker and has grown into a full-featured dual-service monitoring tool.

---

## What's New vs the Original

The original [ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar) by **Maxime B.** was a clean, minimal app that showed your Claude 5h and 7d usage in the menu bar. This fork builds significantly on that foundation:

| Feature | Original | This fork |
|---|---|---|
| Claude usage tracking | ✅ | ✅ |
| Codex (ChatGPT) tracking | ❌ | ✅ |
| Settings window | Inline panel | Dedicated NSWindow with sidebar nav |
| Theme support | System only | Dark / Light / System toggle |
| Color palettes | Green/orange/red | 5 presets (Default, Matrix, Sunset, Ocean, Mono) |
| Progress bar styles | Rounded only | Rounded / Thin / Segmented |
| Status bar display | 5h % only | Optional dual 5h·7d % |
| Layout | Single tab | Side-by-side Claude + Codex option |
| Compact mode | ❌ | ✅ |
| Refresh interval | Fixed 5 min | Configurable (1/5/15/30 min) |
| Graph | Basic line chart | Color-coded with palette support |
| Cookie instructions | 3 steps | 6 detailed steps per service |
| Settings icon | Text tab | Gear icon → floating window |
| Refresh button | Text button | Animated icon |
| Critical/High badges | ❌ | ✅ |
| About / attribution | ❌ | ✅ with links |

---

## Features

### Core Tracking
- **Dual service support** — Claude.ai and ChatGPT Codex in one app
- **Both windows shown** — 5-hour session and 7-day weekly bars for each service
- **Status bar options** — show `⚡ 12%` (session only) or `⚡ 12%·34%` (session + weekly)
- **Reset countdowns** — know exactly when each window resets
- **Pro plan support** — shows weekly Sonnet usage for Claude Pro subscribers
- **Codex code review limits** — shows Codex review rate limit if available

### Appearance & Customization
- **Theme** — Dark, Light, or System (respects macOS appearance preference)
- **Color palettes**
  - Default (green → orange → red)
  - Matrix (all greens)
  - Sunset (amber → orange → pink-red)
  - Ocean (teal → blue → indigo)
  - Monochrome (light → dark gray)
- **Bar styles** — Rounded (standard), Thin (2px line), Segmented (10-block)
- **Live preview** in the settings window as you pick

### Layout & Display
- **Side-by-side mode** — 820px wide popover with Claude and Codex panels next to each other
- **Compact mode** — tighter padding and smaller text for information-dense display
- **Graph toggle** — show or hide the usage history trend chart
- **Configurable refresh interval** — every 1, 5, 15, or 30 minutes

### Notifications & Shortcuts
- **Usage alerts** at 25%, 50%, 75%, and 90% for both services
- **Global shortcut Cmd+U** — toggle the popover from anywhere
- **Open at login** option

### Settings
- Dedicated floating **settings window** with sidebar navigation:
  - Appearance (theme, palette, bar style)
  - Display (layout, graph, compact, refresh interval)
  - Notifications (alerts, open at login)
  - Shortcuts (Cmd+U, accessibility)
  - Cookies (6-step setup guide for each service)
  - About (links, attribution)
- Accessible via **gear icon** in the popover header or right-click menu bar → Settings...

### Privacy
- All data stored locally on your Mac via `UserDefaults`
- Cookies sent only to `claude.ai` and `chatgpt.com` — nowhere else
- No analytics, no telemetry, no servers

---

## Setup (2 min)

### Claude Cookie
1. Open [claude.ai/settings/usage](https://claude.ai/settings/usage) and log in
2. Press `Cmd+Option+I` (Mac) or `F12` (Windows/Linux) to open DevTools
3. Click the **Network** tab and refresh the page
4. Click the **`usage`** request in the list
5. Scroll to **Request Headers**, find **`Cookie`**
6. Copy the entire value (starts with `anthropic-device-id=`, very long — copy all of it)

### Codex Cookie
1. Open [chatgpt.com/codex/settings/usage](https://chatgpt.com/codex/settings/usage) with a ChatGPT Pro account that has Codex access
2. Open DevTools (`Cmd+Option+I` on Mac, `F12` on Windows/Linux)
3. Click the **Network** tab, then refresh the page (`Cmd+R`)
4. Find the request to **`/backend-api/wham/usage`** and click it
5. Under **Request Headers → Cookie**, copy the complete value
6. It will be very long (includes `cf_clearance`, `oai-sc`, `_umsid`, etc.) — copy every character, do not truncate

> **Why `wham/usage`?** The Codex usage data is served from `/backend-api/wham/usage`. The `/backend-api/codex/usage` endpoint does not exist and will return a 404.

> **Why so many cookie fields?** ChatGPT runs behind Cloudflare. The `cf_clearance` value is a Cloudflare challenge token — without it, all requests return 403. The entire cookie string from the `wham/usage` request headers must be copied intact.

Paste each cookie in the app under **Settings → Cookies**.

---

## Build from Source

**Requirements:** macOS 12.0+, Xcode Command Line Tools

```bash
git clone https://github.com/1300Sarthak/claudeandcodex
cd claudeandcodex/app
chmod +x build.sh
./build.sh
```

The built app will be at `app/build/ClaudeUsageBar.app`.

To create a DMG installer:
```bash
./create_dmg.sh
```

---

## Repository Structure

```
app/
  ClaudeUsageBar.swift   — entire application (single Swift file)
  build.sh               — build script (arm64 + x86_64 universal binary)
  create_dmg.sh          — DMG installer creation
  Info.plist             — app bundle metadata
website/
  index.html             — landing page
```

---

## Key Technologies

- **SwiftUI** — views and state management
- **AppKit** — menu bar, popover, NSWindow (settings)
- **Carbon** — global keyboard shortcuts (`RegisterEventHotKey`)
- **Combine** — reactive observation of settings changes
- **NSUserNotification** — system notifications (no permissions required)
- **URLSession** — fetches usage data directly from claude.ai / chatgpt.com APIs

---

## Contributing

This project was built to be extended. Here's how to add more:

### Adding a new service (e.g. Gemini CLI, Cursor)
1. Add a new case to `UsageTab` enum
2. Add `@Published` properties to `UsageManager` for the service's usage data
3. Add a `fetchXxxUsage()` method that hits the service's API
4. Add an `XxxMetric` computed var and hook it into `UsageDashboardView`
5. Add a cookie card in `CookiesSectionView`

### Adding a new color palette
1. Add a case to `AccentColorPreset`
2. Implement the `color(for:)` function returning three `Color` values

### Adding a new bar style
1. Add a case to `BarStyle`
2. Add a rendering branch in `StyledProgressBar.body`

Pull requests and issues are welcome at [github.com/1300Sarthak/claudeandcodex](https://github.com/1300Sarthak/claudeandcodex).

---

## Roadmap

Planned additions (contributions welcome):

- **Better graphs** — area fills, time axis labels, zoom/pan, per-service colors
- **Gemini CLI support** — track Google Gemini API usage
- **Cursor support** — track Cursor editor usage limits
- **Windsurf / Copilot support** — more AI coding tool integrations
- **Notification threshold customization** — set your own % thresholds
- **Menu bar mini-graph** — tiny sparkline in the status bar
- **Usage export** — CSV / JSON export of history
- **iCloud sync** — share settings across Macs

---

## Attribution & License

This project is a fork of **[ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar)** by **Maxime B.** ([@maximemb_](https://x.com/maximemb_)). The original project provided the core architecture: session cookie auth, the claude.ai usage API integration, the NSPopover menu bar pattern, and the basic SwiftUI layout. All of that original work is credited to Maxime.

The following were added in this fork by **[Sarthak Sethi](https://sarthak.lol)** ([github.com/1300Sarthak](https://github.com/1300Sarthak)):
- ChatGPT Codex tracking
- Dedicated settings window with sidebar navigation
- Theme system (Dark/Light/System)
- 5 color palettes + 3 bar styles with live preview
- Side-by-side dual-service layout
- Dual status bar display (5h·7d)
- Compact mode, graph toggle, configurable refresh interval
- Animated icon buttons (gear, refresh)
- 6-step cookie setup guides
- Critical/High usage badges
- Attribution + about section
- Combine-based reactive settings propagation

MIT License — see [LICENSE](LICENSE).

---

## Disclaimer

This app uses internal API endpoints from claude.ai and chatgpt.com which may change without notice. It is not affiliated with or endorsed by Anthropic or OpenAI. Use at your own risk.
