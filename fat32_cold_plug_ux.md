# FAT32 cold-plug slowdown — user impact reference

Reference notes on the user-experience consequences of the macOS USB MSC
mount-phase slow window made visible by PR #10967.

For methodology and reproduction steps see `reproduce-this.md`. This file
is the prose translation of those measurements into "what will users
actually feel."

---

## When the slowdown actually shows up

The slow window only triggers on a real USB re-enumeration. That means
cold-plug events: plugging the board into a Mac for the first time after
powering on, unplugging and re-plugging the cable, switching between USB host
and battery power and back, and sometimes after a deep-sleep wake. It does
**not** trigger on a soft reset (Ctrl-D in the REPL, saving `code.py` and
letting CircuitPython auto-reload, or `microcontroller.reset()`) — those keep
the existing USB enumeration intact, so macOS doesn't redo the heavy
mount-time reads, and CPU performance stays at baseline.

## What users will actually notice

For about 20 seconds after a fresh plug-in (with a FAT32 card), every Python
operation runs roughly three times slower than normal. Sensor reads are
slower, `print()` output drips out, GIF frames stutter, NeoPixel animations
crawl — anything CPU-bound. Then there's a sharp cliff and everything snaps
back to full speed; there's no gradual ramp. After that 20 seconds, the only
ongoing cost is a couple of `TEST_UNIT_READY` polls per second on the bus,
which is too small to feel.

## Who this hurts

The user it hits hardest is what bablokb described in #10733 — a
"wake → do work → deep-sleep" pattern that finishes inside 20 seconds. That
program runs at 3× cost on every cycle and never gets to the fast steady
state. Same idea for kiosk-style "press button to read sensor" projects that
re-enumerate USB to log to a host PC. Anyone doing serial-heavy debugging
will also feel the first 20 seconds of REPL responsiveness as sluggish on
every plug-in, though their work usually stretches past that window.

## Who barely feels it

Long-running projects (data loggers running for hours, always-on dashboards)
pay the 20-second cost once at boot and then it's invisible. Anyone using a
FAT16-formatted SD card (the default for ≤ 2 GB cards) basically doesn't
see it at all — about half a second of bench impact. Battery-powered
standalone projects with no USB host attached don't see it because nothing
is polling. And ordinary REPL-driven development, where you save `code.py`
and let CircuitPython auto-reload, doesn't trigger it because there's no
re-enumeration.

## Mitigation

For users in the affected cohort, dhalbert's proposed `settings.toml` opt-out
gives a clean way to disable the SD-as-USB-MSC exposure entirely, which
removes both the 20-second slow window and the ongoing TUR polling. For
everyone else the defaults are fine — the SD mounts on macOS like the user
expects, and the cost is bounded to a one-time event after a fresh plug.

---

## Quick reference (the underlying numbers)

| Card | Format | Mount-phase READ(10) | CPU slow window | Slowdown |
|---|---|---|---|---|
| 64 MB | FAT16 | 67 | ~0.5 s (1 iter) | 1.9× peak |
| 8 GB | FAT32 | 694 | ~19 s | 3.6× peak |
| 32 GB | FAT32 | 703 | ~19 s | 3.4× peak |

Steady-state TUR polling: ~1/s per LUN regardless of card. CDC throughput
cost during steady state: ~19 % on print()-heavy workloads. CPU steady state
matches baseline-main exactly. CircuitPython soft-reset preserves the USB
enumeration so the slow window is not re-entered on `code.py` reload.
