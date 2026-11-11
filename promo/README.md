# Doomscroll Rehab promo video

A 23.4 second vertical clip (1080x1920, 30 fps) for Threads, built with HyperFrames so every layer stays editable.

## Finished files

| File | Version | Language |
| --- | --- | --- |
| `out/doomscroll-rehab-A-zh.mp4` | A: sends people to the waitlist; the phone is the hero, ends on the pink button | 繁體中文 |
| `out/doomscroll-rehab-A-en.mp4` | A | English |
| `out/doomscroll-rehab-B-zh.mp4` | B: for replies and reposts; Slo is bigger, ends on a question | 繁體中文 |
| `out/doomscroll-rehab-B-en.mp4` | B | English |

## Where to change things

- `STORYBOARD.md`: copy, shot list with seconds and easing, and the list of things that must not appear.
- `compositions/film.html`: the film. Layers are separate elements: `#slo` (ghost), `#phone` (frame and six feed tiles), `#bubbles`, `#caps` (captions), `#endcard`.
  - All on-screen text is in the `STR` table at the top of the script, one entry per language.
  - Positions for versions A and B are in the `POS` table just below it.
  - Timing is the list of calls after that, grouped by shot.
- `index.html`: the two variables (`lang`, `version`) and the sound effect cues.
- `assets/slo.png`: the ghost cut out of `../brand/icon-1024.png` by `scripts/make_assets.py`.
- `assets/slo-noeyes.png`: the same ghost with the eyes painted out by `scripts/make_eyes.py`. The eyes are drawn as `<svg id="slo-eyes">` in `film.html` so they can blink and look around; the `eyes()`, `look()` and `blink()` calls near the end of the script are the schedule.
- `assets/sfx/*.wav`: made from filtered noise by `scripts/make_sfx.sh`. No outside audio.

## Render

```bash
npx hyperframes render -o out/doomscroll-rehab-A-zh.mp4 --variables '{"lang":"zh","version":"a"}' -w 1
```

Change `lang` to `en` and `version` to `b` for the other three. Each takes about a minute. `npx hyperframes check` lints the project; `npx hyperframes snapshot --at 0,9,17.9` writes stills to look at before rendering.

The Chinese text uses Microsoft JhengHei from this Windows machine. A render on another machine or in the cloud needs a font file in `assets/fonts/` and an `@font-face` pointing at it.
