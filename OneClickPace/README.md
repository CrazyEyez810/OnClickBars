# OneClickPace

Tells you when a quest spot is contested. While you stand in one area working a quest, it times your progress there and gives a verdict:

- Keep going: you're getting progress at a normal pace.
- Slow here: at this pace the quest takes more than 15 minutes; think about coming back later.
- Unlucky drops: you're killing the mobs but the item isn't dropping. Keep killing.
- Kills here aren't the quest mob: you're getting kills but no kill credit.
- Contested: no progress and no kills for 3 minutes (or 3 times your usual gap). Other players are taking the mobs; leave and come back later. A raid-warning message and sound play once.

The panel shows the quest, what's left, how long you've been there, time since your last progress, your pace and the time left at that pace.

Quests you finish on the way between hubs, like Raptor Horns in the Barrens, are left alone: when progress keeps landing far from the last progress, the quest is marked as done on the way and never judged. Walking away from a spot ends its timer.

It reads only the quest log, your position and the XP message for kills. It takes no actions.

## Commands

- `/pace` shows or hides the panel
- `/pace collapse` collapses or opens it (or click the corner button)
- `/pace scale 1.2` resizes it
- `/pace alerts off` turns off the contested warning
- `/pace roam` marks the quest on the panel as done on the way; `/pace camp` makes it always judged
- `/pace reset` clears all timers

## Releases

Pushing a tag like `OneClickPace-v0.1.0` builds the zip, attaches it to a GitHub release and uploads it to the CurseForge project in `## X-Curse-Project-ID:` of `OneClickPace.toc`.
