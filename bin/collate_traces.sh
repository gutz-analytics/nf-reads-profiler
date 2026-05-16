#!/bin/bash
# COMPLETED profile_taxa + profile_function + MEDI_QUANT:kraken stats,
# summarized by process then date.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../results_local_logs" && pwd)"

RAW=$(mktemp --suffix=.tsv)
CUT=$(mktemp --suffix=.tsv)
NUM=$(mktemp --suffix=.tsv)
SUMMARY=$(mktemp --suffix=.tsv)
trap "rm -f $RAW $CUT $NUM $SUMMARY" EXIT

# Build raw table: trace_file prepended + all NF trace columns
printf "trace_file\t" > "$RAW"
find "$SCRIPT_DIR" -name "*_trace.txt" -type f | sort | head -1 | xargs head -1 >> "$RAW"

find "$SCRIPT_DIR" -name "*_trace.txt" -type f | sort | while read -r f; do
    grep -E "profile_taxa|profile_function|kraken" "$f" \
        | grep -v "kraken_report" \
        | grep "COMPLETED" \
        | sed "s|^|$(basename "$f")\t|" || true
done >> "$RAW"

# Keep only the columns we need
csvtk -t cut -f trace_file,name,realtime,'%cpu',peak_rss "$RAW" > "$CUT"

# Convert human-readable units to plain numbers: realtime→minutes, strip % and GB
awk -F'\t' 'BEGIN { OFS="\t" }
function parse_time(t,    val) {
    val = 0
    if (match(t, /[0-9]+h/)) val += substr(t, RSTART, RLENGTH-1) * 3600
    if (match(t, /[0-9]+m/)) val += substr(t, RSTART, RLENGTH-1) * 60
    if (match(t, /[0-9]+s/)) val += substr(t, RSTART, RLENGTH-1)
    return val / 60
}
NR==1 { print "date", "process", "sample", "realtime_min", "cpu_pct", "rss_gb"; next }
$5 == "-" { next }
{
    proc = $2; sub(/ \(.*\)/, "", proc)
    cpu = $4; gsub(/%/, "", cpu)
    rss = $5; gsub(/ GB/, "", rss)
    printf "%s\t%s\t%s\t%.2f\t%.1f\t%.2f\n",
        substr($1,1,8), proc, $2, parse_time($3), cpu+0, rss+0
}' "$CUT" > "$NUM"

# Summarize by process + date
csvtk -t summary -g process,date \
    -f sample:count,realtime_min:mean,realtime_min:max,cpu_pct:mean,cpu_pct:min,rss_gb:mean,rss_gb:max \
    "$NUM" > "$SUMMARY"

# Print each process as its own section
csvtk -t cut -f process "$SUMMARY" | tail -n +2 | sort -u | while read -r proc; do
    printf "\n=== %s ===\n" "$proc"
    csvtk -t grep -f process -p "$proc" "$SUMMARY" \
        | csvtk -t cut -f date,'sample:count','realtime_min:mean','realtime_min:max','cpu_pct:mean','cpu_pct:min','rss_gb:mean','rss_gb:max' \
        | csvtk -t pretty
done
