# OneClickMail

Mails items to your own alts by rules, so you never send something to a stranger picked from the name autofill.

Opening a mailbox adds a "One Click" tab next to Inbox and Send Mail. Inside it, each of your alts gets its own tab:

- Click + and pick one of your characters. Characters show up once they've logged in with OneClickMail installed.
- Tick what that alt gets: herbs, leather and hides, cloth, ore, bars and stone, gems, enchanting materials, raw meat and fish, or green gear to disenchant.
- Drop any item onto the box to always send it to that alt. Click its icon to stop.
- "Ready to send" lists exactly what will go.
- Click Send to mail up to 12 items. If there's more, click again for the next mail.
- Tick "Send automatically when I open the mailbox" and it sends everything for that alt as soon as you open a mailbox, the way RestedXP turns in quests when you talk to an NPC.

The recipient is always the exact saved name of your alt, never typed or autofilled. Soulbound items, quest items and the hearthstone are never sent. Only alts of the same faction and realm are shown.

## Commands

- `/ocm alts` lists your saved characters
- `/ocm forget Name-Realm` removes one
- `/ocm auto on` allows automatic sending again if the client blocked it

## Releases

Pushing a tag like `OneClickMail-v0.1.0` builds the zip, attaches it to a GitHub release and uploads it to the CurseForge project in `## X-Curse-Project-ID:` of `OneClickMail.toc`.
