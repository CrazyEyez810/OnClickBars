# OneClickBars

A leveling and addon optimizer for WoW Forever. Set up your action bars once and copy them to any character on your account with one click, then let it set up the game, RestedXP and Questie so 1-20 needs as few decisions as possible.

## How it works

"Save setup" on the character you set up captures the whole thing: action bars, keybindings, every macro, the Edit Mode layout, every game setting you changed, RestedXP settings and per-character addon layouts (WeaponSwingTimer). The first login on a new character puts it all back and asks once to reload (press Enter). "Undo" puts back what the character had before.

For a new client folder (for example the live WoW Forever client after the beta), close WoW and run `tools/launch-day-copy.sh` from the World of Warcraft folder. It copies your addons and their account settings from the beta folder into the new one and backs up anything it replaces.

1. On a character with the bars you want, click "Save setup". This saves the layout, keybindings, which extra bars are switched on, and the pet bar, as a profile for that class.
2. On another character of the same class, click "Load setup".
3. New level 1 characters load their class profile automatically on first login, and the opening cinematic is skipped.
4. Spells you haven't learned yet are placed in their saved slot as soon as you learn them, including higher ranks. Slots you change by hand are left alone.
5. "Leveling setup" turns on the interact key, auto loot, quest levels, enemy nameplates, XP numbers on the bar and other leveling settings, and switches on RestedXP's trainer, quest reward and junk automation. It also sets Questie to mark objectives, turn-ins and quest mobs while RestedXP picks the quests (tracker, auto-accept and off-route "!" icons off). It runs by itself on new level 1 characters and then checks your addons: Leatrix Plus doubling RestedXP's quest, gossip or junk automation, and addons RestedXP says break its arrow (TomTom, SilverDragon, TotemTimers, Leatrix Maps).
6. Shaman get an on-screen talent reminder at each level from 10 to 20.
7. "Undo" puts back the bars, keybindings and the game, RestedXP and Questie settings you had before the last load and leveling setup.

Each class can have several profiles (for example leveling and raid). Use the arrows in the window to pick one, and "New profile" to add one.

OneClickBars copies spells, macros, items, mounts, equipment sets, stance bars, keybindings and the pet bar. Missing macros are created.

## RestedXP support

If RestedXP Guides is installed, new level 1 characters start at step 1 of the 01-06 Durotar guide. The "Reset RestedXP guide" button does the same at any level. To use a different starting guide, load it in RestedXP and type `/1cb guide here`.

## Commands

- `/1cb` show or hide the window (or click the minimap button)
- `/1cb load`, `/1cb save`, `/1cb undo`
- `/1cb new <name>` save the current bars as a new profile
- `/1cb use <name>` pick a profile
- `/1cb list` show saved profiles
- `/1cb delete` delete the selected profile
- `/1cb scale 1.5` resize the window
- `/1cb auto off` stop placing new spells as you learn them
- `/1cb keys off` stop copying keybindings
- `/1cb intro off` stop skipping the opening cinematic
- `/1cb setup` run the leveling setup, `/1cb setup off` stop running it on new characters
- `/1cb check` check your addons for conflicts
- `/1cb talents off` stop the talent reminders
- `/1cb new off` stop auto-loading on new characters
- `/1cb guide off` stop the RestedXP reset on new characters

Key bindings for "Load action bars", "Undo", "Leveling setup" and "Reset RestedXP guide" are under Key Bindings, AddOns.

## Releases

Pushing a tag like `v1.2.0` builds the addon zip and attaches it to a GitHub release. Uploading to CurseForge also needs a `CF_API_TOKEN` repository secret.
