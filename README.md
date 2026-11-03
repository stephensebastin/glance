# Claude Peek

A small pill at the top of your Mac's screen. It shows your Claude Code sessions (terminal and desktop app) and the Slack conversations where someone is waiting on you. Hover over it to expand it. It is hidden from screen sharing.

## Requirements

- macOS 14 or later.
- Swift 6 (comes with Xcode or the Command Line Tools: `xcode-select --install`).
- For the Slack tab: the Claude desktop app with the Slack connector, and the `claude` CLI signed in to the same claude.ai account.

## Build and run

```bash
./build.sh --run       # build and open it once
./build.sh --install   # copy to ~/Applications, start at login, restart if it stops
```

## Slack setup

1. Fill in your details in [`scan/SKILL.md`](scan/SKILL.md): your Slack user ID (Slack → your profile → ⋯ → Copy member ID), workspace, team ID and timezone.
2. In the Claude desktop app, ask Claude to create a scheduled task named `slack-waiting-on-me` with the schedule `0 9,13,17,21,1 * * *` and the contents of `scan/SKILL.md` as its prompt. Its prompt is stored at `~/.claude/scheduled-tasks/slack-waiting-on-me/SKILL.md`, which the **↻** button also reads.

## What it shows

- **Running:** sessions that are working right now, or waiting on you. Covers both terminal (`claude` CLI) and Claude desktop app sessions.
- **Unread:** app sessions whose last turn finished after you last opened them, including archived ones (marked **Archived**), plus terminal sessions that finished since you last clicked them here. Clicking a row opens it (Claude app, or the terminal app hosting it) and marks it read. There is no "mark all read": each one clears only when you open it.
- **Open, idle:** live sessions with nothing new.

## Slack: who is waiting on you

A scheduled Claude task, `slack-waiting-on-me`, scans Slack at 9am, 1pm, 5pm, 9pm and 1am. It only reads Slack, and never posts or reacts. It keeps only conversations where someone is waiting on your reply, approval or action, and you haven't answered yet. Being cc'd, FYI posts, broadcasts and bot posts without an ask are left out. Results go to `~/Library/Application Support/ClaudePeek/slack.json`.

**Check now:** on the Slack tab, click **↻** in the header to run the same scan immediately. It takes about a minute, and the header shows a spinner and "checking now…" until it's done. It runs through the `claude` CLI (Homebrew's copy first) with your claude.ai Slack connector. It can only search and read Slack: it has no file, shell or posting tools. Claude Peek writes `slack.json` itself from the result. If it fails, the header says "refresh failed" and the CLI's reply is saved to `slack-refresh-error.log` in the same folder.

The scan sorts every item into one of three groups, most urgent first, with whoever has waited longest on top:

| Group | Means | Clears when |
|---|---|---|
| **Blocked on you · reply first** (red) | Someone can't proceed until you act: approvals, sign-offs, a choice they're waiting on, a review before something ships, an error or incident, anything urgent or due within a day | You reply (see below) |
| **Needs your input** (purple) | Your answer or review is needed, but nobody is stuck yet | You reply (see below) |
| **Just read it** (blue-grey) | They only want you to see it | You open it |

- The pill shows a red bubble with the blocked count, then a purple bubble with the rest. The Slack tab shows the same two numbers.
- Errors get a red warning icon.
- Clicking a row opens that exact thread in the Slack app. Opening a blocked or input item doesn't clear it: the row says **Opened · reply now** (or **Opened · reply**) and keeps counting.
- **Replies close items within a couple of seconds.** Claude Peek follows the Slack app's own log (`~/Library/Application Support/Slack/logs/default/webapp-console.log`), which records each message you send and where:
  - A reply in the item's own thread closes it, whether or not you opened it from here.
  - A message in the DM or channel closes it only if you opened the item from here first. In a busy DM you often write about other things, so that alone doesn't prove you answered.
  - Only messages sent from the Slack app on this Mac are seen. Replies from your phone or the browser are picked up by the next scan.
- Scheduled tasks run while the Claude app is open. A run that was due while it was closed happens the next time you open it.
- The task's own runs are hidden from the session list.

## Where the data comes from

| Data | Source |
|---|---|
| Live status (busy/idle) for terminal and app | `~/.claude/sessions/<pid>.json`, filtered to live processes |
| App session titles, last focused, last turn end | `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json` |
| What you've marked read here | `~/Library/Application Support/ClaudePeek/acks.json` |

All of this is read-only and local. Nothing goes over the network.

## Screen sharing

The panel sets `NSWindow.sharingType = .none`, so screenshots, screen recording and screen sharing leave it out. Do one test share in your meeting app to confirm it on your setup.

## The pill

`[icon] 3 • 12`: an animated icon, then the number of running sessions, then a blue dot with the unread count. The icon is orange when sessions are working, yellow when one needs you, and grey when idle.

- **Move it:** drag the pill, or the top of the expanded panel, anywhere on any screen. It remembers where you leave it.
- **Change the icon:** click the icon in the expanded header to cycle through Spark, Buddy, Orbit and Equalizer, or right-click and pick one.
- **Reset position:** right-click, then **Reset position**.

## Quit / start at login

- Quit: hover, then click **×**, or right-click, then **Quit Claude Peek**.
- Start at login: `./build.sh --install` sets up a LaunchAgent (`local.claudepeek`) that starts it at login and restarts it if it crashes or is killed. Quitting with × keeps it closed until the next login, or until you run `launchctl kickstart gui/$(id -u)/local.claudepeek`.
