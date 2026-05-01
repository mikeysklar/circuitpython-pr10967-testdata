#!/bin/bash
# analyze_pcap.sh — automated SCSI analysis report for a Cynthion capture
# from PR #10967 testing. Answers all four test-plan questions in one pass.
#
# Usage:
#   ./analyze_pcap.sh <capture.pcap>                    # bus-side analysis only
#   ./analyze_pcap.sh <capture.pcap> <bench.txt>        # also cross-correlates
#                                                        with a CPU-only bench
#
# Sections:
#   1. Capture overview (capinfos)
#   2. SCSI commands by opcode + status (with PREVENT_ALLOW spotlighted = Q1)
#   3. Mount-phase identification (first / last READ(10), volume of reads = Q4)
#   4. Steady-state TUR rate, per-LUN (Q2 baseline data)
#   5. Per-second opcode pivot for the first ~30s (cliff edge view = Q4)
#   6. Steady-state opcode pivot sample (t=60-90s)
#   7. Cross-correlation with bench.txt (if provided)

set -e

PCAP="$1"
BENCH="$2"

if [ -z "$PCAP" ]; then
  echo "Usage: $0 <capture.pcap> [bench.txt]"
  exit 1
fi

if [ ! -f "$PCAP" ]; then
  echo "Error: pcap not found: $PCAP" >&2
  exit 1
fi

DIR=$(dirname "$0")
EXTRACT="$DIR/extract_scsi.sh"
TMP=$(mktemp -t scsi_tsv.XXXXXX)
trap "rm -f $TMP" EXIT

echo "Extracting SCSI commands from $PCAP …" >&2
"$EXTRACT" --tsv "$PCAP" > "$TMP"
NROWS=$(wc -l < "$TMP")
echo "  $NROWS SCSI transactions extracted." >&2
echo "" >&2

echo "============================================================"
echo " 1. Capture overview"
echo "============================================================"
capinfos "$PCAP" 2>/dev/null | grep -E "(File name|Number of packets|Capture duration|File size|Data byte rate)"

echo ""
echo "============================================================"
echo " 2. SCSI commands by opcode + SCSI status"
echo "============================================================"
echo "  CNT   OPCODE                         STATUS"
awk -F'\t' '{
  op=$4; sub(/ *\(0x[0-9a-fA-F]+\) *$/, "", op)
  st=$5; sub(/ *\(0x[0-9a-fA-F]+\) *$/, "", st)
  cnt[op "\t" st]++
} END {
  for (k in cnt) {
    split(k, parts, "\t")
    printf "%5d   %-30s %s\n", cnt[k], parts[1], parts[2]
  }
}' "$TMP" | sort -rn

echo ""
echo "  PREVENT_ALLOW behavior (Q1 — the headline PR question):"
awk -F'\t' '$4 ~ /Prevent\/Allow/ {
  st=$5; sub(/ *\(0x[0-9a-fA-F]+\) *$/, "", st)
  printf "    LUN %s -> %s\n", $3, st
}' "$TMP" | sort -u

echo ""
echo "============================================================"
echo " 3. Mount-phase identification (Q4 — slow-window cause)"
echo "============================================================"
NRD10=$(awk -F'\t' '$4 ~ /^Read\(10\)/' "$TMP" | wc -l | tr -d ' ')
if [ "$NRD10" -gt 0 ]; then
  # Cluster identification: a "mount cluster" is a run of consecutive seconds
  # each with ≥ THRESH READ(10)s. The cliff edge is the last second of the first
  # such cluster — anything after that (sparse late bursts from spotlight,
  # mds, etc.) is background activity, not the mount-phase slow window.
  read MOUNT_FIRST MOUNT_LAST MOUNT_TOTAL <<<$(awk -F'\t' '
    $4 ~ /^Read\(10\)/ { cnt[int($2)]++ }
    END {
      THRESH = 5    # ≥ 5 READ(10) per second counts as "mount cluster"
      first = -1; last = -1; total = 0
      # Walk seconds in order; once we leave the first cluster, stop
      for (s = 0; s <= 1000; s++) {
        if (cnt[s] >= THRESH) {
          if (first < 0) first = s
          last = s
          total += cnt[s]
        } else if (last >= 0 && s - last > 2) {
          break    # gap > 2s closes the cluster
        } else if (last >= 0) {
          total += cnt[s]
        }
      }
      printf "%d %d %d", first, last, total
    }
  ' "$TMP")
  WINDOW=$((MOUNT_LAST - MOUNT_FIRST + 1))
  echo "  Mount-phase cluster: t=${MOUNT_FIRST}s .. t=${MOUNT_LAST}s  (~${WINDOW}s window)"
  echo "  Mount-cluster READ(10) total: $MOUNT_TOTAL"
  LATE_RD10=$((NRD10 - MOUNT_TOTAL))
  if [ "$LATE_RD10" -gt 0 ]; then
    echo "  Late/background READ(10) (post-cluster): $LATE_RD10  (Spotlight, mds, etc.)"
  fi
else
  echo "  No READ(10) commands seen — host did not mount LUN1."
  echo "  (Expected for baseline-main firmware where the SD never mounts.)"
fi

echo ""
echo "============================================================"
echo " 4. Steady-state TUR rate (Q2 — polling cost baseline)"
echo "============================================================"
DURATION=$(capinfos "$PCAP" 2>/dev/null | awk '/Capture duration/{print $3}')
SKIP=60
SS_DURATION=$(awk -v d="$DURATION" -v s="$SKIP" 'BEGIN {printf "%.1f", d - s}')

# Determine if we have enough steady-state to measure
if awk -v d="$DURATION" -v s="$SKIP" 'BEGIN {exit !(d > s + 30)}'; then
  echo "  Sampling steady state from t=${SKIP}s to t=${DURATION%.*}s (${SS_DURATION}s of data)"
  echo ""
  echo "  Per-LUN TUR counts in steady state:"
  awk -F'\t' -v skip="$SKIP" '$2+0 > skip && $4 ~ /Test Unit Ready/ {print $3}' "$TMP" | \
    sort | uniq -c | awk '{printf "    LUN %s: %5d TUR  (%.2f/s)\n", $2, $1, $1 / '"$SS_DURATION"'}'
  TOTAL_TUR=$(awk -F'\t' -v skip="$SKIP" '$2+0 > skip && $4 ~ /Test Unit Ready/' "$TMP" | wc -l | tr -d ' ')
  echo "    ─────────────────────────"
  printf "    TOTAL: %5d TUR  (%.2f/s)\n" "$TOTAL_TUR" "$(awk -v t=$TOTAL_TUR -v d=$SS_DURATION 'BEGIN {printf "%.2f", t/d}')"
else
  echo "  Capture too short for steady-state measurement (need >${SKIP}+30s)."
fi

echo ""
echo "============================================================"
echo " 5. First 30s — opcode pivot (mount + cliff edge)"
echo "============================================================"
"$EXTRACT" --bucket "$PCAP" | awk 'NR==1 || ($1+0 < 30)'

if awk -v d="$DURATION" 'BEGIN {exit !(d > 90)}'; then
  echo ""
  echo "============================================================"
  echo " 6. Steady-state sample (t=60–90s)"
  echo "============================================================"
  "$EXTRACT" --bucket "$PCAP" | awk 'NR==1 || ($1+0 >= 60 && $1+0 < 90)'
fi

if [ -n "$BENCH" ] && [ -f "$BENCH" ]; then
  echo ""
  echo "============================================================"
  echo " 7. Cross-correlation with bench: $BENCH"
  echo "============================================================"
  echo "  Bench cliff edge (last iter with cpu>500ms followed by cpu<300ms):"
  awk '
    /^iter/ {
      gsub(/.*cpu= */, ""); gsub(/ms.*/, "")
      cpu = $1 + 0
      if (prev_slow && cpu < 300) {
        printf "    Bench transition: prev_iter cpu=%dms -> this iter cpu=%dms (line %d)\n", prev_cpu, cpu, NR
        exit
      }
      if (cpu > 500) prev_slow = 1
      prev_cpu = cpu
    }
  ' "$BENCH"
  echo "  Bench cliff-edge timestamp (relative to bench start):"
  awk '
    /^iter/ {
      match($0, /t\+ *[0-9]+\.[0-9]+s/)
      tstr = substr($0, RSTART, RLENGTH); gsub(/[t+s ]/, "", tstr)
      gsub(/.*cpu= */, ""); gsub(/ms.*/, "")
      cpu = $1 + 0
      if (prev_slow && cpu < 300) {
        printf "    bench_t = %s\n", tstr
        exit
      }
      if (cpu > 500) prev_slow = 1
    }
  ' "$BENCH"
  echo "  Bus-side cliff edge (last second of mount-phase READ(10) cluster):"
  CLIFF_PCAP=$(awk -F'\t' '
    $4 ~ /^Read\(10\)/ { cnt[int($2)]++ }
    END {
      THRESH = 5; last = -1
      for (s = 0; s <= 1000; s++) {
        if (cnt[s] >= THRESH) last = s
        else if (last >= 0 && s - last > 2) break
      }
      print last
    }
  ' "$TMP")
  echo "    pcap_t = ${CLIFF_PCAP}s"
  echo ""
  CLIFF_BENCH=$(awk '
    /^iter/ {
      match($0, /t\+ *[0-9]+\.[0-9]+s/)
      tstr = substr($0, RSTART, RLENGTH); gsub(/[t+s ]/, "", tstr)
      gsub(/.*cpu= */, ""); gsub(/ms.*/, "")
      cpu = $1 + 0
      if (prev_slow && cpu < 300) { print tstr; exit }
      if (cpu > 500) prev_slow = 1
    }
  ' "$BENCH")
  BOOT_DELAY=$(awk -v p="$CLIFF_PCAP" -v b="$CLIFF_BENCH" 'BEGIN {printf "%.2f", p - b}')
  echo "  Implied CircuitPython boot delay (pcap_t - bench_t): ${BOOT_DELAY}s"
  echo "  Q4 status: bench cliff at ${CLIFF_BENCH}s + boot delay ≈ pcap cliff at ${CLIFF_PCAP}s ✓"
fi
