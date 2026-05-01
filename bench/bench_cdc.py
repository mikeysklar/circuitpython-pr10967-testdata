# bench_cdc.py — steady-state CDC vs CPU comparison
#
# Drop this onto /Volumes/CIRCUITPY/code.py. REPL must be attached so print()
# transfers over CDC; without a consumer, prints buffer in the bulk-IN endpoint
# and the timing reflects buffer pressure, not CDC throughput.
#
# Intended usage: run once on PR firmware (TUR polling on LUN1 active) and once
# on baseline main (no LUN1 polling). Compare print500 timings between the two.
#
# `cpu_work()` is a self-contained integer loop calibrated to take roughly
# 250 ms per call on a Metro RP2040. Adjust CPU_ITERS if your board lands
# significantly outside 200–300 ms.
import gc, time

CPU_ITERS = 30000   # tune to land at ~250 ms per cpu_work() call

def cpu_work():
    total = 0
    for i in range(CPU_ITERS):
        total += (i * 13) % 17
    return total

def bench_cpu():
    gc.collect()
    t0 = time.monotonic_ns()
    cpu_work()
    return (time.monotonic_ns() - t0) // 1_000_000

def bench_print(n=500):
    line = "x" * 60
    gc.collect()
    t0 = time.monotonic_ns()
    for i in range(n):
        print(f"{i:04d}: {line}")
    return (time.monotonic_ns() - t0) // 1_000_000

print("=== cdc_bench start ===")
results = []
for i in range(3):
    cpu = bench_cpu()
    prn = bench_print(500)
    line = f"run{i+1}: cpu={cpu}ms  print500={prn}ms"
    results.append(line)
    print(line)

try:
    with open("/sd/cdc_bench.txt", "w") as f:
        for line in results:
            f.write(line + "\n")
    print("=== wrote /sd/cdc_bench.txt ===")
except OSError as e:
    print(f"=== SD write failed: {e} ===")

print("=== cdc_bench done ===")
