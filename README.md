# wow-addons

Addons for WoW Forever by CrazyEyez810. Each folder is one addon with its own CurseForge project.

- `OneClickBars/` saves your whole setup (bars, keybindings, macros, Edit Mode layout, game and addon settings) and loads it on every new character, with leveling automation for RestedXP and Questie.
- `OneClickXP/` is an on-screen XP panel with kills to level and time to level.
- `tools/launch-day-copy.sh` copies your addons and their settings from one WoW folder to another, such as from the beta to the live client. Put it in the World of Warcraft folder and run it with WoW closed.

## Releasing

Tag the commit with the addon's name and version, then push the tag:

    git tag OneClickXP-v1.0.0
    git push origin OneClickXP-v1.0.0

The release workflow packages that addon's folder, creates a GitHub release and uploads to CurseForge. The `CF_API_TOKEN` repository secret holds the CurseForge token.
