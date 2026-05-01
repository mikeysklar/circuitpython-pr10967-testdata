# circuitpython-pr10967-testdata

Parsing tools, benchmark code, and bench/extracted output from hardware
testing of [adafruit/circuitpython#10967](https://github.com/adafruit/circuitpython/pull/10967)
on macOS.

The PR changes how CircuitPython responds to the SCSI `PREVENT_ALLOW_MEDIUM_REMOVAL`
command on USB Mass Storage LUNs. This repo holds the scripts and benchmark
code used during hardware testing on a Metro RP2040 + Cynthion USB analyzer,
plus the textual outputs (extracted SCSI logs, per-second opcode pivots,
benchmark timings) from each run.

The README is descriptive only. For interpretation see the linked docs and
the PR thread.

## What's in here

- `tools/` — shell scripts for parsing Cynthion captures with `tshark`
- `bench/` — CircuitPython benchmark scripts that run on the device
- `firmware/` — UF2 builds of the firmware versions tested (`main` and the PR
  branch), plus their commit metadata
- `results/` — text outputs from running the bench scripts and the parser
  tools (no PCAPs)
- `reproduce-this.md` — full methodology
- `step-by-step.md` — single-session test sequence
- `fat32_cold_plug_ux.md` — prose notes on user-facing behavior

PCAP captures are **not** redistributed here. They're large, host-specific,
and easy to regenerate. The methodology + tools + bench code lets anyone
with a Cynthion + Metro RP2040 + macOS reproduce the same measurements in
about 20 minutes.

## Hardware

- Metro RP2040 running CircuitPython (firmware UF2s in `firmware/`)
- Cynthion USB analyzer (Great Scott Gadgets), default analyzer bitstream
- microSD cards: 32 GB FAT32, 8 GB FAT32, 64 MB FAT16
- macOS 14 (Apple Silicon)

## Tools (`tools/`)

Shell scripts for parsing Cynthion `.pcap` files with `tshark`.

- `extract_scsi.sh` — wraps `tshark -Y "usbms" -V` and extracts the SCSI
  CBW/CSW pairs. Three output modes:
  - default: human-readable, one line per command
  - `--tsv`: tab-separated columns (frame, t_rel, lun, opcode, scsi_status)
  - `--bucket`: per-second opcode pivot table
- `analyze_pcap.sh` — calls `extract_scsi.sh` and prints a multi-section
  summary report. Optionally cross-correlates with a benchmark file.

## Benchmark code (`bench/`)

CircuitPython scripts that run on the device and produce the timings in
`results/`. Drop either onto `code.py` on a CIRCUITPY drive — no other files
needed.

- `bench_cpu_only.py` — 100 iterations of an inline integer CPU loop, no SD
  I/O during measurement. Results saved to `/sd/cpu_only_bench.txt` at the
  end.
- `bench_cdc.py` — 3 runs of CPU + `print()` throughput. Results saved to
  `/sd/cdc_bench.txt`.

Each script defines its own `cpu_work()` function (a small integer loop
calibrated to take roughly 250 ms per call on a Metro RP2040). If your
board lands far outside 200–300 ms in steady state, adjust `CPU_ITERS` at
the top of the file.

### What's on CIRCUITPY during the test

- `/code.py` — one of the two `bench_*.py` files in this repo, copied across
- `/boot.py` — **not used**; the board runs stock CircuitPython defaults
  (USB MSC on for internal flash + SD, CIRCUITPY read-only from device side,
  REPL on USB CDC). No `storage.remount()` or `usb_cdc.disable()` in this
  work.

That's it — no other files needed on the board.

## Firmware (`firmware/`)

Pre-built UF2 images of the two firmware variants used in testing, plus the
commit metadata for each:

- `firmware_main.uf2` — built from CircuitPython `origin/main`
- `firmware_main.commit` — short hash, ISO date, and commit subject for the
  above
- `firmware_pr.uf2` — built from PR #10967 head
- `firmware_pr.commit` — short hash, ISO date, and commit subject

To flash: hold BOOTSEL on the Metro RP2040, tap RESET, copy the relevant UF2
to `RPI-RP2`. The board reboots into the new firmware automatically.

To rebuild from source: see `reproduce-this.md` for the full toolchain
setup. Quick version:

```bash
brew install arm-gcc-bin@14
export PATH="/opt/homebrew/Cellar/arm-gcc-bin@14/14.3.rel1_1/bin:$PATH"

git clone --recurse-submodules https://github.com/adafruit/circuitpython
cd circuitpython
make -C mpy-cross
cd ports/raspberrypi
make BOARD=adafruit_metro_rp2040 -j$(nproc)   # or -j8 on macOS
```

## Results (`results/`)

Text outputs produced by running the bench code on a board, and the parser
tools on the Cynthion `.pcap` files.

- `cpu_only_bench_<card>.txt` — per-iteration CPU timings from
  `bench_cpu_only.py`, copied off the SD card after each run
- `cdc_bench_<firmware>.txt` — CPU + `print()` timings from `bench_cdc.py`
- `analyze_<card>.txt` — full output of `analyze_pcap.sh` for each capture
- `scsi_bucket_<card>.txt` — per-second opcode pivot tables from
  `extract_scsi.sh --bucket`
- `scsi_commands_<firmware>.txt` — full SCSI command/response logs from
  `extract_scsi.sh` (default mode)

Cards: `32gb` (FAT32), `8gb` (FAT32), `64mb` (FAT16).
Firmware variants: `main`, `pr10967`.

## Software requirements

To rerun the parsing tools on captures you've taken yourself:

- macOS (tested) or Linux
- Wireshark CLI tools (`tshark`, `capinfos`) — `brew install wireshark`
- bash, awk, gzip (standard on macOS / Linux)

To take new captures:

- A Cynthion USB analyzer
- The `cynthion` Python package — `pip install cynthion` (Python 3.11+)
- [Packetry](https://packetry.readthedocs.io/) — `brew install packetry`

## Quick examples

Once you have your own `.pcap` from a Cynthion capture:

```bash
# Per-second SCSI opcode pivot — shows the mount-phase READ(10) cluster
# and the cliff edge where it stops
./tools/extract_scsi.sh --bucket /path/to/capture.pcap

# Full analysis report (optional bench cross-correlation)
./tools/analyze_pcap.sh /path/to/capture.pcap /path/to/cpu_only_bench.txt
```

## Licence

GPL-3.0. See `LICENSE`.
