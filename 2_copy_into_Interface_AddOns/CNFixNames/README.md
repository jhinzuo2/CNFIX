# CNFix — instant English meaning names (layered)

Every Chinese player/guild/group name is shown as a readable **English meaning**
instantly across who / party / raid / LFG / guild / friends / nameplates — never
raw Chinese, never laggy. Quality upgrades over time toward Google translations.

## How it works (three local layers, all instant in the DLL)
1. **Learned glossary** — Google meanings harvested from WoWTranslate, saved to
   `CNFix_learned.txt` next to WoW.exe. Instant forever once learned, even offline.
2. **WoW glossary** — fixed game terms (Molten Core, etc.).
3. **Smart compose** — readable component substitution (e.g. 小龙女 -> "Little
   Dragon Girl") for any name not yet learned. Clean, spaced, capitalized.

The optional **CNFixNames** addon nudges WoWTranslate to translate the names you
can see, so the DLL can harvest them into the learned glossary and upgrade the
display. The DLL works without the addon (layers 2-3); the addon just makes the
learned layer grow.

Invites/whispers/targeting use the real name (the DLL swaps it back).

## Install
1. Put **CNFixEnglish.dll** and **CNFix_learned.txt** next to WoW.exe; add
   `CNFixEnglish.dll` to `dlls.txt`.
2. (Optional but recommended) install **WoWTranslate** + the **CNFixNames**
   addon to grow the learned glossary toward Google quality.

> **WoWTranslate is strongly recommended for contextual English names. Without
> it, CNFix still works, but will fall back to pinyin/word substitution and may
> be less accurate.**

## The learned file grows
`CNFix_learned.txt` gains entries as you play (harvested from WoWTranslate). You
can share it, or ship a big pre-harvested one so common names are Google-quality
from first launch.
