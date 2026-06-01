# CNFix

**Readable English (or pinyin) names for Chinese players, guilds, and NPCs in World of Warcraft 1.12.1 (client build 5875).**

> ⚠️ **Work in progress.**
> **Latest release:** https://github.com/Milky691/CNFix1.12/releases

CNFix is a small client add-on (a DLL plus a companion UI addon) for WoW 1.12
private/custom servers. It shows Chinese **player names, guild names, and NPC
names** in English — both on the floating names above heads in the 3D world and
across the interface. You pick how names read: **English** (meaning) or
**Pinyin** (sound), switchable in-game at any time.

It changes the **names you see**, not the chat people type. When you invite,
whisper, trade, mail, or target someone, the game still uses their real Chinese
name behind the scenes, so everything reaches the right person.

> **Optional dependency — WoWTranslate.** WoWTranslate is strongly recommended
> for contextual English names. Without it, CNFix still works, but will fall
> back to pinyin/word substitution and may be less accurate.
> **Link:** `<add WoWTranslate link here>`

<img width="1571" height="869" alt="frames" src="https://github.com/user-attachments/assets/c72a19be-0d32-4913-856b-d3a9467eb4ed" />
<img width="1571" height="869" alt="who" src="https://github.com/user-attachments/assets/cb646ff0-ef30-4a18-b626-d273d722c58b" />

---

## What it translates

**In the 3D world**
- Floating overhead names above players and creatures.
- Guild tags (`<Guild>`) and NPC subnames (`<subname>`) shown under those names.
- A small `*` is added after any overhead name CNFix translated, so you know the
  real name is Chinese. Names that were already English, or that couldn't be
  translated, get no mark. The overhead pass has its own on/off toggle.

**Across the UI**
- `/who` results, friends list, guild roster.
- Party/raid frames and unit frames.
- Mail and the Group Finder.
- World-map mouseover (player dots).
- Inspect window and Trade window names.
- Right-click player dropdown menu (title and entries).

Tooltips and nameplates are deliberately left to **WoWTranslate**, so the two
addons coexist instead of fighting over the same text.

## Two ways to read names

| Mode | Example | Notes |
|---|---|---|
| **English** (default) | `小龙女 → LittleDragonGirl` | meaning, as one readable word |
| **Pinyin** | `小龙女 → XiaoLongNu` | how it sounds |

Switch between them anytime in the settings — it's one install, not two separate
builds. A leading rank or title (e.g. an NPC role) is kept separate from the
name in both modes.

## Names stay clickable and reach the right person

- Invite, whisper, party/guild invite, trade, mail, target, and `/who` all use
  the player's actual Chinese name — CNFix swaps the displayed name back before
  anything is sent to the server.
- Hyperlinks and chat links remain intact and clickable.
- CNFix does **not** translate the chat sentences people type — only names and
  labels. For translating chat, use a dedicated chat-translation addon.

## How a name is resolved

Every name is resolved locally in the DLL, in this order:

1. **Learned names** — contextual translations harvested from WoWTranslate and
   saved to `CNFix_learned.txt`. Once learned, a name is instant forever, even
   offline.
2. **Game-term glossary** — fixed WoW terms (roles, dungeons, raids), e.g.
   `治疗 → Healer`, `熔火之心 → Molten Core`.
3. **Word/character substitution** — a readable composed meaning for any name
   not yet learned.
4. **Pinyin** — romanization (used as the fallback, and for all names in Pinyin
   mode).

Layers 2–4 are instant and offline. Contextual names (layer 1) appear as
WoWTranslate translates what's on your screen; CNFix then remembers them in
`CNFix_learned.txt`, which grows as you play and can be shared or shipped
pre-filled so common names are good from first launch.

---

## Install

1. Copy these three files into your game folder, next to `WoW.exe` and your
   other `.dll` files:
   - `CNFixEnglish.dll`
   - `CNFix_data.txt` — the bundled dictionary the DLL reads at startup
   - `CNFix_learned.txt` — the learned-names file (grows over time)
2. Open **`dlls.txt`** in that same folder (create it if it doesn't exist) and
   add the file name on its own line:
   ```
   CNFixEnglish.dll
   ```
3. Copy the **`CNFixNames`** folder into `Interface\AddOns\`.
4. *(Recommended)* install **WoWTranslate** so contextual English names can be
   learned.
5. Launch the game.

Open settings with the minimap button or `/cnfix`: master on/off, plus toggles
for Social, Unit Frames, Overhead Names, real-time learning, and the
**English / Pinyin** switch. Settings are saved account-wide.

**Uninstall:** remove the `CNFixEnglish.dll` line from `dlls.txt`, delete the
DLL (and the `CNFix_*.txt` files), and remove the `CNFixNames` addon folder.

---

## Compatibility & safety

- Built for **WoW 1.12.1, client build 5875** only. On load, the DLL verifies
  the client; if it doesn't recognise the build, it installs nothing and does
  nothing — a safe no-op rather than a crash. If a game update changes the
  client, you'll need an updated CNFix.
- CNFix makes **no network calls** of its own; all translation data is either
  bundled or harvested from WoWTranslate.

## Troubleshooting

**Names are still Chinese**
- Confirm `CNFixEnglish.dll` and `CNFix_data.txt` are next to `WoW.exe`.
- Confirm `CNFixEnglish.dll` is listed in `dlls.txt`, on its own line.
- Fully close and restart the game.

**Some English names look a bit odd**
- Expected for names that are wordplay and don't translate cleanly. Switch to
  Pinyin mode for consistent, tidy names.

**I want a log of what it's doing**
- Create an empty file named `WoWRomanizer.debug` next to the DLL. CNFix will
  write `WoWRomanizer.log` in the same folder. Delete the `.debug` file to stop.

---

## Building from source

You only need this to compile it yourself.

- A 32-bit C++ compiler (the client is 32-bit); these notes use MinGW-w64
  (`i686-w64-mingw32-g++`).
- MinHook is included as source under `source/minhook/`.

```
cd source
bash build.sh
```

This builds `CNFixEnglish.dll` from `src/CNFixEnglish_source.cpp`. Translation
data is included as generated headers (`pinyin_map.h`, `meaning_map.h`,
`glossary_map.h`, plus `wnr_common.h`) in `src/`.

---

## Author

**Milky**

## License & credits

MIT licensed (see `LICENSE`). Translation data derives from CC-CEDICT
(CC BY-SA); pinyin from pypinyin; hooking via MinHook (BSD). See
`THIRD_PARTY_NOTICES.txt`. Not affiliated with or endorsed by Blizzard
Entertainment. See `DISCLAIMER.txt` before use.
