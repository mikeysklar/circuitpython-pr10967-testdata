# bench_cpu_only.py — slow-window measurement
#
# Drop this onto /Volumes/CIRCUITPY/code.py and trigger a hardware RESET (or
# physical unplug/replug) to provoke a fresh USB enumeration.
#
# Pure CPU benchmark — no SD writes during measurement, no external benchmark
# module to install. Board-side SD writes while the host is mounting LUN1
# will fight macOS's mount-time block reads and mask the slow window, so we
# defer the result file write until after all iterations.
#
# `cpu_work()` is a self-contained integer loop calibrated to take roughly
# 250 ms per call in CircuitPython on a Metro RP2040 at 125 MHz. If your
# board is faster/slower, adjust CPU_ITERS until iter timings in steady
# state land around 200–300 ms.
#
# 100 iters × ~250 ms (steady state) or ~700–900 ms (slow window) → ~30–40 s
# of bench time on a FAT32 card, spanning the full slow window with headroom.
# On FAT16 cards the slow window is much shorter so the bench finishes in
# ~25 s.
import gc, time

CPU_ITERS = 30000   # tune to land at ~250 ms steady-state per cpu_work() call

def cpu_work():
    total = 0
    for i in range(CPU_ITERS):
        total += (i * 13) % 17
    return total

ITERS = 100
results = []
boot_t0 = time.monotonic_ns()
for i in range(ITERS):
    t_iter = (time.monotonic_ns() - boot_t0) // 1_000_000
    gc.collect()
    t0 = time.monotonic_ns()
    cpu_work()
    c = (time.monotonic_ns() - t0) // 1_000_000
    results.append(f"iter{i+1:03d}: t+{t_iter/1000:6.2f}s  cpu={c:4d}ms")

try:
    with open("/sd/cpu_only_bench.txt", "w") as f:
        for line in results:
            f.write(line + "\n")
except OSError:
    pass

for line in results:
    print(line)
print("=== cpu_only_bench done ===")
