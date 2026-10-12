#!/bin/zsh
# Batch-flash and bus-test One ROM boards with One ROM Lab.
#
# For each board:
#   1. Wait for it to be plugged into USB.
#   2. If blank, flash it with the rand_64KB test image plus the usb (system)
#      and rgb (user) plugins.  The usb plugin is what keeps the board serving
#      while it is USB powered; without it the firmware drops into the
#      bootloader whenever it sees VBUS.
#   3. Poll the Lab until the board is seated on the pogo pins (hold it by the
#      edges, not across the pin tails - skin across the pins makes released
#      data lines flaky and shows up as tristate failures).  No key to press.
#   4. Run READS checksum reads on the Lab and compare SHA1 and tristate
#      failures against the expected values.  PASS only if every read matches
#      with zero failures.
#   5. On a failure, lift the board off and re-seat it; the test reruns by
#      itself, up to ATTEMPTS times, before the board is recorded as failed.
#   6. Append a line to the log (with the serial), play a sound, wait for the
#      board to be unplugged, loop.
#
# Requires: onerom CLI, python3 with pyserial, and a One ROM Lab plugged in
# whose pin count matches the boards being tested.  With no Lab, the script
# offers to turn the next board plugged in into one (needs picotool), or to
# program boards without testing.
#
# Usage: onerom-batch-test.sh <board> [--reads N] [--no-flash|--reflash] [--no-test] [--lab-to-normal]
#   board        any Fire board type the CLI knows (onerom board list), e.g.
#                fire-24-e, or just 24-e.  Ice (STM32) boards are not supported
#                by the CLI or by Lab.
#   --reads N    reads per board (default 3)
#   --no-flash   never program; only test boards that already carry the image
#   --reflash    program every board, even one that is already programmed
#   --no-test    program only, no Lab needed (offered interactively if no Lab is found)
#   --lab-to-normal
#                turn the connected Lab back into a normal board (programmed
#                like any other board, with the test image), then exit

set -u
set -o pipefail   # so a failed "onerom program" is seen through the sed indent

# Everything on disk is relative to this script or overridable from the
# environment, so a checkout works anywhere.
SCRIPT_DIR="${0:A:h}"
ONEROM="${ONEROM:-$(command -v onerom || echo "$HOME/.local/bin/onerom")}"
IMAGES="${IMAGES:-$SCRIPT_DIR/images}"                  # test ROM images
LOG="${LOG:-$SCRIPT_DIR/onerom-batch-test.log}"         # CSV results
READS=3
ATTEMPTS=3
FLASH=1       # 1 = flash blank boards, 0 = never flash, 2 = flash every board
TEST=1        # 1 = bus-test on the Lab, 0 = program only
UNLAB=0       # 1 = reprogram the connected Lab as a normal board and exit
LAB_VERSION="${LAB_VERSION:-0.4.0}"             # One ROM Lab release to flash when making a Lab
LAB_DIR="${LAB_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/onerom-batch-test}"  # downloaded Lab images

usage() { echo "Usage: $0 <board> [--reads N] [--no-flash|--reflash] [--no-test] [--lab-to-normal]" >&2; exit 1; }
[[ $# -ge 1 ]] || usage

# Board: "fire-24-e", "24-e" or "onerom-24-e" all mean fire-24-e.  Validated
# against the CLI's own list so every board it can program is accepted.
BOARD="${1:l}"
BOARD="${BOARD#onerom-}"
[[ "$BOARD" == fire-* || "$BOARD" == ice-* ]] || BOARD="fire-$BOARD"
shift
if [[ "$BOARD" == ice-* ]]; then
  echo "$BOARD is an Ice (STM32) board; the onerom CLI and One ROM Lab only work with Fire (RP2350) boards." >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reads)
      [[ $# -ge 2 && "$2" == <1-> ]] || { echo "--reads needs a whole number of 1 or more." >&2; usage; }
      READS="$2"; shift 2 ;;
    --no-flash) FLASH=0; shift ;;
    --reflash) FLASH=2; shift ;;
    --no-test) TEST=0; shift ;;
    --lab-to-normal|--unlab) UNLAB=1; FLASH=2; shift ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -x "$ONEROM" ]] || { echo "onerom CLI not found (looked at $ONEROM). Put it on PATH or set ONEROM=/path/to/onerom." >&2; exit 1; }
known=$("$ONEROM" board list 2>/dev/null | sed -n '/Supported One ROM board types/,/^$/p' | tr -d ' ' | tr ',' '\n')
if ! echo "$known" | command grep -q '^fire-'; then
  echo "Could not read the board list from '$ONEROM board list'; is the CLI working?" >&2
  exit 1
fi
if ! echo "$known" | command grep -qx "$BOARD"; then
  echo "Unknown board '$BOARD'.  The CLI supports:" >&2
  echo "$known" | command grep '^fire-' | tr '\n' ' ' | fold -s -w 76 | sed 's/^/  /' >&2
  echo "" >&2
  exit 1
fi
PINS="${${BOARD#fire-}%%-*}"

# What the board serves, and what the Lab reads it as.  One chip per pin
# count: the largest common EPROM/mask ROM of that package, so every address
# line is exercised.  Chips with a configurable CS get it answered active-low at
# Lab's prompt; EPROMs with fixed /CE /OE prompt for nothing.
case "$PINS" in
  24) CHIP="2364";   SERVED_BYTES=$((8*1024));   IMAGE="$IMAGES/rand_64KB.rom"
      SLOT="file=$IMAGE,type=2364,cs1=active-low,size-handling=truncate" ;;
  28) CHIP="27512";  SERVED_BYTES=$((64*1024));  IMAGE="$IMAGES/rand_64KB.rom"
      SLOT="file=$IMAGE,type=27512" ;;
  32) CHIP="27C040"; SERVED_BYTES=$((512*1024)); IMAGE="$IMAGES/rand_512KB.rom"
      SLOT="file=$IMAGE,type=27C040" ;;
  40) CHIP="27C400"; SERVED_BYTES=$((512*1024)); IMAGE="$IMAGES/rand_512KB.rom"
      SLOT="file=$IMAGE,type=27C400" ;;
  *)  echo "No test chip defined for a $PINS-pin board." >&2; exit 1 ;;
esac

[[ -f "$IMAGE" ]] || { echo "Test image not found: $IMAGE" >&2; exit 1; }
python3 -c "import serial" 2>/dev/null || { echo "pyserial missing: python3 -m pip install --break-system-packages pyserial" >&2; exit 1; }

# Expected SHA1 of exactly the bytes the board serves.
EXPECT_SHA1=$(head -c "$SERVED_BYTES" "$IMAGE" | shasum -a 1 | awk '{print $1}')

scan() { "$ONEROM" --unrecognised scan 2>/dev/null; }

# Sounds: Pop = programmed, Glass = pass, Basso = fail.  Icons: 💾 programmed, ✅ pass, ❌ fail.
chime() { afplay "/System/Library/Sounds/$1.aiff" 2>/dev/null & }

# Action prompts - what you must do next - stand out in bold reverse video
# (plain text when output is not a terminal).
if [[ -t 1 ]]; then
  act() { printf '\e[1;7;33m %s \e[0m' "$*"; }
else
  act() { printf '[%s]' "$*"; }
fi


# ---- Find the Lab -----------------------------------------------------------

# The Lab's CDC port, chosen by USB serial number - a board under test with the
# usb plugin exposes a serial port too, so /dev/cu.usbmodem* alone is ambiguous.
lab_port() {
  python3 - "$LAB_SERIAL" <<'EOF'
import sys, serial.tools.list_ports as lp
for p in lp.comports():
    if p.serial_number == sys.argv[1]:
        print(p.device); break
EOF
}

# Look for a running Lab.  Sets LAB_SERIAL and LAB_PORT; returns 1 if none.
find_lab() {
  local lab_line lab_pins
  lab_line=$(scan | grep "One ROM Lab")
  [[ -n "$lab_line" ]] || return 1
  LAB_SERIAL=$(echo "$lab_line" | grep -o 'Serial: [A-F0-9]*' | awk '{print $2}')
  lab_pins=$(echo "$lab_line" | grep -o 'Fire [0-9]*' | awk '{print $2}')
  if [[ "$lab_pins" != "$PINS" ]]; then
    echo "Lab is a $lab_pins-pin board; it cannot test $PINS-pin boards." >&2
    exit 1
  fi
  # The CDC port can appear a moment after the Lab shows up in a scan.
  local i
  for i in {1..20}; do
    LAB_PORT=$(lab_port)
    [[ -n "$LAB_PORT" ]] && return 0
    sleep 0.5
  done
  echo "Lab $LAB_SERIAL found but its serial port did not appear." >&2
  return 1
}

# Turn the next board plugged in into a One ROM Lab.  Uses the ready-built Lab
# image for $BOARD from the lab-v$LAB_VERSION GitHub release (cached in
# $LAB_DIR) and flashes it with picotool, since the onerom CLI only writes One
# ROM firmware.  Works on a blank board (stock RP2350 bootloader), a board
# sitting in its bootloader, or one running One ROM with the usb plugin.
make_lab() {
  local bin="$LAB_DIR/onerom-lab-$BOARD-$LAB_VERSION.bin"
  local url="https://github.com/piersfinlayson/one-rom/releases/download/lab-v$LAB_VERSION/onerom-lab-$BOARD-$LAB_VERSION.bin"
  command -v picotool >/dev/null || { echo "picotool is needed to flash Lab:  brew install picotool" >&2; exit 1; }

  if [[ ! -s "$bin" ]]; then
    mkdir -p "$LAB_DIR"
    echo "Downloading Lab v$LAB_VERSION image for $BOARD..."
    curl -fsSL -o "$bin" "$url" || { echo "Download failed: $url" >&2; rm -f "$bin"; exit 1; }
  fi
  echo "Lab image: $bin"

  echo ""
  echo "$(act "PLUG IN THE BOARD TO BECOME THE LAB")"
  printf "    waiting... "
  local out serial i
  while true; do
    out=$(scan | grep -v "One ROM Lab")
    echo "$out" | grep -q "Serial:" && break
    sleep 0.3
  done
  serial=$(echo "$out" | grep -o 'Serial: [A-F0-9]*' | head -1 | awk '{print $2}')
  echo "found."
  sleep 2

  # Into the bootloader.  A running board (usb plugin) answers picoboot on
  # One ROM's running VID:PID; a blank or stopped board is already there.  A
  # running board drops off USB for a second or so at random, so the reboot
  # request is retried until picotool confirms it went through.
  if ! picotool info --ser "$serial" >/dev/null 2>&1 && \
     ! picotool info --vid 0x1209 --pid 0xf540 --ser "$serial" >/dev/null 2>&1; then
    for i in {1..20}; do
      picotool reboot -u --vid 0x1209 --pid 0xf542 --ser "$serial" 2>&1 | grep -q "rebooted" && break
      sleep 0.5
    done
  fi
  local bl=() found=0
  for i in {1..60}; do
    if picotool info --ser "$serial" >/dev/null 2>&1; then bl=(); found=1; break; fi
    if picotool info --vid 0x1209 --pid 0xf540 --ser "$serial" >/dev/null 2>&1; then bl=(--vid 0x1209 --pid 0xf540); found=1; break; fi
    sleep 0.5
  done
  if [[ $found -eq 0 ]]; then
    echo "  ❌ Board did not enter its bootloader. Unplug it, hold BOOTSEL while plugging it back in, and retry."
    chime Basso
    return 1
  fi

  echo "    flashing Lab...  (do not disconnect)"
  out=$(picotool load "$bin" -t bin -o 0x10000000 -v --ser "$serial" "${bl[@]}" 2>&1)
  if [[ $? -ne 0 ]] || ! echo "$out" | grep -q "OK"; then
    echo "  ❌ Flashing Lab failed:"
    echo "$out" | tr '\r' '\n' | grep -v "%" | sed 's/^/      /'
    chime Basso
    return 1
  fi
  echo "    verified."
  for i in {1..10}; do
    picotool reboot --ser "$serial" "${bl[@]}" 2>&1 | grep -q "rebooted" && break
    sleep 0.5
  done

  printf "    waiting for Lab to start... "
  for i in {1..40}; do
    if scan | grep "One ROM Lab" | grep "$serial" | grep -q "Running"; then echo "up."; break; fi
    sleep 0.5
  done
  if ! find_lab; then
    echo "  ❌ Lab flashed but is not answering. Unplug and replug it, then restart this script."
    chime Basso
    return 1
  fi
  echo "  🔬 This board is now the Lab ($LAB_SERIAL on $LAB_PORT).  Leave it plugged in."
  chime Pop
  return 0
}

LAB_SERIAL=""; LAB_PORT=""
if [[ $UNLAB -eq 1 ]]; then
  lab_line=$(scan | grep "One ROM Lab")
  [[ -n "$lab_line" ]] || { echo "No One ROM Lab connected to turn back into a normal board." >&2; exit 1; }
  if [[ $(echo "$lab_line" | wc -l) -gt 1 ]]; then
    echo "More than one Lab is connected. Leave only the one to reprogram plugged in." >&2
    exit 1
  fi
  LAB_SERIAL=$(echo "$lab_line" | grep -o 'Serial: [A-F0-9]*' | awk '{print $2}')
elif [[ $TEST -eq 1 ]]; then
  while ! find_lab; do
    echo ""
    echo "No One ROM Lab found.  What now?"
    echo "  [l]  make the next board I plug in a Lab, then test boards with it"
    [[ $FLASH -ne 0 ]] && echo "  [p]  program boards without testing them"
    echo "  [r]  I have plugged a Lab in, look again"
    echo "  [q]  quit"
    read -k 1 "?> "; echo ""
    case "$REPLY" in
      l|L) make_lab && break ;;
      p|P) [[ $FLASH -ne 0 ]] && { TEST=0; break; } ;;
      r|R) ;;
      q|Q|$'\x03'|$'\x1b') exit 1 ;;
    esac
  done
elif [[ $FLASH -eq 0 ]]; then
  echo "--no-test with --no-flash leaves nothing to do." >&2
  exit 1
fi

echo "Board:    $BOARD ($PINS pin), read by Lab as $CHIP"
echo "Image:    $IMAGE (first $SERVED_BYTES bytes)"
echo "Expected: SHA1 $EXPECT_SHA1, tristate failures 0"
if [[ $UNLAB -eq 1 ]]; then
  echo "Lab:      $LAB_SERIAL - will be reprogrammed as a NORMAL board, then exit"
elif [[ $TEST -eq 1 ]]; then
  echo "Lab:      $LAB_SERIAL on $LAB_PORT"
  echo "Reads:    $READS per board"
else
  echo "Lab:      none - PROGRAM ONLY, boards are not bus-tested"
fi
echo "Log:      $LOG"
case $FLASH in
  0) echo "Flash:    never" ;;
  1) echo "Flash:    blank boards only (usb, rgb plugins)" ;;
  2) echo "Flash:    every board (usb, rgb plugins)" ;;
esac

# ---- Lab read ---------------------------------------------------------------
# One serial session per call: opening the port toggles DTR, which starts a
# fresh Lab session and abandons any pending prompt, so everything for one read
# happens inside a single open.  Prints "SHA1 CHECKSUM FAILURES" or
# "ERROR <reason>".  Lab ignores a range in checksum mode and always reads
# the full ROM, so the seated-or-not poll is a full read too (about a second).
lab_read() {
  python3 - "$LAB_PORT" "$CHIP" "${1:-0}" <<'EOF'
import sys, time, re, serial
port, chip, length = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    s = serial.Serial(port, 115200, timeout=0.2)
except Exception as e:
    print("ERROR cannot open Lab port:", e); sys.exit(0)

def collect(stop, secs):
    """Read until stop(out) is true or secs elapse."""
    out = b""; end = time.time() + secs
    while time.time() < end:
        c = s.read(65536)
        if c:
            out += c
            if stop(out): break
    return out

def at_cs_prompt(o):
    # Lab is waiting at "CS1 polarity (...) [0]: " - the prompt is the LAST thing
    # printed.  Checking only the tail is what stops the "0" answer being sent
    # again once the read has started and the prompt has scrolled up.
    return re.search(rb"polarity[^\r\n]*\]: $", o) is not None

def done(o):
    return b"failures" in o and o.rstrip().endswith(b">")

time.sleep(0.4); s.read(65536)              # greeting
s.write(f"r:{chip}:0:{length}:cs\r".encode())
out = b""
for _ in range(4):                           # up to 3 CS polarity prompts, then the result
    out += collect(lambda o: at_cs_prompt(o) or done(o) or b"Unknown" in o, 10)
    if done(out) or b"Unknown" in out:
        break
    if at_cs_prompt(out):
        s.write(b"0\r")                      # active-low
        continue
    break                                    # nothing recognisable: give up quickly
s.close()
txt = out.decode(errors="replace")
# A 16-bit capable chip (27C400) is read in 8-bit and 16-bit mode and gives two
# result blocks, each labelled; a plain chip gives one, unlabelled.  Report the
# SHA1s and the failure counts as +-joined lists so the caller can insist on
# every one being right.  ("+" because zsh's (z) word splitting treats ";" as
# a separator, and "," is the log's column separator.)
shas  = re.findall(r"SHA1:\s*([0-9a-f]{40})\s+checksum:\s*(0x[0-9A-Fa-f]+)", txt)
fails = re.findall(r"tristate failures:\s*(\d+)", txt)
if shas and fails:
    print("+".join(h for h, _ in shas), "+".join(c for _, c in shas), "+".join(fails))
else:
    print("ERROR no result from Lab (hung? unplug and replug it). Output was:\n" + txt.strip())
EOF
}

# ---- Build the firmware once ------------------------------------------------
# Building resolves and downloads the plugins from images.onerom.org, about two
# seconds per call.  Doing it once here means programming a board starts the
# moment it is plugged in, and every board gets byte-identical firmware.
FW=""
ERRF="$(mktemp -t onerom-batch-err)"
trap 'rm -f "$ERRF" "$FW"' EXIT
if [[ $FLASH -ne 0 ]]; then
  FW="$(mktemp -t onerom-batch-fw.bin)"   # the CLI overwrites it
  echo ""
  echo "Building firmware once ($BOARD, usb + rgb plugins, $SLOT)..."
  if ! "$ONEROM" -y firmware build --board "$BOARD" --plugin usb --plugin rgb \
         --slot "$SLOT" --output "$FW" 2>&1 | sed -l 's/^/    /'; then
    echo "Firmware build failed." >&2
    exit 1
  fi
  echo "Firmware: $FW"
fi

# ---- Lab back to a normal board ---------------------------------------------
# The normal batch loop never programs a Lab, so the Lab can't be flashed over
# by accident.  This is the deliberate way back.  The onerom CLI can program
# a running Lab directly; the CLI's device scan has the same random misses as
# for any board, so it is retried.
if [[ $UNLAB -eq 1 ]]; then
  echo ""
  echo "Reprogramming the Lab as a normal board..."
  ok=0
  for try in {1..5}; do
    if "$ONEROM" --unrecognised -y --serial "$LAB_SERIAL" program --board "$BOARD" --firmware "$FW" 2> "$ERRF"; then
      ok=1; break
    fi
    grep -q -E "No One ROMs found|One ROM not found" "$ERRF" || { sed 's/^/    /' "$ERRF"; break; }
    echo "    (board not seen by the CLI just now, retrying $try/5)"
    sleep 1
  done
  [[ $ok -eq 1 ]] || { echo "❌ Programming failed."; chime Basso; exit 1; }
  for i in {1..40}; do
    scan | grep "$LAB_SERIAL" | grep -v "One ROM Lab" | grep -q "State: Running" && break
    sleep 0.5
  done
  if scan | grep "$LAB_SERIAL" | grep -v "One ROM Lab" | grep -q "State: Running"; then
    echo "💾 Done. The board is a normal One ROM again, running the test image.  $(act "UNPLUG IT")"
    chime Glass
    exit 0
  fi
  echo "❌ The board did not come back as a running One ROM. Unplug and replug it, then run 'onerom scan'."
  chime Basso
  exit 1
fi

# ---- Main loop --------------------------------------------------------------

passed=0; failed=0
mkdir -p "$(dirname "$LOG")"
[[ -f "$LOG" ]] || echo "timestamp,serial,board,result,reads,sha1s,failures" >> "$LOG"

# Wait until the board has been absent for three seconds.  A scan takes about
# 50 ms, but a connected board sometimes drops out of scans for up to about 1.6
# seconds at a time, so a short absence must not count as an unplug (the board
# would be seen again as a new board and programmed twice).
#
# Measured 2026-10-12: a board the CLI cannot open because another process
# holds its USB interface is left out of the scan and reported on stderr as
# "could not be opened".  The first miss of each absence shows that reason,
# so a pattern of misses can be told apart from a real unplug.  See
# upstream/01-scan-misses-running-board.md.
zmodload zsh/datetime
wait_unplug() {
  local first_miss="" out why
  while true; do
    # One scan, both streams: the presence test and the reason for a miss
    # must come from the same scan or a flapping board defeats the reason.
    # "Serial: X" is the device line; the WARN line also contains X.
    out=$("$ONEROM" --unrecognised scan 2>&1)
    if echo "$out" | grep -q "Serial: $1"; then
      first_miss=""
    else
      if [[ -z "$first_miss" ]]; then
        first_miss=$EPOCHREALTIME
        why=$(echo "$out" | grep -i -m1 "warn")
        [[ -n "$why" ]] && echo "      (scan miss: ${why#*WARN:  })"
      fi
      (( EPOCHREALTIME - first_miss >= 3.0 )) && return
    fi
    sleep 0.1
  done
}

# "Seated" when a read returns anything other than an all-zero bus.  A Lab
# error (port gone, Lab hung) is fatal here: otherwise it looks exactly like
# "not seated" and the poll would wait forever without saying why.
seated() {
  local r=$(lab_read)
  if [[ "$r" == ERROR* ]]; then
    echo ""
    echo "  ❌ Lab: ${r#ERROR }" >&2
    echo "     Unplug and replug the Lab, then restart this script." >&2
    chime Basso
    exit 1
  fi
  [[ "${${(z)r}[2]}" == *[1-9A-Fa-f]* ]]
}

board_no=0
banner() {
  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "  Board #$1    (passed $passed, failed $failed)"
  echo "════════════════════════════════════════════════════════════════════"
}

while true; do
  echo ""
  echo "──> Waiting for a board to be plugged in...   (Ctrl-C to stop)"
  warned_lab=""
  while true; do
    all=$(scan)
    out=$(echo "$all" | grep -v "One ROM Lab")
    echo "$out" | grep -q "Serial:" && break
    # A Lab that isn't the tester never gets programmed by this loop, so say
    # so instead of sitting here silently.
    other_lab=$(echo "$all" | grep "One ROM Lab" | grep -v "${LAB_SERIAL:-__none__}" | grep -o 'Serial: [A-F0-9]*' | head -1 | awk '{print $2}')
    if [[ -n "$other_lab" && "$other_lab" != "$warned_lab" ]]; then
      warned_lab="$other_lab"
      echo ""
      echo "  ⚠️  The board you plugged in is a One ROM Lab. This loop never programs a Lab."
      echo "      To make it a normal board again, stop this script and run:"
      echo "          $0 $BOARD --lab-to-normal"
      echo "      Otherwise unplug it and plug in a board to test."
      chime Basso
    fi
    sleep 0.3
  done
  # Only the first board's line counts; with two plugged in, the second one's
  # state must not decide whether the first is blank.
  line=$(echo "$out" | grep "Serial:" | head -1)
  serial=$(echo "$line" | grep -o 'Serial: [A-F0-9]*' | awk '{print $2}')
  blank=0; echo "$line" | grep -q "Firmware: n/a" && blank=1
  board_no=$((board_no + 1))
  banner $board_no

  # ---- Flash ----
  if [[ $blank -eq 1 && $FLASH -eq 0 ]]; then
    echo "  ⏭  Board is blank and --no-flash was given.  $(act "UNPLUG IT")"
    wait_unplug "$serial"
    continue
  fi
  if [[ $blank -eq 1 || $FLASH -eq 2 ]]; then
    [[ $blank -eq 1 ]] && echo "  Blank board." || echo "  Board already programmed, reprogramming (--reflash)."
    # Let USB enumeration settle; a board plugged in a moment ago can still
    # fail picoboot reads.
    sleep 2
    # Not piped: the CLI buffers its output when it isn't talking to a
    # terminal, which would hold "DO NOT DISCONNECT" back until it had finished.
    # A connected board drops out of the CLI's device scan for a second or so
    # at random; if the CLI fails to select the board, wait and try again.
    prog_ok=0
    for try in {1..5}; do
      if "$ONEROM" --unrecognised -y --serial "$serial" program --board "$BOARD" --firmware "$FW" 2> "$ERRF"; then
        prog_ok=1; break
      fi
      # "No One ROMs found" when nothing is on the bus; "One ROM not found"
      # when the Lab is there but the board has dropped out.
      if grep -q -E "No One ROMs found|One ROM not found" "$ERRF"; then
        echo "    (board not seen by the CLI just now, retrying $try/5: $(grep -i -m1 'warn' "$ERRF" | sed 's/.*WARN:  //'))"
        sleep 1
      else
        sed 's/^/      /' "$ERRF"
        break
      fi
    done
    if [[ $prog_ok -eq 1 ]]; then
      # In program-only mode the "programmed and running" line below is the
      # one that matters, so say nothing here.
      if [[ $TEST -eq 1 ]]; then
        echo "  💾 Programmed."
        chime Pop
      fi
    else
      echo "  ❌ Programming failed.  $(act "UNPLUG IT") and check the board."
      chime Basso
      echo "$(date +%FT%T),$serial,$BOARD,PROGRAM_FAILED,0,," >> "$LOG"
      wait_unplug "$serial"
      continue
    fi
  elif [[ $TEST -eq 1 ]]; then
    echo "  Board already programmed; testing what it has."
  else
    echo "  Board already programmed; nothing to do.  $(act "UNPLUG IT")"
    wait_unplug "$serial"
    continue
  fi

  # ---- Wait for it to be Running (usb plugin keeps it serving on USB power) ----
  ok=0
  for i in {1..20}; do
    if scan | grep "$serial" | grep -q "State: Running"; then ok=1; break; fi
    sleep 1
  done
  if [[ $ok -eq 0 ]]; then
    echo "  ❌ Board is not running. A board without the usb plugin sits in its bootloader on USB power.  $(act "UNPLUG IT")"
    chime Basso
    echo "$(date +%FT%T),$serial,$BOARD,NOT_RUNNING,0,," >> "$LOG"
    wait_unplug "$serial"
    continue
  fi

  if [[ $TEST -eq 0 ]]; then
    passed=$((passed + 1))
    echo "  💾 Programmed and running.  $(act "UNPLUG IT")"
    chime Glass
    echo "$(date +%FT%T),$serial,$BOARD,PROGRAMMED_UNTESTED,0,," >> "$LOG"
    wait_unplug "$serial"
    echo "  Board removed."
    continue
  fi

  # ---- Bus test on the Lab ----
  attempt=0
  while true; do
    attempt=$((attempt + 1))
    echo ""
    echo "  $(act "PRESS THE BOARD ONTO THE POGO PINS")  hold it by the edges, not across the pin tails"
    printf "      waiting for the board on the pins... "
    while ! seated; do sleep 0.3; done
    echo "seated, hold still."
    sleep 0.5

    result="PASS"; shas=""; fails=""; wrong_shas=()
    for ((n = 1; n <= READS; n++)); do
      printf "      read %d/%d: " "$n" "$READS"
      r=$(lab_read)
      if [[ "$r" == ERROR* ]]; then
        echo "$r"
        result="ERROR"; break
      fi
      sha=${${(z)r}[1]}; csum=${${(z)r}[2]}; f=${${(z)r}[3]}
      shas="$shas$sha;"; fails="$fails$f;"
      # sha / csum / f are +-joined lists, one entry per read mode.
      sha_ok=1; for x in ${(s:+:)sha}; do [[ "$x" == "$EXPECT_SHA1" ]] || sha_ok=0; done
      tri_ok=1; for x in ${(s:+:)f};   do [[ "$x" == "0" ]] || tri_ok=0; done
      if [[ $sha_ok -eq 1 && $tri_ok -eq 1 ]]; then
        echo "ok    SHA1 matches, tristate failures 0"
      elif [[ $sha_ok -eq 1 ]]; then
        echo "FAIL  SHA1 matches, tristate failures $f  (a line not released - fingers on the pins?)"
        result="FAIL"
      elif [[ "$csum" != *[1-9A-Fa-f]* ]]; then
        echo "FAIL  read all zeros  (lost contact during the read)"
        result="FAIL"
      else
        echo "FAIL  SHA1 $sha != expected  (wrong bytes - contact, or a stuck line)"
        result="FAIL"; wrong_shas+=("$sha")
      fi
    done
    # Every read wrong in the same way on a board this run did not flash is
    # almost certainly a different image, not a bad board.
    if [[ $blank -eq 0 && $FLASH -ne 2 && ${#wrong_shas} -eq $READS && ${#${(u)wrong_shas}} -eq 1 ]]; then
      echo "      (the same wrong SHA1 every read: the board probably carries another image; try --reflash)"
    fi

    echo ""
    if [[ "$result" == "PASS" ]]; then
      passed=$((passed + 1))
      echo "  ✅ PASS  ($READS/$READS reads, attempt $attempt).  $(act "LET GO AND UNPLUG IT")"
      chime Glass
      echo "$(date +%FT%T),$serial,$BOARD,PASS,$READS,$shas,$fails" >> "$LOG"
      break
    fi

    chime Basso
    if [[ $attempt -ge $ATTEMPTS ]]; then
      failed=$((failed + 1))
      echo "  ❌ $result after $attempt attempts.  Recorded as $result.  $(act "UNPLUG IT")"
      echo "$(date +%FT%T),$serial,$BOARD,$result,$READS,$shas,$fails" >> "$LOG"
      break
    fi
    echo "  ❌ $result (attempt $attempt of $ATTEMPTS).  $(act "LIFT THE BOARD OFF, THEN RE-SEAT IT")"
    printf "      waiting for the board to be lifted off... "
    while seated; do sleep 0.3; done
    echo "off."
  done

  wait_unplug "$serial"
  echo "  Board removed."
done
