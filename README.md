# OneClickBars

A World of Warcraft addon for WoW Forever. Set up your action bars once, then copy them to any character on your account with one click. No import strings.

## How it works

1. On a character with the bars you want, click "Save bars". This saves the layout, keybindings, which extra bars are switched on, and the pet bar, as a profile for that class.
2. On another character of the same class, click "Load bars".
3. New level 1 characters load their class profile automatically on first login, and the opening cinematic is skipped.
4. Spells you haven't learned yet are placed in their saved slot as soon as you learn them, including higher ranks. Slots you change by hand are left alone.
5. "Undo last load" puts back the bars and keybindings you had before the last load.

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
- `/1cb new off` stop auto-loading on new characters
- `/1cb guide off` stop the RestedXP reset on new characters

Key bindings for "Load action bars", "Undo last load" and "Reset RestedXP guide" are under Key Bindings, AddOns.

## Releases

Pushing a tag like `v1.2.0` builds the addon zip and attaches it to a GitHub release. Uploading to CurseForge also needs a `CF_API_TOKEN` repository secret.
