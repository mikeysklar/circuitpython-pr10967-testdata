# Reproducing the PR #10967 SCSI + CDC measurements

This guide lets a peer reproduce, on their own bench, every measurement that
backs the PR-thread comments on
[adafruit/circuitpython#10967](https://github.com/adafruit/circuitpython/pull/10967):

1. **SCSI evidence** — baseline-main returns `GOOD` to `PREVENT_ALLOW_MEDIUM_REMOVAL`
   on both LUNs; PR returns `CHECK_CONDITION + ILLEGAL_REQUEST`. macOS only
   mounts the SD on the PR firmware.
2. **TUR polling, steady state** — macOS keeps polling `TEST_UNIT_READY` at
   ~1/s per LUN (~2/s total) indefinitely after the mount completes, with no
   backoff or tapering.
3. **CDC throughput cost** — steady-state polling steals ~19 % of `print()`
   bandwidth over USB CDC. Pure-CPU compute is unaffected (~1.7 %, noise).
4. **Slow window** — for **~17–20 s** after USB re-enumeration, CPU work runs at
   **~2.8–3.4× slower** than steady state. Caused by macOS's heavy block-read
   pass (~700 `READ(10)` commands at 30–70/s) while it parses the LUN1
   partition table. Cliff-edge transition back to steady state once the mount
   completes — bus-side `READ(10)` traffic stops within ±1 s of the bench
   cliff edge, confirming the mechanism. A full physical unplug/replug
   produces a slightly worse window than a RESET-button cold boot, since
   macOS's xHCI cache is also invalidated.

Measurements were captured on macOS 14 (Apple Silicon). Linux/Windows hosts
behave differently and are not in scope.

The three measurement procedures (SCSI capture, CDC bench, slow-window bench)
each require slightly different setup. Read sections 4, 5, and 6 in order; they
build on each other.

---

## Bill of materials

| Item | Notes |
|---|---|
| Adafruit Metro RP2040 | The board with both internal QSPI flash *and* an onboard microSD slot — required for the dual-LUN scenario. |
| Cynthion USB analyzer | Great Scott Gadgets. Default analyzer bitstream. |
| microSD card, FAT32 | A 32 GB card is what the PR thread describes as worst case. An 8 GB card produces the same TUR rate. |
| macOS host | Tested on macOS 14 (Sonoma) on Apple Silicon. |
| Two USB-C cables | One for the Cynthion CONTROL port → Mac. One for Metro RP2040 → Cynthion TARGET A. |

---

## 1. Software setup (Mac)

This mirrors the standalone `cynthion-macos-getting-started.md` in this directory
— if you already followed that, skip to step 2.

```bash
# System deps
brew install python libusb
brew install packetry
brew install wireshark           # CLI only — installs tshark/capinfos/editcap
brew install lsusb

# Python 3.14 venv (system Python 3.9 is EOL and incompatible with cynthion)
python3 -m venv ~/venvs/cynthion
source ~/venvs/cynthion/bin/activate
pip install cynthion dpkt pyshark

# Convenience alias
echo 'alias cyn="source ~/venvs/cynthion/bin/activate && echo cynthion venv active"' >> ~/.zshrc
```

To **build** CircuitPython firmware locally you need the ARM embedded
toolchain — Homebrew's bare `arm-none-eabi-gcc` is *not* sufficient (it lacks
newlib). Install the bundled formula:

```bash
brew install arm-gcc-bin@14
export PATH="/opt/homebrew/Cellar/arm-gcc-bin@14/14.3.rel1_1/bin:$PATH"
arm-none-eabi-gcc --version    # should print 14.3.x
```

Older `arm-gcc-bin@10` is too old for current CircuitPython main and will fail.

---

## 2. Build the two firmware images

You need two UF2s — one from `main` and one from the PR branch.

```bash
git clone --recurse-submodules https://github.com/adafruit/circuitpython.git
cd circuitpython

# Toolchain for both builds
export PATH="/opt/homebrew/Cellar/arm-gcc-bin@14/14.3.rel1_1/bin:$PATH"

# --- Build baseline main ---
git checkout main
git submodule update --init --recursive
make -C mpy-cross
cd ports/raspberrypi
make BOARD=adafruit_metro_rp2040 -j8
cp build-adafruit_metro_rp2040/firmware.uf2 \
   ~/Downloads/firmware_baseline_main.uf2

# --- Build PR #10967 ---
cd ../..
git fetch origin pull/10967/head:pr-10967
git checkout pr-10967
git submodule update --init --recursive
make -C mpy-cross
cd ports/raspberrypi
make BOARD=adafruit_metro_rp2040 -j8
cp build-adafruit_metro_rp2040/firmware.uf2 \
   ~/Downloads/firmware_pr10967.uf2
```

Pre-built UF2s captured during this run are also in the per-test directories:

- `metro_rp2040_baseline_main/firmware_baseline_main_8e45cf19.uf2`
- `metro_rp2040_pr10967/firmware_pr10967_00254fd6.uf2`

---

## 3. Hardware wiring

```
[Mac running Packetry]
        │ USB-C
        ▼
  ┌─────────────────────────┐
  │ Cynthion CONTROL (left) │ ← Mac
  │                         │
  │ TARGET A (right)        │ ← Metro RP2040 plugs in HERE
  └─────────────────────────┘
```

The Mac sees the Metro through the Cynthion's pass-through TARGET A port, and
Cynthion sniffs the bus.

---

## 4. SCSI capture (the PREVENT_ALLOW + TUR-polling evidence)

This is the same procedure for baseline and PR; flash the firmware first, then
capture the cold boot.

### Flash the firmware

1. Hold **BOOTSEL** on the Metro, tap **RESET**, release BOOTSEL → `RPI-RP2`
   appears in Finder.
2. `cp firmware_baseline_main_*.uf2 /Volumes/RPI-RP2/`  (or the PR UF2)
3. Board reboots automatically.

### Capture

```bash
cynthion info                  # confirm "Bitstream: USB Analyzer"
cynthion run analyzer          # load if not already
packetry                       # GUI
```

In Packetry:
- **Speed: Full Speed** (12 Mbit/s)
- Press **Capture** (⌘+B)
- Hit the **Target Power Switch** to power-cycle the Metro for a clean
  cold-boot capture, *or* unplug/replug it from TARGET A.
- After ~75–90 s (long enough to see SET_CONFIGURATION + the
  PREVENT_ALLOW exchange + a handful of TURs), stop capture (⌘+E),
  save as `.pcap` (⌘+S).

For the **TUR-rate measurement**, leave the capture running for 5 minutes
(`pr10967_32gb_5min_01.pcap` is 295 s).

### Extract the SCSI commands

The script `extract_scsi.sh` wraps `tshark -Y "usbms" -V` and parses out
`(frame, time, LUN, opcode, status)` rows. Field-extraction
(`-e scsi.cdb.opcode`) doesn't populate on Cynthion's DLT 288 captures —
this is a raw-USB-2.0 link type without the Linux URB pseudo-headers that
Wireshark's USB dissector expects.

`extract_scsi.sh`:

```bash
#!/bin/bash
# Extract SCSI command/response pairs from a Cynthion USB 2.0 pcap file.
# Usage: ./extract_scsi.sh <capture.pcap>

if [ -z "$1" ]; then
  echo "Usage: $0 <capture.pcap>"
  exit 1
fi

tshark -r "$1" -Y "usbms" -V 2>/dev/null | \
  awk '
    /^Frame [0-9]+:/{frame=$2; gsub(/:$/,"",frame)}
    /Epoch Arrival/{t=$NF}
    /LUN: 0x000/{lun=$NF}
    /Opcode:/{op=$0}
    /Status:/{
      gsub(/^ +/,"");
      printf "Frame %s  t=%.3fs  LUN=%s  %s  -> %s\n", frame, t, lun, op, $0
    }
  '
```

Usage:

```bash
chmod +x extract_scsi.sh
./extract_scsi.sh metro_rp2040_baseline_main/baseline_32gb_coldboot_01.pcap \
  > scsi_commands_baseline.txt
./extract_scsi.sh metro_rp2040_pr10967/pr10967_32gb_coldboot_01.pcap \
  > scsi_commands_pr10967.txt
```

What you should see:

| Firmware | LUN0 (CIRCUITPY) PREVENT_ALLOW | LUN1 (SD) PREVENT_ALLOW | macOS behavior |
|---|---|---|---|
| baseline main | `GOOD` | `GOOD` | LUN1 not mounted; no TUR polling |
| PR #10967 | `CHECK_CONDITION + ILLEGAL_REQUEST` | `CHECK_CONDITION + ILLEGAL_REQUEST` | Both mount; macOS polls TUR ~4/s per LUN forever |

To verify the polling rate, count TUR opcodes per 10-second window:

```bash
awk '/Opcode: Test Unit Ready/ {
  bin = int($3 + 0); print bin
}' scsi_commands_pr10967.txt | sort -n | uniq -c
```

Expect ~40 TURs per 10-second bin (8/s total = 4/s × 2 LUNs), flat for the
length of the capture. No backoff or tapering.

---

## 5. CDC throughput benchmark (the ~19% slowdown)

The CPU-only benchmark (~245 ms per call in steady state) is **not** affected
by polling — TinyUSB ISR overhead is in the noise. The slowdown only shows
up on CDC-heavy workloads.

### Required CIRCUITPY contents

Copy `bench/bench_cdc.py` from this repo onto the board as `code.py`. No
other files needed:

```bash
cp bench/bench_cdc.py /Volumes/CIRCUITPY/code.py
```

The script defines its own `cpu_work()` (a small inline integer loop
calibrated to ~250 ms per call on a Metro RP2040) and a `bench_print(500)`
that times 500 `print()` calls over CDC. It runs both three times and
saves the timings to `/sd/cdc_bench.txt`.

### Running the benchmark

The REPL **must** be attached during the run, otherwise `print()` blocks/buffers
and the timing reflects buffer pressure rather than CDC throughput.

```bash
# Open a REPL terminal in another tab so prints have a consumer:
screen /dev/cu.usbmodem1201 115200
# (or tio, mpremote, etc.)
```

Save `code.py` — CircuitPython auto-reloads. Watch for the `=== cdc_bench done ===`
banner, then read the output:

```bash
# /sd/ is exposed via USB MSC; reading on the host is fine
cat /Volumes/ADALOGGER/cdc_bench.txt
```

### Swap firmware between runs

To re-run on the other firmware:

1. Disconnect screen/tio so the serial port is free.
2. Hold BOOTSEL, tap RESET, release → `RPI-RP2` appears.
3. `cp firmware_pr10967_*.uf2 /Volumes/RPI-RP2/` (or the baseline UF2).
4. Wait for `CIRCUITPY` to come back, reconnect the REPL, soft-reset the board
   (Ctrl-D in screen) so `code.py` re-runs.
5. Read `/Volumes/ADALOGGER/cdc_bench.txt` — note that on baseline-main,
   `ADALOGGER` is not mounted by macOS (LUN1 isn't reported as removable)
   so you have to read the file *after* swapping back to the PR firmware,
   *or* eject ADALOGGER and read the SD via a card reader.

### Expected results (3-run average)

| Workload | Baseline main | PR #10967 | Delta |
|---|---|---|---|
| `cpu` (CPU-only compute) | 241 ms | 245 ms | +1.7 % (noise) |
| `print500` (CDC-heavy) | 212 ms | 252 ms | **+19 %** |

Per-print cost: 0.42 ms baseline → 0.50 ms with polling (≈ +80 µs per `print()`).

The CPU number being unchanged is the proof that the cost is *not* TinyUSB ISR
overhead. The CDC delta is the cost — the RP2040 USB controller serializes
endpoint servicing per frame and the bulk-IN/OUT for each TUR competes with
CDC's IN endpoint for transmit slots.

---

## 6. Slow-window benchmark (the 2.82× regression bablokb described)

This is the headline measurement for the PR thread: with PR firmware, every
USB re-enumeration produces a **~17.5-second window where CPU work runs at
2.82× steady-state cost**. The window ends sharply (cliff edge in iter timings)
when macOS finishes parsing the LUN1 partition table.

The earlier `cdc_bench` from §5 misses this entirely because:

1. It runs only 3 iterations — too short.
2. Each iteration writes 64 KB to `/sd/` from the board side; those writes
   contend with macOS's mount-time block reads on the same SD, *preventing
   macOS from completing the mount*. The slow window then never starts because
   the host-side cause never gets to run. We confirmed this experimentally:
   in the 30-iteration FS-IO version with board-side writes, ADALOGGER never
   appeared in `/Volumes/` and the timings were flat. Removing the board-side
   writes was what allowed the window to manifest.

So the slow-window protocol has three rules that all matter:

1. **Hardware RESET, not soft-reset.** Soft-reset preserves USB enumeration; no
   re-enumeration, no slow window. Press the red RESET button on the Metro,
   *not* BOOTSEL. (Unplug/replug works too.)
2. **Pure CPU benchmark, no `/sd/` writes during measurement.** Board-side
   writes block the host's mount, which is the very thing causing the window.
3. **Run for ~30+ seconds.** The window is ~17.5 s on a 32 GB card; you need
   to capture both the slow phase and several seconds of steady state to
   pinpoint the cliff edge.

### Required CIRCUITPY contents

Copy `bench/bench_cpu_only.py` from this repo onto the board as `code.py`:

```bash
cp bench/bench_cpu_only.py /Volumes/CIRCUITPY/code.py
```

The script defines its own `cpu_work()` (a small inline integer loop
calibrated to ~250 ms per call on a Metro RP2040) and runs 100 iterations
with no SD writes during measurement. Results are saved to
`/sd/cpu_only_bench.txt` only after the loop completes, so the writes
don't fight macOS during the mount-phase window.

### Running the benchmark

```bash
# 1. With code.py in place on CIRCUITPY, disconnect any REPL.
#    (Soft-reset would skip the slow window — we need full re-enumeration.)
# 2. Press the RESET button on the Metro RP2040 (the red one).
# 3. The serial port disappears, then comes back at a NEW path
#    (e.g. /dev/cu.usbmodem23201 instead of /dev/cu.usbmodem1201)
#    once enumeration completes. Note the new path:
ls /dev/cu.usbmodem*

# 4. Reconnect the REPL on the new path. The board is mid-benchmark;
#    you don't see the live prints because they happen at the end.
# 5. Wait ~40 s, then read the saved output:
```

```python
# In the REPL:
with open("/sd/cpu_only_bench.txt") as f:
    print(f.read())
```

If the slow window manifested, you can also confirm host-side timing on macOS:

```bash
# Before the bench finishes, /dev/disk5 has no parsed partition scheme:
diskutil list external | grep -A2 disk5
#   *31.9 GB    disk5

# After the cliff edge in the iter timings, the partition table appears:
diskutil list external | grep -A2 disk5
#   FDisk_partition_scheme   *31.9 GB    disk5
#   Windows_FAT_32 BOOT      31.9 GB     disk5s1
```

### Expected results

Captured run on Metro RP2040 + 32 GB SD + macOS 14, full file in
`metro_rp2040_pr10967/cpu_only_bench_pr_powercycle.txt`. Excerpt around the
cliff edge:

```
iter001: t+  0.00s  cpu= 700ms       <-- slow window starts
iter008: t+  4.92s  cpu= 673ms
iter014: t+  9.06s  cpu= 721ms
iter024: t+ 16.20s  cpu= 684ms
iter025: t+ 16.89s  cpu= 566ms       <-- transition (single iteration)
iter026: t+ 17.47s  cpu= 248ms       <-- CLIFF EDGE: steady state begins
iter027: t+ 17.72s  cpu= 247ms
iter050: t+ 23.50s  cpu= 248ms
iter100: t+ 36.23s  cpu= 249ms
```

| Phase | Iters | Wallclock | CPU avg | Multiplier vs steady |
|---|---|---|---|---|
| Slow window | 1–24 | 0.0 – 16.9 s | ~700 ms | **2.82 ×** |
| Transition | 25 | 16.9 – 17.5 s | 566 ms | 2.28 × |
| Steady state | 26–100 | 17.5 – 36.2 s | 248–250 ms | 1.00 × (matches baseline-main) |

### Pitfalls specific to this measurement

- **The serial-port path can change after RESET.** macOS assigns a new
  `iSerial`-derived path (we saw `/dev/cu.usbmodem1201` → `/dev/cu.usbmodem23201`
  across our reset). Always re-list `/dev/cu.usbmodem*` after reset before
  reconnecting.
- **Don't soft-reset to retry.** Soft-reset (Ctrl-D in REPL) doesn't re-enumerate
  USB — the host already considers the device steady-state, so the window
  doesn't open. Only hardware RESET (or unplug/replug) provokes the window.
- **macOS may auto-mount ADALOGGER from a previous power-cycle, even after
  RESET.** Check `ls /Volumes/` *before* RESET — if `ADALOGGER` is already
  mounted, eject it first via `diskutil eject /Volumes/ADALOGGER`, otherwise
  macOS may skip the heavy-read phase the second time around.
- **Don't add `print(line)` inside the measurement loop.** Even a single
  `print()` per iteration adds ~80 µs of CDC contention overhead per the §5
  result, which compounds across 100 iterations and can mask small
  perturbations. Print only after measurements complete.

### Why this matches the PR thread

- bablokb on `#10733`: *"the slow phase lasts ~20s after USB re-enumeration"* —
  our 17.5 s aligns within the same regime.
- bablokb on `#10967`: *"For a startup-work-deepsleep program that finishes in
  under 20s, every run is ~3× slower"* — our 2.82× confirms.
- dhalbert on `#10733`: *"caused by the host computer doing a lot of reads of
  the SD card drive as it's mounting it"* — the cliff edge coincides with
  `diskutil` showing the parsed partition table, supporting the mechanism.

---

## 7. Files in this repo

```
metro_rp2040_baseline_main/
  firmware_baseline_main_8e45cf19.uf2     built from main @ 8e45cf19
  baseline_32gb_coldboot_01.pcap          75 s, full enumeration + first TURs
  scsi_commands_baseline.txt              extracted SCSI events
  cdc_bench_baseline.txt                  3 runs of cdc_bench code.py
  fsio_bench_baseline_softreset.txt       30 iters of fsio_bench (flat — no slow
                                            window since LUN1 isn't host-mounted)
  highlevel-summary.txt                   narrative summary
  session.log                             build/test log

metro_rp2040_pr10967/
  firmware_pr10967_00254fd6.uf2           built from pr-10967 @ 00254fd6
  pr10967_32gb_coldboot_01.pcap           91 s cold boot
  pr10967_32gb_5min_01.pcap               295 s — proves polling is permanent
  pr10967_8gb_5min_01.pcap                312 s — same TUR rate on small card
  scsi_commands_pr10967.txt               extracted SCSI events
  cdc_bench_pr10967.txt                   3 runs of cdc_bench code.py
  fsio_bench_pr_powercycle_short.txt      30 iters w/ board-side SD writes —
                                            note: blocked macOS mount, slow window
                                            never started (failure-mode artifact)
  cpu_only_bench_pr_powercycle.txt        100 iters of CPU-only bench across the
                                            slow window — THE headline result
  highlevel-summary.txt                   narrative summary
  session.log                             build/test log

extract_scsi.sh                           tshark+awk SCSI extractor
cynthion-macos-getting-started.md         full Cynthion macOS setup guide
reproduce-this.md                         this guide
```

---

## 8. Pitfalls observed during the original run

- **`brew install arm-none-eabi-gcc` is bare GCC, no newlib.** Use
  `brew install arm-gcc-bin@14` and `export PATH=...` to its `bin/`.
- **System Python 3.9 vs Homebrew Python 3.14.** `pip install cynthion` against
  3.9 leaves `cynthion` invisible to `python3` (which resolves to 3.14). Always
  use a venv from `python3 -m venv`.
- **`cynthion info` leaves the device claimed.** If Packetry then says "failed
  to open device", run `cynthion run analyzer` to reload the gateware fresh.
- **CIRCUITPY is read-only from the board side while the host has it mounted.**
  Standalone benchmarks that try to write to `/` will silently no-op. Write to
  `/sd/` instead, or call `storage.remount("/", readonly=False)` from `boot.py`.
- **`tshark -T fields -e scsi.*` returns nothing on Cynthion captures.** DLT 288
  is raw bus packets — Wireshark's USB dissector expects Linux URB headers. Use
  `-V` (verbose) and parse with `awk`, as `extract_scsi.sh` does.
- **REPL must be attached during `print500`.** Without a CDC consumer, prints
  buffer in the bulk-IN endpoint and the timing collapses (or stalls
  altogether). Use `screen`, `tio`, or `mpremote` — keep the terminal open.
- **Board-side SD writes during measurement *prevent* the slow window from
  starting.** macOS's mount-time block reads on LUN1 are what cause the
  slowdown; if the board is concurrently writing the same SD, the host's
  reads return inconsistent data and macOS retries / never finishes mounting.
  Symptom: `/dev/disk5` appears in `diskutil list` but with no parsed
  partition scheme (`*31.9 GB disk5` with no `disk5s1` line) and the
  benchmark timings are flat. Fix: don't write to `/sd/` from the board
  during slow-window measurement; only at the end.
- **Serial-port path changes after a hardware RESET.** macOS picks a new
  TTY suffix, e.g. `/dev/cu.usbmodem1201` → `/dev/cu.usbmodem23201`. Always
  re-list `/dev/cu.usbmodem*` before reconnecting REPL after RESET.
- **macOS skips the heavy-read mount phase if ADALOGGER is still mounted
  from a previous boot.** If you're re-running the slow-window bench after a
  prior successful mount, eject ADALOGGER first
  (`diskutil eject /Volumes/ADALOGGER`) before the RESET, otherwise macOS
  reuses cached FAT structures and you'll measure a no-window run.
