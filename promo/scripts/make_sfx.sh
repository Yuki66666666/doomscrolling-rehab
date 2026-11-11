#!/usr/bin/env bash
# Sound effects made from filtered noise with ffmpeg, so there is nothing to license.
# Run from promo/:  bash scripts/make_sfx.sh
set -e
mkdir -p assets/sfx
F="ffmpeg -hide_banner -loglevel error -y"

# swipe, two takes: a short band of pink noise that fades in and out
$F -f lavfi -i "anoisesrc=d=0.24:c=pink:seed=3:a=0.9" -af "highpass=f=900,lowpass=f=5200,afade=t=in:d=0.09,afade=t=out:st=0.10:d=0.14,volume=2.2" -ar 48000 -ac 2 assets/sfx/swipe-a.wav
$F -f lavfi -i "anoisesrc=d=0.34:c=pink:seed=11:a=0.9" -af "highpass=f=600,lowpass=f=3400,afade=t=in:d=0.14,afade=t=out:st=0.14:d=0.20,volume=2.2" -ar 48000 -ac 2 assets/sfx/swipe-b.wav

# bubble pop: a very short mid-band burst
$F -f lavfi -i "anoisesrc=d=0.10:c=white:seed=5:a=1" -af "bandpass=f=1100:w=900,afade=t=in:d=0.003,afade=t=out:st=0.012:d=0.085,volume=38dB,alimiter=limit=0.5" -ar 48000 -ac 2 assets/sfx/pop.wav

# phone set down: low thump
$F -f lavfi -i "anoisesrc=d=0.22:c=brown:seed=7:a=1" -af "lowpass=f=160,afade=t=in:d=0.005,afade=t=out:st=0.02:d=0.2,volume=6.0,alimiter=limit=0.8" -ar 48000 -ac 2 assets/sfx/thud.wav

# button click
$F -f lavfi -i "anoisesrc=d=0.03:c=white:seed=9:a=0.9" -af "highpass=f=2200,afade=t=out:st=0.004:d=0.024,volume=1.6" -ar 48000 -ac 2 assets/sfx/click.wav

ls -la assets/sfx
