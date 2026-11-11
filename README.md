# Doomscroll Rehab

The longer you scroll short videos, the slower they load. No blocking, no lock screen. The feed just gets worse until putting the phone down is the easier choice. To get full speed back you have to talk to an AI, which asks what you actually want from the next few minutes.

Built at c0mpiled-18, the YC Startup School Hackathon in Taipei, for the topic "AI Powered Consumer Products for a Billion People".

## Why slowing instead of blocking

- Blockers get switched off. A hard limit feels imposed, so people remove it.
- Delay works by itself. In a study of the one sec app, a short wait before opening a target app made people abandon 36% of attempts, and attempts fell 37% over six weeks. In the follow-up experiment the delay alone reduced use; the persuasive message did not. (Grüning, Riedel, Lorenz-Spreen, PNAS 2023)
- A lot of feed time is not wanted time. One estimate attributes 31% of social media use to self-control problems. (Allcott, Gentzkow, Song, American Economic Review 2022)
- Platforms have measured the reverse. Google found that 100 to 400 ms of added latency cut searches per user by 0.2% to 0.6%. (Brutlag, 2009)
- Cutting back is at least as durable as quitting. In a 619-person trial, people who used their phone one hour less per day were using it 45 minutes less four months later; people who quit entirely for a week, 38 minutes less. (Brailovskaia et al., Journal of Experimental Psychology: Applied, 2022)

We found no published study of network throttling as an intervention. That is the experiment this app runs.

## How it works

1. All phone traffic goes through a small proxy. It sees hostnames only, never content.
2. Traffic to feed hosts (Instagram, Threads, TikTok, YouTube video, Hongguo) starts a session clock.
3. For the first few minutes the feed runs at full speed. After that the speed falls every minute, from 3 Mbps down to 40 kbps, which is below the lowest video bitrate, and each new connection waits up to 3 seconds.
4. Everything else, such as messages, maps and search, is untouched.
5. Ten minutes away from the feed resets the session.
6. Each day the full-speed window is 7% shorter than the day before, over fourteen days.
7. Asking for speed back opens a chat with the negotiator. It uses motivational interviewing: one open question at a time, no lecturing. A specific reason and a stopping point earn up to 10 minutes. Three boosts a day.

## Run it

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

- The throttling is real. It is done by a proxy on a laptop, so the phone has to be on the same network.
- Apps that ignore the system proxy are not slowed. Their mobile web versions are.
- The shipping version is an on-device local VPN: Android first with `VpnService`, which can be limited to chosen apps. On iPhone, a packet tunnel extension can only tell feeds apart by hostname.
- The host list for Hongguo is a best guess and should be checked against what the dashboard shows.
- The proxy and dashboard accept connections from private network addresses only. Do not expose them to the internet.

## Files

- `server.js`: proxy, session clock, token-bucket throttle, negotiator, dashboard API
- `public/index.html`: dashboard
- `landing/`: landing page
