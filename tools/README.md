# DragonUI checks

Run from the repository root with Lua 5.1:

```sh
lua5.1 tools/achievement_search_test.lua
lua5.1 tools/bartender_handoff_test.lua
lua5.1 tools/feral_ap_tooltip_test.lua
lua5.1 tools/guild_bank_slots_test.lua
lua5.1 tools/keybinding_search_test.lua
lua5.1 tools/latency_test.lua
lua5.1 tools/loot_triage_test.lua
lua5.1 tools/minimap_zoom_test.lua
lua5.1 tools/movement_speed_test.lua
lua5.1 tools/quest_givers_test.lua
lua5.1 tools/review_regression_test.lua
lua5.1 tools/window_positions_test.lua
lua5.1 tools/upstream_integration_test.lua
lua5.1 tools/ui_scale_test.lua
lua5.1 tools/profile_actions_test.lua
lua5.1 tools/raid_browser_skin_test.lua
lua5.1 tools/shadowuf_handoff_test.lua
lua5.1 tools/tooltip_cursor_test.lua
lua5.1 tools/tracker_quest_click_test.lua
lua5.1 tools/classic_skin_test.lua
python3 tools/build_classic_skin.py --check
python3 tools/recolour_grounds.py --check
python3 tools/link_icon_bubble.py --check
```

The Classic skin test covers the default skin touching no widget method, the swap on texture and button setters, what painted before the settings were readable, unrelated paths left alone, the skin read once per load, every baked sheet being on disk with its Forever sheet still there, a class's spec sheets sharing one three-tree sheet, spelled-out extensions, and unit frames drawing Forever's geometry only under Classic. It does not draw anything; how the art sits needs a game client.
The Bartender4 hand-off test covers the per-part owners (action bars; micro menu and bags; XP and reputation bars, whose hand-over turns Bartender4's on where DragonUI's were): handing DragonUI's modules over and keeping the matching Bartender4 modules off without changing its settings, the once-per-change login lines, restoring only the handed modules on a later load (never mid-session), DragonUI action bars next to a loaded Bartender4 (its whole bar set off, the stock buttons, possess bar, grid and talent event put back, after combat on a reload in combat, "Use Blizzard Vehicle UI" kept off), the bar layout saved at logout and given to Bartender4's bars once on the load that hands them over, editor mode unlocking Bartender4, and the old Use Bartender4 setting. It does not load mainbars.lua or noop.lua, whose Bartender4 paths need a game client.
The Shadowed Unit Frames hand-off test covers the flag (set only with it loaded, and it an OptionalDep so it loads first), the login line once per character until a load without it, every unit frame file but uf_core and text_system returning before it touches a global or the addon (and doing work without it), and UF.IsEnabled answering off for every frame. It does not load castbar.lua or show the frames in a game client.
The tooltip cursor test covers the cursor-anchored tooltip with offsets: following the cursor, hiding the moment the world unit under it is left (the engine's ANCHOR_CURSOR tip did; the offset follow lingered 2-3 s like a corner tip), and leaving unit frame tips, object tips and the zero-offset engine follow alone.
The quest givers test covers the world map's quest giver pins against a faked mod-quest-map: no requests at all once the hello goes unanswered (and its echo ignored), parsing the server's rows, hiding trivial quests unless the filter is on, the blue daily and grey trivial icons, the tooltip, no refetch on objective updates but one when a quest is taken or on level-up, the busy retry (only for the map still shown, with a later try once the retries run out), a lost answer, a refetch after entering another zone, nearby givers sharing one pin with a count (the same giver twice listed once, split again when zoomed in), and the repeatable filter.
The Raid Browser skin test covers the stock art hidden, red List Me / Set Comment / Leave Queue / Send Message / Invite / Refresh buttons, the raid list, comment box and member list each fitting their inset over the button row, the Browse buttons spread evenly across the seats, and a tab another addon adds later (RaidFinder's third) joining the strip, which re-chains on every open.
The guild bank slots test covers the bank's 98 slots until the realm whispers its tab size (EvermoreGuildBank, slots:98-196; other senders, channels, prefixes and out-of-range counts ignored), 196 slots in 14 rows of 14 at the same icon size, hiding the extras again at 98, the window growing once to fit 14 rows at its width (saved with the rows it was sized for, never taller than the screen or under its minimum) and shrinking back on a 98-slot realm, and the realm's last count kept by realm name for the next session's first open (forgotten when the realm says 98), and which window opens: DragonUI's with the Bagster bags on, and with them off once the realm says more than 98 (the stock vault, with its 98 buttons, comes back when it says 98).
The minimap zoom test covers remembering the outdoor and indoor levels per character, putting each back after a reload or login (the indoor one on the first indoor visit), ignoring zoom calls made before the world is entered, the zoom buttons' enabled state, clamping, telling the modes apart when both levels match, and the IsIndoors fallback without the zoom CVars.
The movement speed test covers the reading (percent of 7 yd/s, vehicles, the last reading dimmed when standing), the spot under the ring for each minimap style, stepping beside the durability figure, editor drag/reset and the toggle.
The latency test covers the self-whisper round trip (ignoring other senders, channels, prefixes and stale answers), the colour bands, the reading climbing while the server is slow, the 30 s resend, dropping a ping across a loading screen, hanging under the speed line or taking its spot, editor drag/reset and the toggle.
The key binding search test covers filtering by command name and key, kept section headers, scrolling the filtered list, selection highlight, deselect on focus and reset on close.
The achievement test covers reward matching, translated type aliases, tier chains,
UI selection, cache reuse, debounced typing and invalidation while shown/hidden.
The regression test loads the production modules with Wrath-style API mocks and
covers position-preset round trips/rejection/rollback, vendor acknowledgements and
auto-repair sequencing, and mail capacity/timeout/COD/GM/close handling.
The texture check requires Pillow. These checks do not simulate protected frames or
prove server behavior in a real client.

Not yet checked in a game client: the Classic skin, the guild bank's 196 slots (needs the realm's edited Wow.exe), the saved minimap zoom, the Raid Browser skin (with or without RaidFinder's tab), the server lag line under the minimap, the quest giver pins on the world map (and their grouping), the movement speed line under the minimap, the Bartender4 hand-off (owner switch, stock buttons restored next to it, layout hand-over), the Key Bindings search box, position presets and window dragging across the panels, grey-item
auto-sell and auto-repair, Open All with full bags, achievement search, and the unit-frame styles
and combo-point modes after the last upstream merge. Also not checked: portrait-off unit frames
(beta) with their decorations and icons, /reload in an LFG party, tooltip sharing with other
addons, empty-loot auto-hide, large alt-gold totals, and Mind Sear / Volley ticks.

After merging upstream, `python3 tools/recolour_grounds.py --check` says whether `ui-background-rock`
and `ui-background-marble` need their warm brown recolour regenerated.

See [the October 28 upstream integration report](UPSTREAM-2026-10-28.md) for source
parents, conflict decisions, validation and the pending client/delivery checklist.

Measure behavioral line coverage with Lua/luac 5.1:
`python3 tools/measure_coverage.py --output /tmp/dragonui-coverage.json`.
See `coverage-baseline.json` for the measured baseline and the integration report
for remaining gaps; this is not full line or branch coverage.
The loot triage test covers ranking by stack value (cheapest first, the marks cap, greens only at quality 2, consumables only when allowed), the items never suggested (crafting materials, recipes, Mining Pick, fishing pole, Hearthstone, quest items, unsellable items), the static and pulsing border, the Alt + Right Click star (not Alt + Left, not with the auction house open, not when bag sort locks with Alt + Right Click) and the next item moving up, the loot coins (dear loot and quest items only), and when marks show: while the loot will not fit, at 4 or fewer free slots, always, or never.
The tracker quest click test covers a tracked quest's click (and the menu's View in Quest Log and a quest timer) opening the world map's quest log on that quest's page, showing a hidden panel for it, and falling back to the stock quest log with the map module off, the map closed or the panel hidden in combat, or no quest ID. It does not open the map in a game client.
