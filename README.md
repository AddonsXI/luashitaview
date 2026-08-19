# luashitaview v1.2.0

View and edit your equipment sets in game, without touching a Lua file.

It works with LuAshitacast but is not affiliated with it or endorsed by it.

## Install

1. Drop the `luashitaview` folder into `Game/addons/`.
2. Type `/addon load luashitaview` in game.

Add it to your default script if you want it running every launch.

## Commands

`/lua`, `/gear`, `/sets` or `/luashitaview` to toggle the window.

`/sets debug` to log what the addon is doing, for reporting a problem.

## Features

- Real items with icons on an equipment grid. Click a slot to change it and drag equipment around.
- Search your bags or all items by name or by stat, filtered to your job and level.
- Set your augments, bags and priority.
- In a `_Priority` set you can list several pieces in one slot, and the game wears the best one your level allows. One click turns a normal set into one.
- Backs the file up first, and touches only the sets you edited.
- Undo, redo, and restore any backup in one click.
- Profile Checks points out what is broken in your profile, and offers to fix it where it can.
- Compare two sets side by side.

![config](config.png)

## Good to know

- Equipment you do not own is marked with a small orange dot.
- A slot your profile fills in with code shows as `{}`. The addon cannot change those, and leaves them exactly as they are.
- Experimental: let a profile skip past equipment you do not own, so you can list pieces you are still working towards. Offered on BasicLuas profiles, and on standard ones that call `gFunc.EvaluateLevels`.

## Profile styles

Standard LuAshitacast profiles are fully editable, as are gcinclude, Rag's, miniswap and BasicLuas. A few shapes open read only, like J-Cast, where the sets only exist while the file runs.

## Credits

Thanks to Thorny for [LuAshitacast](https://github.com/ThornyFFXI/LuAshitacast), which this addon exists to serve.

More addons @ https://github.com/AddonsXI
