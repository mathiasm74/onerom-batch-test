# onerom-batch-test

Batch-flash and bus-test [One ROM](https://github.com/piersfinlayson/one-rom)
Fire boards using a One ROM Lab, one board after another, with a CSV log of
every result.

The upstream repo ships the pieces (`onerom program --batch`, the Lab firmware
and its interactive shell) but nothing that loops over a pile of boards and
drives the Lab for you. This script is that glue.

## What it does

For each board:

1. Waits for it to be plugged into USB.
2. If blank, flashes it with the `rand_64KB` test image plus the `usb` (system)
   and `rgb` (user) plugins. The usb plugin keeps the board serving while USB
   powered.
3. Polls the Lab until the board is seated on the pogo pins.
4. Runs checksum reads on the Lab and compares SHA1 and tristate failures
   against the expected values. PASS only if every read matches with zero
   failures.
5. On a failure, waits for you to lift and re-seat the board and reruns the
   test, up to `ATTEMPTS` times, before recording the board as failed.
6. Appends a CSV line (timestamp, serial, board, result, reads, SHA1s,
   failures) to the log, plays a sound, waits for the board to be unplugged.

With no Lab connected it offers to turn the next board plugged in into one
(needs `picotool`), or to program boards without testing.

## Bench setup: the Lab and the board under test

The Lab is a spare One ROM Fire board running the
[One ROM Lab](https://github.com/piersfinlayson/one-rom/tree/main/rust/lab)
firmware, with pogo pins in its ROM socket. The board under test is pressed
onto those pins so the Lab can read it like a ROM chip.

**Both boards need their own USB cable to the computer.** The pogo pins carry
only the ROM socket signals, not USB.

- **The Lab** is driven over its USB serial (CDC) port. The script sends it
  read commands and parses the SHA1, checksum and tristate results it prints.
  It also has to be seen by `onerom scan`, which is how the script finds its
  serial number and picks the right port.
- **The board under test** is powered from its own USB cable, and that same
  cable is how the `onerom` CLI flashes it and how the script detects it being
  plugged in and unplugged. The `usb` system plugin in the test image is what
  keeps the board serving the ROM while it is USB powered. Without that plugin
  One ROM drops into its bootloader whenever it sees VBUS, and there would be
  nothing on the socket pins for the Lab to read.

Because both boards show up in `onerom scan` and both expose a serial port,
the script tells them apart by USB serial number rather than by port name.
Only one Lab should be connected at a time. Boards with the same pin count as
the Lab are the only ones it can test.

Keep the Lab plugged in for the whole session. Plug each board under test in,
let the script flash it, press it onto the pogo pins when asked, and unplug it
when the result is shown.

## Usage

```
onerom-batch-test.sh <board> [--reads N] [--no-flash|--reflash] [--no-test] [--lab-to-normal]
```

| Argument | Meaning |
|---|---|
| `board` | Any Fire board the CLI knows, e.g. `fire-24-e` or just `24-e`. Ice (STM32) boards are not supported by the CLI or by Lab. |
| `--reads N` | Reads per board (default 3). |
| `--no-flash` | Never program; only test boards that already carry the image. |
| `--reflash` | Program every board, even one already programmed. |
| `--no-test` | Program only, no Lab needed. |
| `--lab-to-normal` | Turn the connected Lab back into a normal board, then exit. |

## Requirements

- `onerom` CLI on `PATH` (or set `ONEROM=/path/to/onerom`)
- `python3` with `pyserial`
- A One ROM Lab whose pin count matches the boards under test
- `picotool`, only if you want the script to make a Lab for you
- zsh (macOS)

## Files and overrides

Nothing is tied to a particular machine. The test images ship in `images/`,
the log is written next to the script, and the `onerom` CLI is taken from
`PATH`. Each can be overridden with an environment variable.

| Variable | Default | Purpose |
|---|---|---|
| `ONEROM` | `onerom` on `PATH`, else `~/.local/bin/onerom` | The One ROM CLI |
| `IMAGES` | `<repo>/images` | Test ROM images (`rand_64KB.rom`, `rand_512KB.rom`) |
| `LOG` | `<repo>/onerom-batch-test.log` | CSV results log, gitignored |
| `LAB_DIR` | `$XDG_CACHE_HOME/onerom-batch-test` or `~/.cache/onerom-batch-test` | Downloaded Lab firmware images |
| `LAB_VERSION` | `0.4.0` | Lab release to download when making a Lab |

Example:

```
LOG=~/batches/2026-10.csv ./onerom-batch-test.sh 24-e
```

## Handling tips

Hold boards by the edges, not across the pin tails. Skin across the pins makes
released data lines flaky and shows up as tristate failures.
