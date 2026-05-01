#!/bin/bash
# Extract SCSI command/response pairs from a Cynthion USB 2.0 pcap file.
#
# Usage:
#   ./extract_scsi.sh <capture.pcap>             # human-readable (default)
#   ./extract_scsi.sh --tsv <capture.pcap>       # TSV: cbw_frame, t_rel, lun, opcode, scsi_status
#   ./extract_scsi.sh --bucket <capture.pcap>    # per-second opcode counts (for cliff-edge analysis)
#
# Time is RELATIVE to capture start (seconds), not Unix epoch.
# Each row is one completed SCSI transaction (CBW timestamp, CSW status).
#
# Status values come from the SCSI sense byte ([Status: ...] in tshark -V):
#   Good           — command succeeded
#   Check Condition — command failed; SENSE follow-up explains why (e.g. PREVENT_ALLOW
#                    returning ILLEGAL_REQUEST to make macOS keep polling).

MODE="pretty"
case "$1" in
  --tsv)    MODE="tsv"; shift ;;
  --bucket) MODE="bucket"; shift ;;
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# //; s/^#//'; exit 0 ;;
esac

if [ -z "$1" ]; then
  sed -n '2,16p' "$0" | sed 's/^# //; s/^#//'
  exit 1
fi

PCAP="$1"

# Parse tshark -V output; emit TSV `cbw_frame\tt_rel\tlun\topcode\tscsi_status`
# - CBW frame: contains "Opcode: ..." (no bracket) — capture op, LUN, request frame/time
# - CSW frame: contains "[Status: ...]" (bracketed = SCSI sense) — emit row with
#   the CBW's frame/time so the row reflects when the command was issued.
TSV=$(tshark -r "$PCAP" -Y "usbms" -V 2>/dev/null | awk '
  BEGIN { t0 = 0 }
  /^Frame [0-9]+:/ {
    cur_frame = $2; gsub(/:$/, "", cur_frame)
  }
  # Use Epoch Arrival Time and subtract the first epoch we see — the
  # "Time since reference or first frame" field changes format after 60s
  # ("1 minute, 5.678 milliseconds") which breaks plain regex extraction.
  /Epoch Arrival Time:/ {
    ep = $NF + 0
    if (t0 == 0) t0 = ep
    cur_t = sprintf("%.9f", ep - t0)
  }
  /^[[:space:]]*Opcode: / {
    op = $0
    sub(/^[[:space:]]*Opcode: /, "", op)
    sub(/[[:space:]]+$/, "", op)
    req_frame = cur_frame
    req_t = cur_t
  }
  /= LUN: 0x[0-9a-fA-F]+/ {
    match($0, /0x[0-9a-fA-F]+/)
    lun = substr($0, RSTART, RLENGTH)
  }
  /^[[:space:]]*\[Status: / {
    st = $0
    sub(/^[[:space:]]*\[Status: /, "", st)
    sub(/\][[:space:]]*$/, "", st)
    if (op != "" && req_frame != "") {
      printf "%s\t%s\t%s\t%s\t%s\n", req_frame, req_t, lun, op, st
      op = ""; req_frame = ""
    }
  }
')

case "$MODE" in
  pretty)
    echo "$TSV" | awk -F'\t' '
      {printf "Frame %-7s  t=%8.3fs  LUN=%-6s  %-32s  -> %s\n", $1, $2, $3, $4, $5}
    '
    ;;
  tsv)
    echo "$TSV"
    ;;
  bucket)
    # Emit (sec, opcode, count) rows, then pivot with sort+awk so we don't
    # need gawk's asorti. Output is a wide table with a column per opcode.
    raw=$(echo "$TSV" | awk -F'\t' '
      {
        sec = int($2)
        op = $4; sub(/ *\(0x[0-9a-fA-F]+\) *$/, "", op)
        cnt[sec "\t" op]++
      }
      END { for (k in cnt) { print k "\t" cnt[k] } }
    ' | sort -n -k1,1)
    # Distinct opcodes in deterministic order
    ops=$(echo "$raw" | awk -F'\t' '{print $2}' | sort -u)
    # Header
    printf "%6s" "t(s)"
    while IFS= read -r op; do printf "  %-22s" "$op"; done <<< "$ops"
    echo
    # Body — one row per second, columns per opcode
    secs=$(echo "$raw" | awk -F'\t' '{print $1}' | sort -un)
    while IFS= read -r s; do
      printf "%6d" "$s"
      while IFS= read -r op; do
        c=$(echo "$raw" | awk -F'\t' -v s="$s" -v op="$op" '$1==s && $2==op {print $3; exit}')
        printf "  %-22d" "${c:-0}"
      done <<< "$ops"
      echo
    done <<< "$secs"
    ;;
esac
