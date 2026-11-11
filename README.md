# Doomscroll Rehab

The longer you scroll short videos, the slower they load. No blocking, no lock screen. The feed just gets worse until putting the phone down is the easier choice. To get full speed back you have to talk to an AI, which asks what you actually want from the next few minutes.

Built at c0mpiled-18, the YC Startup School Hackathon in Taipei, for the topic "AI Powered Consumer Products for a Billion People".

**Status:** Android first. The Android app in this repo is what we are building and testing right now. An iOS version will follow.

**Landing page and waitlist:** https://doomscrolling-rehab.vercel.app

## Why slowing instead of blocking

- Blockers get switched off. A hard limit feels imposed, so people remove it.
- Delay works by itself. In a study of the one sec app, a short wait before opening a target app made people abandon 36% of attempts, and attempts fell 37% over six weeks. In the follow-up experiment the delay alone reduced use; the persuasive message did not. (Grüning, Riedel, Lorenz-Spreen, PNAS 2023)
- A lot of feed time is not wanted time. One estimate attributes 31% of social media use to self-control problems. (Allcott, Gentzkow, Song, American Economic Review 2022)
- Platforms have measured the reverse. Google found that 100 to 400 ms of added latency cut searches per user by 0.2% to 0.6%. (Brutlag, 2009)
- Cutting back is at least as durable as quitting. In a 619-person trial, people who used their phone one hour less per day were using it 45 minutes less four months later; people who quit entirely for a week, 38 minutes less. (Brailovskaia et al., Journal of Experimental Psychology: Applied, 2022)

We found no published study of network throttling as an intervention. That is the experiment this app runs.

## Two builds, one engine

- `app/`: the Android app. A local VPN that never leaves the phone applies to the feed apps you pick and points them at a throttling proxy inside the app. No laptop, no shared Wi-Fi, no host list. Measured on a Galaxy A54 with Instagram: with the limit at 40 kbps, traffic held at 39 to 40 kbps.
- `server.js` and `public/`: the same engine as a laptop proxy with a web dashboard, for phones we cannot install on and for showing the numbers on a big screen.

Both are in English and Traditional Chinese.

## How it works

1. Feed traffic goes through a small proxy: inside the app on Android, or on the laptop. It sees hostnames only, never content.
2. Traffic from the chosen feed apps (Instagram, Threads, TikTok, YouTube, Hongguo) starts a session clock.
3. For the first few minutes the feed runs at full speed. After that the speed falls every minute, from 3 Mbps down to 40 kbps, which is below the lowest video bitrate, and each new connection waits up to 3 seconds.
4. Everything else, such as messages, maps and search, is untouched.
5. Ten minutes away from the feed resets the session.
6. Each day the full-speed window is 7% shorter than the day before, over fourteen days.
7. Asking for speed back opens a chat with the negotiator. It uses motivational interviewing: one open question at a time, no lecturing. A specific reason and a stopping point earn up to 10 minutes. Three boosts a day.

## Where the AI is

- Coach: you describe how you scroll in your own words. The model sets the four numbers that shape your curve (full-speed window, daily tightening, ramp length, floor speed) and says why. It also sees the sessions the proxy has measured.
- Negotiator: the model decides whether you get speed back and for how long.
- Feed finder: the model reads the hostnames your phone is loading and picks out the ones that are feeds, so new apps are covered without a hand-kept list. It can only add hosts the phone really contacted.
- Usage report ("Said versus did"): every boost is logged with the words you used to ask for it. When the boost runs out, the proxy watches for two minutes; feed traffic in that window marks the promise broken, silence marks it kept.
- `GET /api/report` is plain arithmetic, no model: promises kept and broken, minutes by hour of day, how long you stayed after slowing began, and which host you came from.
- "Write my report" sends those numbers to the model, which answers in at most 90 words, quotes your own words back where a promise was broken, names the riskiest hour and proposes one change to the plan. The change is applied only if you press "Apply to my plan".
- "Load demo week" swaps in a fabricated week, labelled "Demo data, not measured" and never mixed with the real log.

The throttle itself is plain code. The model decides how hard it bites, for whom, and when it lets go.

## Run the Android app

Needs Flutter 3.41 or later and a phone on Android 10 or later.

```bash
cd app
flutter run --dart-define-from-file=../.env
```

Pick the apps to slow, press "Turn on" and accept the VPN prompt. Then open one of those apps. The app shows the speed, the session clock, the curve, the coach, the negotiator, the said-versus-did list and the server names the feed apps are loading. Without a `.env` the AI features say that no model is configured.

How the VPN is used: it routes no traffic. Android only lets a VPN do two things we need, which are applying to chosen apps and telling them to use a proxy. The proxy listens on `127.0.0.1` inside the app and connects straight to the real servers.

## Run the laptop proxy

Needs Node 18 or later. No dependencies.

```bash
node server.js
```

Then open `http://localhost:3000`.

To connect the negotiator to a model, copy `.env.example` to `.env` and set `LLM_BASE_URL`, `LLM_API_KEY` and `LLM_MODEL` for any OpenAI-compatible endpoint. Without it the chat falls back to two scripted replies, and the dashboard says so.

### Phone setup

1. Put the phone on the same Wi-Fi as the laptop.
2. In the phone's Wi-Fi settings, set the proxy to manual: the laptop's IP address, port `8888`. The dashboard shows the address.
3. Open a feed. Its hostnames appear on the dashboard. If an app's video host is not being slowed, press "Slow this" next to it.

The demo controls speed up the session clock so a twenty-minute session fits in a short demo.

## What this prototype is and is not

- The throttling is real in both builds, and measured.
- The Android app relies on feed apps honouring the proxy the VPN announces. Instagram does. An app that ignored it would not be slowed; the fix for that is to carry the packets through the tunnel, which this build does not do.
- Tested with Instagram on one phone. Threads, YouTube and Facebook are selectable but not measured. TikTok and Hongguo were not installed on the test phone.
- The app keeps its log in memory, so it is lost when the app is closed. The model key is compiled into the debug build, which is fine for a demo and wrong for a release.
- A session is counted while feed traffic flows. Background refreshes by a feed app can keep a session alive longer than the user was looking at it.
- No iPhone build. There, a packet tunnel extension can only tell feeds apart by hostname, and VPN apps need an organisation developer account.
- On the laptop build, the host list for Hongguo is a best guess and should be checked against what the dashboard shows.
- Model timings on GMI Cloud with `Qwen/Qwen3.8-Flash`: negotiator about 3 seconds, coach about 18, report about 26.
- The proxy and dashboard accept connections from private network addresses only. Do not expose them to the internet.

## Files

- `app/android/app/src/main/kotlin/tw/rehab/doomscroll_rehab/`: `RehabVpnService.kt` (the VPN), `ThrottleProxy.kt` (the in-app proxy), `Engine.kt` (session clock, token bucket, promises)
- `app/lib/main.dart`: the app screen, coach, negotiator and report
- `server.js`: laptop proxy, session clock, token-bucket throttle, coach, negotiator, feed finder, report, dashboard API
- `public/index.html`: dashboard
- `landing/`: landing page
