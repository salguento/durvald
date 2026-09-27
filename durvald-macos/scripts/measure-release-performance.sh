#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: measure-release-performance.sh --app PATH --database PATH [options]

Options:
  --output PATH       Output directory (default: /tmp/durvald-perf-TIMESTAMP)
  --idle-seconds N    Idle sampling duration (default: 30)
  --play-seconds N    Playback sampling duration (default: 60)
  --interval N        Sampling interval in seconds (default: 1)
  --startup-timeout N Window detection timeout in seconds (default: 30)
  --skip-playback     Record startup and idle only

The script launches the Release executable directly, outside Xcode. During the
playback phase it waits for Enter so a real library track can be started first.
EOF
}

app_path=""
database_path=""
output_path=""
idle_seconds=30
play_seconds=60
interval=1
startup_timeout=30
skip_playback=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app) app_path=${2:?}; shift 2 ;;
        --database) database_path=${2:?}; shift 2 ;;
        --output) output_path=${2:?}; shift 2 ;;
        --idle-seconds) idle_seconds=${2:?}; shift 2 ;;
        --play-seconds) play_seconds=${2:?}; shift 2 ;;
        --interval) interval=${2:?}; shift 2 ;;
        --startup-timeout) startup_timeout=${2:?}; shift 2 ;;
        --skip-playback) skip_playback=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$app_path" ] || [ -z "$database_path" ]; then
    usage >&2
    exit 2
fi

executable="$app_path/Contents/MacOS/Durvald"
if [ ! -x "$executable" ]; then
    echo "Release executable not found: $executable" >&2
    exit 1
fi
if [ ! -f "$database_path" ]; then
    echo "Database not found: $database_path" >&2
    exit 1
fi

if [ -z "$output_path" ]; then
    output_path="/tmp/durvald-perf-$(date '+%Y%m%d-%H%M%S')"
fi
if [ -e "$output_path/samples.csv" ] || [ -e "$output_path/summary.txt" ]; then
    echo "Output already contains a measurement: $output_path" >&2
    exit 1
fi
mkdir -p "$output_path"

samples="$output_path/samples.csv"
summary="$output_path/summary.txt"
stdout_log="$output_path/app.stdout.log"
stderr_log="$output_path/app.stderr.log"
wal_path="${database_path}-wal"
printf 'elapsed_seconds,phase,cpu_percent,rss_kb,wal_bytes\n' > "$samples"

now_seconds() {
    perl -MTime::HiRes=time -e 'printf "%.6f", time'
}

wal_bytes() {
    if [ -f "$wal_path" ]; then
        stat -f '%z' "$wal_path"
    else
        printf '0'
    fi
}

wal_bytes_before=$(wal_bytes)

started_at=$(now_seconds)
"$executable" >"$stdout_log" 2>"$stderr_log" &
app_pid=$!

cleanup() {
    if kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

startup_status="unavailable"
startup_seconds=""
startup_deadline=$(( $(date '+%s') + startup_timeout ))
while kill -0 "$app_pid" 2>/dev/null && [ "$(date '+%s')" -lt "$startup_deadline" ]; do
    if osascript -e 'tell application "System Events" to tell process "Durvald" to return exists window 1' 2>/dev/null | grep -q true; then
        visible_at=$(now_seconds)
        startup_seconds=$(awk -v end="$visible_at" -v start="$started_at" 'BEGIN { printf "%.3f", end-start }')
        startup_status="visible_window"
        break
    fi
    sleep 0.1
done

if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "Durvald exited during startup. See $stderr_log" >&2
    exit 1
fi

sample_phase() {
    phase=$1
    duration=$2
    phase_started=$(now_seconds)
    while kill -0 "$app_pid" 2>/dev/null; do
        sampled_at=$(now_seconds)
        elapsed=$(awk -v now="$sampled_at" -v start="$started_at" 'BEGIN { printf "%.3f", now-start }')
        phase_elapsed=$(awk -v now="$sampled_at" -v start="$phase_started" 'BEGIN { print now-start }')
        if awk -v elapsed="$phase_elapsed" -v duration="$duration" 'BEGIN { exit !(elapsed >= duration) }'; then
            break
        fi
        process_sample=$(ps -p "$app_pid" -o %cpu= -o rss= | awk '{$1=$1; print}')
        if [ -n "$process_sample" ]; then
            cpu=$(printf '%s\n' "$process_sample" | awk '{print $1}')
            rss=$(printf '%s\n' "$process_sample" | awk '{print $2}')
            printf '%s,%s,%s,%s,%s\n' "$elapsed" "$phase" "$cpu" "$rss" "$(wal_bytes)" >> "$samples"
        fi
        sleep "$interval"
    done
}

sample_phase idle "$idle_seconds"

if [ "$skip_playback" -eq 0 ]; then
    printf '\nStart playback of a representative local track, then press Enter.\n' >&2
    read -r _
    sample_phase playback "$play_seconds"
fi

ended_at=$(now_seconds)
total_seconds=$(awk -v end="$ended_at" -v start="$started_at" 'BEGIN { printf "%.3f", end-start }')

{
    repository_root=$(cd "$(dirname "$0")/../.." && pwd)
    printf 'measured_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'git_commit=%s\n' "$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || printf 'unknown')"
    printf 'macos=%s\n' "$(sw_vers -productVersion 2>/dev/null || printf 'unknown')"
    printf 'hardware=%s\n' "$(uname -m)"
    printf 'app=%s\n' "$app_path"
    printf 'database=%s\n' "$database_path"
    printf 'pid=%s\n' "$app_pid"
    printf 'startup_status=%s\n' "$startup_status"
    printf 'startup_seconds=%s\n' "${startup_seconds:-unavailable}"
    printf 'total_seconds=%s\n' "$total_seconds"
    printf 'wal_bytes_before=%s\n' "$wal_bytes_before"
    printf 'wal_bytes_after=%s\n' "$(wal_bytes)"
    printf 'samples=%s\n' "$samples"
    awk -F, 'NR > 1 {
        phase=$2; count[phase]++; cpu[phase]+=$3; rss[phase]+=$4;
        if ($3 > max_cpu[phase]) max_cpu[phase]=$3;
        if ($4 > max_rss[phase]) max_rss[phase]=$4;
        last_wal[phase]=$5
    } END {
        for (phase in count) {
            printf "%s_samples=%d\n", phase, count[phase];
            printf "%s_cpu_mean_percent=%.2f\n", phase, cpu[phase]/count[phase];
            printf "%s_cpu_max_percent=%.2f\n", phase, max_cpu[phase];
            printf "%s_rss_mean_mb=%.2f\n", phase, rss[phase]/count[phase]/1024;
            printf "%s_rss_max_mb=%.2f\n", phase, max_rss[phase]/1024;
            printf "%s_wal_bytes_after=%d\n", phase, last_wal[phase];
        }
    }' "$samples"
} > "$summary"

trap - EXIT INT TERM
cleanup
printf 'Measurement written to %s\n' "$output_path"
cat "$summary"
