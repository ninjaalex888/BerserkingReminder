# Berserking Reminder

A small addon for **WoW Forever** that shows the Troll racial **Berserking** whenever it's off
cooldown during a fight, so you remember to use it. It stays quiet on characters that aren't Trolls.

| Berserking is | In combat | Out of combat |
|---|---|---|
| Ready | A pulsing Berserking icon labeled "Berserking ready" | Nothing (`/berserk always` shows it) |
| Cooling down | Nothing | Nothing |

If Berserking comes off cooldown in the middle of a fight, you also hear a short ping
(`/berserk sound` turns that off). The icon also hides while you're dead or on a flight path.

## Install

1. Download `BerserkingReminder-<version>.zip` from the [latest release](https://github.com/ninjaalex888/BerserkingReminder/releases/latest).
2. Extract it into the WoW Forever client's `Interface\AddOns` folder, so you end up with
   `Interface\AddOns\BerserkingReminder\BerserkingReminder.toc`. During the beta the client folder is `_classic_beta_`.
3. Restart the game (or `/reload`) and check that **Berserking Reminder** is ticked in the AddOns list at
   character select.

The green **Code → Download ZIP** button works too, but rename the extracted folder from
`BerserkingReminder-main` to `BerserkingReminder`. WoW only loads an addon whose folder name matches its `.toc`.

If the addon shows as out of date, your client is newer than interface `16001` (Forever 1.60.1).
Get the current number with `/dump select(4, GetBuildInfo())` and put it on the `## Interface:` line of
`BerserkingReminder.toc`, or tick **Load out of date AddOns**.

## Commands

Type `/berserk` or `/bzr` on its own to list these in game, along with your current settings.

| Command | What it does |
|---|---|
| `/berserk unlock`, `/berserk lock` | Unlock to drag the icon where you want it, then lock it in place |
| `/berserk test` | Preview the reminder for 10 seconds |
| `/berserk scale <0.5-3>` | Icon size |
| `/berserk always` | Also show it out of combat when it's ready (off by default) |
| `/berserk sound` | Ping when it comes off cooldown mid-fight (on by default) |
| `/berserk on`, `/berserk off` | Turn the reminder on or off |
| `/berserk status` | What the addon sees right now |
| `/berserk reset` | Restore all defaults |

Settings are saved account-wide.

## Notes for WoW Forever

- **Combat restrictions.** Forever runs the modern (Midnight 12.x) addon API, which hides cooldown timers
  from addons during combat. It still tells addons whether a cooldown is running, and that's all this
  reminder needs, so it works mid-fight. If a client ever hides that too, the icon falls back to showing
  Berserking with a cooldown swipe for the whole fight.
- **Global cooldown.** Casting other spells doesn't hide the icon. A cooldown no longer than the global
  cooldown counts as ready.
- **Which characters.** It looks for Berserking in your spellbook (the mana, rage or energy version, or the
  spell's name), so only Trolls ever see it.
- **Position.** It starts just to the right of [Well Fed Reminder](https://github.com/ninjaalex888/WellFedReminder)'s
  default spot so the two icons don't overlap. Move it with `/berserk unlock`.
