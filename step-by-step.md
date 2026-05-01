# Step-by-step: cold-boot capture session

Single-session test sequence: a 90-second Cynthion capture during a fresh
USB enumeration, with `bench_cpu_only.py` running on the board so we can
cross-correlate the bus-side `READ(10)` cluster with the CPU-side cliff
edge.

For broader methodology see `reproduce-this.md`.

Repeat for each card under test (e.g. 32 GB FAT32, 8 GB FAT32, 64 MB FAT16).

---

## Phase 1 — verify state (board plugged into Cynthion TARGET A)

```bash
ls /Volumes/                       # expect CIRCUITPY (and the SD volume label
                                   # if it auto-mounted, e.g. 32GB_SD)
ls /dev/cu.usbmodem*               # note the current path; will change after RESET
```

Confirm `code.py` is the CPU-only bench. macOS may deny terminal access to
`/Volumes/CIRCUITPY` on a fresh mount, so check via REPL instead:

```python
# In the REPL connected to the board:
with open("/code.py") as f:
    print(f.read()[:200])
# First line should read: "# bench_cpu_only.py — slow-window measurement"
```

If wrong, `cp bench/bench_cpu_only.py /Volumes/CIRCUITPY/code.py`.

The bench scripts are self-contained — no other files need to be on the
board.

---

## Phase 2 — pre-capture cleanup

```bash
diskutil eject /Volumes/<SD_VOLUME_LABEL> 2>/dev/null || echo "SD not mounted"
# (Replace <SD_VOLUME_LABEL> with whatever shows up — e.g. 32GB_SD, 8GB_SD,
# 64MB_SD, ADALOGGER, BOOT, etc.)
```

If the SD is still mounted from a prior run, macOS may use cached FAT
structures on the next reset and skip the heavy-read mount phase, masking
the slow window.

Confirm Cynthion is in analyzer mode:

```bash
cyn                                # activate venv (or your equivalent)
cynthion info                      # expect: Bitstream: USB Analyzer (Cynthion Project)
```

---

## Phase 3 — arm the Packetry capture

```bash
packetry &
```

In Packetry GUI:
- Speed dropdown → **Full Speed**
- Click **Capture** (⌘+B) — capture is now running

---

## Phase 4 — trigger the cold boot

Physically unplug the Metro from Cynthion TARGET A and replug it. (RESET
button works too, but full unplug/replug forces macOS xHCI cache
invalidation as well — closer to a fresh user experience.)

`code.py` auto-runs for ~30–40 s on a FAT32 card (~25 s on FAT16). The
slow window plus a few seconds of steady state will fit comfortably in a
**90-second capture**.

---

## Phase 5 — stop and save Packetry

After ~90 seconds:

- ⌘+E → stop capture
- ⌘+S → save somewhere local (e.g. `~/captures/pr_<size>.pcap`)

---

## Phase 6 — read the bench results

```bash
ls /dev/cu.usbmodem*               # path likely changed after RESET
                                   # (e.g. 1201 → 23201)
```

Connect REPL to the new path, then:

```python
with open("/sd/cpu_only_bench.txt") as f:
    print(f.read())
```

Save the output to your `results/` folder, e.g.
`results/cpu_only_bench_<card>.txt`.

---

## Phase 7 — host-side cliff-edge confirmation (optional)

```bash
diskutil list external | grep -A3 disk5
# Expected after the bench cliff edge:
#   FDisk_partition_scheme   *NN GB    disk5
#   Windows_FAT_32 <LABEL>   NN GB     disk5s1
```

When the partition scheme shows up in `diskutil`, macOS has finished the
heavy-read mount phase. That moment lines up with the iter cliff edge in
the bench file.

---

## Phase 8 — bus-side analysis (the cross-correlation)

```bash
# Per-second opcode pivot — cliff edge view
./tools/extract_scsi.sh --bucket ~/captures/pr_<size>.pcap \
  > results/scsi_bucket_<card>.txt
cat results/scsi_bucket_<card>.txt

# Full multi-section report; cross-correlates with the bench cliff edge
./tools/analyze_pcap.sh ~/captures/pr_<size>.pcap \
  results/cpu_only_bench_<card>.txt \
  > results/analyze_<card>.txt
cat results/analyze_<card>.txt
```

In `scsi_bucket_<card>.txt` look for the second where `Read(10)` drops
from tens-per-second to 0 — that's the **bus-side cliff edge**. Compare
to the bench cliff edge in `cpu_only_bench_<card>.txt`; they should align
within ±2 s after accounting for the ~12 s of CircuitPython boot delay
(`pcap_t ≈ bench_boot_offset + bench_t`).

---

## Success criteria

| Check | Expected (FAT32) | Expected (FAT16) |
|---|---|---|
| `Prevent/Allow Medium Removal` status | CHECK_CONDITION on both LUNs | CHECK_CONDITION on both LUNs |
| Mount-cluster `READ(10)` total | ~700 commands | ~70 commands |
| Mount-cluster duration | ~20 s | ~1 s |
| Bench cliff edge (FAT32) | iter ≈ 25–28, t+17–20 s | iter ≈ 4, t+1 s |
| Steady-state TUR rate | ~1/s per LUN, ~2/s total | ~1/s per LUN, ~2/s total |

If any of these diverge meaningfully from prior runs, note it and
investigate.

---

## If you need to retry

A second cold-boot in the same session needs another full re-enumeration:

```bash
diskutil eject /Volumes/<SD_VOLUME_LABEL>     # eject SD before reset
# (no need to eject CIRCUITPY — the unplug will detach it)
```

Then back to Phase 3 (arm Packetry → unplug/replug → wait 90 s → save).
