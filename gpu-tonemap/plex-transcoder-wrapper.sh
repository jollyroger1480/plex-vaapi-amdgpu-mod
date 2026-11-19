#!/usr/bin/bash
# Plex Transcoder wrapper: GPU (OpenCL) HDR tone mapping for AMD radeonsi.
#
# Installed as "/usr/lib/plexmediaserver/Plex Transcoder"; the real binary is
# "Plex Transcoder.real" next to it.
#
# Every job is passed through untouched (exec, same pid, same argv, same env)
# unless ALL of these hold:
#   - one -filter_complex is exactly Plex's CPU HDR chain
#       [0:V]scale=w=W:h=H:force_divisible_by=4[a];[a]format=p010,tonemap=hable[b];
#       [b]format=pix_fmts=nv12[c];[c]hwupload[OUT]
#   - the options before the first -i are all ones this script understands
#   - -copyts, -start_at_zero and one "-init_hw_device vaapi=NAME:/dev/dri/..." exist
#   - an OpenCL device works (checked once per container start)
#   - not disabled (env PLEX_GPU_TONEMAP=0 or file /config/gpu-tonemap.disable)
#
# For a matching job it runs two processes:
#   1. feeder (child): decode input 0 on VAAPI -> scale_vaapi -> tonemap_opencl
#      -> raw nv12 in NUT on a pipe. A tiny silent anchor audio stream at pts 0 keeps the pipe's
#      start_time at 0, so -copyts/-start_at_zero timestamps line up with input 0.
#   2. Plex's own argv (exec'd, keeps Plex's pid), with the pipe added as the last
#      input and the CPU chain replaced by "[K:0]hwupload[OUT]". Audio, subtitles,
#      maps, -ss, progress URL, DASH output: all unchanged.
# If Plex kills the main process the feeder dies on the broken pipe (SIGPIPE).
set -u
REAL="${0%/*}/Plex Transcoder.real"
[ -x "$REAL" ] || REAL="/usr/lib/plexmediaserver/Plex Transcoder.real"
STATE=/tmp/plex-gpu-tonemap
LOG=$STATE/wrapper.log

pass() { # $1 = reason (logged only when the job looked like HDR)
  [ -n "${1:-}" ] && log "passthrough: $1"
  exec -a "$0" "$REAL" "${ARGS[@]}"
}
log() { mkdir -p "$STATE" 2>/dev/null && printf '%s [%s] %s\n' "$(date '+%F %T')" "$$" "$*" >> "$LOG" 2>/dev/null; }

ARGS=("$@")

# Fast path: not an HDR tone-map job.
hit=0
for a in "$@"; do case "$a" in *tonemap=hable*) hit=1; break;; esac; done
[ "$hit" = 1 ] || exec -a "$0" "$REAL" "$@"

[ "${PLEX_GPU_TONEMAP:-1}" = 0 ] && pass "disabled by env"
[ -e /config/gpu-tonemap.disable ] && pass "disabled by /config/gpu-tonemap.disable"

re='^\[0:([^]]+)\]scale=w=([0-9]+):h=([0-9]+):force_divisible_by=4\[([A-Za-z0-9_]+)\];\[([A-Za-z0-9_]+)\]format=p010,tonemap=hable\[([A-Za-z0-9_]+)\];\[([A-Za-z0-9_]+)\]format=pix_fmts=nv12\[([A-Za-z0-9_]+)\];\[([A-Za-z0-9_]+)\]hwupload\[([A-Za-z0-9_]+)\]$'

n=${#ARGS[@]}
fc_idx=-1; first_i=-1; ninputs=0; last_i=-1; copyts=0; saz=0; va_init=""; nva=0; nfc_tm=0; direct0=""
for ((k=0; k<n; k++)); do
  a=${ARGS[k]}
  case "$a" in
    -i) ninputs=$((ninputs+1)); [ $first_i -lt 0 ] && first_i=$k; last_i=$k ;;
    -copyts) copyts=1 ;;
    -start_at_zero) saz=1 ;;
    -init_hw_device) v=${ARGS[k+1]:-}; case "$v" in vaapi=*) va_init=$v; nva=$((nva+1));; esac ;;
    -filter_complex) case "${ARGS[k+1]:-}" in *tonemap*) nfc_tm=$((nfc_tm+1)); fc_idx=$((k+1));; esac ;;
    -map) case "${ARGS[k+1]:-}" in 0:*) direct0=${ARGS[k+1]};; esac ;;
  esac
done
# A stream mapped straight from input 0 (e.g. an embedded MP4 mov_text subtitle)
# makes ffmpeg keep reading input 0 for that sparse stream and never service
# pipe:3, so video stalls after the first segment. Leave those jobs on the CPU.
[ -z "$direct0" ] || pass "stream mapped directly from input 0: $direct0"
[ $nfc_tm = 1 ] || pass "tonemap in $nfc_tm filter graphs"
fc=${ARGS[fc_idx]}
[[ $fc =~ $re ]] || pass "filter graph not the known CPU chain: $fc"
V=${BASH_REMATCH[1]}; W=${BASH_REMATCH[2]}; H=${BASH_REMATCH[3]}; OUT=${BASH_REMATCH[10]}
[ "${BASH_REMATCH[4]}" = "${BASH_REMATCH[5]}" ] && [ "${BASH_REMATCH[6]}" = "${BASH_REMATCH[7]}" ] \
  && [ "${BASH_REMATCH[8]}" = "${BASH_REMATCH[9]}" ] || pass "filter labels do not chain"
[ $copyts = 1 ] && [ $saz = 1 ] || pass "no -copyts/-start_at_zero"
[ $nva = 1 ] || pass "$nva vaapi devices"
[[ $va_init =~ ^vaapi=([A-Za-z0-9_]+):(/dev/dri/[A-Za-z0-9]+)$ ]] || pass "vaapi device string: $va_init"
VANAME=${BASH_REMATCH[1]}; VADEV=${BASH_REMATCH[2]}
[ $first_i -ge 0 ] || pass "no input"
SRC=${ARGS[first_i+1]:-}
[ -f "$SRC" ] && [ -r "$SRC" ] || pass "input 0 not a readable file"

# Input-0 options: copy the ones that matter to the feeder, refuse unknown ones.
feed_in=()
for ((k=0; k<first_i; k++)); do
  a=${ARGS[k]}; b=${ARGS[k+1]:-}
  case "$a" in
    -codec:"$V"|-c:"$V")               feed_in+=("$a" "$b"); k=$((k+1)) ;;
    -codec:*|-c:*|-eae_prefix:*)     k=$((k+1)) ;;            # audio decoders: main process only
    -hwaccel:"$V"|-hwaccel_device:"$V")feed_in+=("${a%%:*}" "$b"); k=$((k+1)) ;;
    -ss|-analyzeduration|-probesize) feed_in+=("$a" "$b"); k=$((k+1)) ;;
    -noaccurate_seek|-accurate_seek) feed_in+=("$a") ;;
    *) pass "unknown input option $a" ;;
  esac
done
printf '%s\n' "${feed_in[@]}" | grep -qx -- -hwaccel || pass "input 0 not VAAPI-decoded"

# OpenCL check once per container start (cached in /tmp).
mkdir -p "$STATE" 2>/dev/null || pass "no state dir"
if [ ! -e "$STATE/ocl.ok" ] && [ ! -e "$STATE/ocl.bad" ]; then
  if timeout 20 "$REAL" -hide_banner -init_hw_device opencl=ocl 2>&1 | grep -q 'Device creation failed\|No such device'; then
    : > "$STATE/ocl.bad"
  else
    : > "$STATE/ocl.ok"
  fi
fi
[ -e "$STATE/ocl.ok" ] || pass "OpenCL device unavailable"

ANCHOR=$STATE/anchor.wav   # 16 bytes of silence, 8 kHz mono s16le, starts at pts 0
[ -s "$ANCHOR" ] || printf 'RIFF\x34\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80\x3e\x00\x00\x02\x00\x10\x00data\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$ANCHOR"

# Main argv: add the pipe as the last input, swap the CPU chain for an upload.
K=$ninputs
main=()
for ((k=0; k<n; k++)); do
  if [ $k = $fc_idx ]; then main+=("[$K:0]hwupload[$OUT]"); continue; fi
  main+=("${ARGS[k]}")
  if [ $k = $((last_i+1)) ]; then
    main+=(-f nut -probesize 65536 -analyzeduration 0 -thread_queue_size 64 -i pipe:3)
  fi
done

TM="tonemap_opencl=tonemap=hable:desat=${PLEX_GPU_TONEMAP_DESAT:-0}:format=nv12:t=bt709:m=bt709:p=bt709"
feed=(-hide_banner -nostdin -nostats -loglevel error
  -init_hw_device "vaapi=$VANAME:$VADEV" -init_hw_device opencl=ocl -filter_hw_device ocl
  "${feed_in[@]}" -hwaccel_output_format vaapi -i "$SRC"
  -i "$ANCHOR" -copyts -start_at_zero
  -filter_complex "[0:$V]scale_vaapi=w=$W:h=$H:format=p010,hwdownload,format=p010,hwupload,$TM,hwdownload,format=nv12[v]"
  -map "[v]" -map 1:0 -c:v rawvideo -c:a copy -fps_mode passthrough -avoid_negative_ts disabled
  -max_interleave_delta 100000 -flush_packets 1 -f nut pipe:1)

find "$STATE" -name 'feed-*.log' -mmin +1440 -delete 2>/dev/null
log "gpu: src=$SRC v=$V ${W}x$H out=$OUT K=$K"
# If the feeder fails while the main process is still alive (GPU hang, driver
# error), stop the main process so Plex sees a failed transcode and retries,
# instead of a frozen picture with audio running on. EPIPE (main gone) and a
# clean end of file are left alone.
MAIN=$$
exec 3< <(
  "$REAL" "${feed[@]}" 2>"$STATE/feed-$MAIN.log"; rc=$?
  if [ $rc != 0 ] && ! grep -q 'Error number -32' "$STATE/feed-$MAIN.log" 2>/dev/null \
     && [ "$(readlink "/proc/$MAIN/exe" 2>/dev/null)" = "$REAL" ]; then
    log "feeder failed rc=$rc, stopping main $MAIN"
    kill -TERM "$MAIN" 2>/dev/null
  fi
)
exec -a "$0" "$REAL" "${main[@]}"
