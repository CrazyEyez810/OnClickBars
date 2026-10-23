# OneClickXP

An on-screen XP panel for WoW Forever. No hovering, no extra panels to install.

It shows current and rested XP, XP to level, kills to level (counting double XP while you're rested), and XP per hour with time to level and time to 60 for the last 15 minutes of play, this session, this level and all time played. The last-15-minutes rate is the main estimate: it follows your current pace and drops old AFK time. The collapsed line uses it too.

Click the button in the top-right corner to collapse it to one line with level %, kills and time to level, and again to open it. Drag it to move it.

## Commands

- `/oxp` shows or hides the panel
- `/oxp collapse` collapses or opens it
- `/oxp scale 1.2` resizes it
- `/oxp window 10` sets the rolling window in minutes (5 to 60, default 15)

## Releases

Pushing a tag like `OneClickXP-v1.0.0` builds the zip, attaches it to a GitHub release and uploads it to the CurseForge project in `## X-Curse-Project-ID:` of `OneClickXP.toc`.
