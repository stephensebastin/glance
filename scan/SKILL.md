---
name: slack-waiting-on-me
description: Scan Slack for conversations where someone is waiting on the user's reply, approval or action, and write them to the Claude Peek pill.
---

You are refreshing the "Waiting on you" list for the user's Claude Peek desktop widget. Find every Slack conversation where someone is waiting on the user right now, and write them to a JSON file. Read-only: NEVER send, post, react to or edit anything in Slack.

## Who
- The user: Slack user ID <YOUR_SLACK_USER_ID>, workspace <your-workspace> (team <YOUR_TEAM_ID>), timezone <your timezone>.
- Use the Slack connector tools: slack_search_public_and_private, slack_read_thread, slack_read_channel.

## Output file
Path: ~/Library/Application Support/ClaudePeek/slack.json
1. If the file exists, read it first. Its `items` are the previous list. Re-check each of them: they stay only if still waiting.
2. Search window: always the last 3 full days plus today, whatever the previous `scannedAt` says. A scan that missed something must not hide it from every later scan. In Slack search `after:` excludes the date given, so use the date 4 days ago (e.g. on 2026-11-23 use "after:2026-11-19").

## Find candidates
Use sort "timestamp", include_context false, response_format "concise". Follow next_cursor until there are no more pages (up to 5 pages per search); never stop at the first page.
1. Direct mentions: keywords ["<@<YOUR_SLACK_USER_ID>>"], filters "after:<date>", include_bots true.
2. DMs and group DMs: one search PER DAY, filters "is:dm on:<YYYY-MM-DD>" with channel_types "im,mpim", for today and each of the 3 days before. Do not use a single "is:dm after:" search: over several days Slack returns only the newest day and reports no more pages.
3. Threads they are part of: filters "from:<@<YOUR_SLACK_USER_ID>> is:thread after:<date>". For each, check whether someone else replied after them with something for them.
4. Messages the user marked done: "hasmy::white_check_mark: after:<date 7 days ago>" and "hasmy::heavy_check_mark: after:<same date>" (include_bots true). Note each hit's channel and Message_ts. These are not candidates; the rules below use them.

Group every hit from searches 1 to 3, plus the previous list, into conversations (one DM or group DM, or one thread). Skip a conversation only when the newest message in it is the user's own; every other conversation must be read before you decide. Never decide from search snippets alone.

## Decide, per conversation (one DM, or one thread)
For each candidate, read the thread (slack_read_thread with the parent ts) or the recent DM history (slack_read_channel, oldest = start of window) so you see everything said after the message, including the user's own replies.

Include it ONLY if ALL of these are true (an ask that tags the user together with other people still counts, unless one of them has already answered it):
- Someone other than the user (or an alert/bot that tags them by name) is waiting on THEM: a question to them, a request for their approval/decision/review/sign-off/ETA, a blocker they must unblock, an error or incident that needs their action, or a DM where a person greeted them or asked to talk and is waiting for a reply.
- The user has NOT replied after that message in the same thread/DM.
- The user has NOT reacted with :white_check_mark: or :heavy_check_mark: (✅ ✔️) to that message or to any later message in the same thread/DM (search 4 lists them). A ✅ means they have read and handled it, whatever the ask, question or not, so leave it out. A :+1: / :thumbsup: from them counts only for acknowledgements and approvals, not for questions that need an answer.
- Nobody else has already resolved it in the thread.
- The latest message waiting on them is less than 7 days old.

Exclude (this is the "no noise" rule — when in doubt, leave it out):
- They is only cc'd, tagged for FYI or visibility ("cc", "++", "for visibility", "fyi"), or it is a status update / announcement with no ask.
- @here / @channel / broadcast messages that don't ask them by name.
- Automated bot posts that don't need their action, even if they tag them in a cc list.
- Conversations where the last word is the user's, or where the other person just said "ok", "thanks", "sure" and nothing is pending.

## Each item
One item per conversation, for the most recent message that is waiting on them:
{
  "id": "<channel_id>:<thread_ts or ts of that message if not in a thread>",
  "from": "<first name of the person waiting>",
  "where": "#channel-name" | "DM" | "Group DM",
  "summary": "<what they need from the user, in English, max 80 chars, start with a verb or the ask, e.g. 'Approve per-minute rate limit for flooding customer'. Translate non-English messages.>",
  "kind": "error" | "approval" | "question" | "request",
  "priority": "blocked" | "input" | "read",
  "ts": "<Slack ts string of that message, e.g. 1793199861.146969>",
  "permalink": "<that message's permalink exactly as the search or thread result gives it, e.g. https://<your-workspace>.slack.com/archives/C.../p...?thread_ts=...&cid=C...>"
}
kind: "error" for incidents, failures, outages, alerts; "approval" for approve/decide/sign-off; "question" for direct questions; "request" for everything else.

priority is how soon the user must act. They read "blocked" items first, so get this right:
- "blocked": someone cannot proceed until the user acts. Approvals, sign-offs and go/no-go calls; a choice between options they're waiting on before building ("which do you suggest?"); a review that must pass before something ships or goes to a customer; an error, outage or incident that needs their action; anything marked urgent, ASAP or EOD, or with a deadline within 24 hours.
- "input": their answer, opinion or review is needed, but their work isn't stuck on it yet. Open questions, proposals, "can we build…", "should we…", checking a list of bugs, a person asking to talk.
- "read": they only want them to see or acknowledge something, and opening it is enough: "please take a look", a doc or update addressed to them by name with no question. (Plain FYIs and cc's stay excluded as noise.)
When torn between two, pick the more urgent one.

Order: blocked first, then input, then read; oldest first within each, so whoever has waited longest is on top. At most 25 items.

## Write
Write this JSON, then move it into place so the widget never reads a half-written file:
{"scannedAt": "<now, ISO 8601 with offset, e.g. 2026-10-28T21:30:00+05:30>", "checked": <number of conversations you read>, "items": [ ... ]}
Write to slack.json.tmp in the same folder (create the folder if missing), then `mv -f` it to slack.json. Write the file even when there are no items ("items": []), so the widget knows the scan ran.

Finish with one short line: how many people are waiting on the user. Nothing else.