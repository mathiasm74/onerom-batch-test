# Draft: a running One ROM intermittently missing from `onerom scan`

**Status: do not file yet.** The mechanism below is measured. What is not yet
known is what held the device on the batch bench. Run one batch session with
the script's new miss reporting (it prints the CLI's WARN line on each miss)
and attach those lines before filing. If every miss says "could not be
opened", this is a bench problem (another process holding the interface) and
there may be nothing to report at all.

## Measurements, 2026-10-12, macOS, CLI v0.5.0, Fire 24 E firmware v0.8.0

A loop of `onerom --unrecognised scan` every 0.1 s against a running board
with the usb plugin:

| Condition | Scans | Missed | Longest gap |
|---|---|---|---|
| Board idle, nothing else using it | 726 | 0 | 0 |
| Board's CDC serial port held open by pyserial | 237 | 0 | 0 |
| A second `onerom inspect info --serial ...` running in a loop | 454 | 326 | 1.49 s |
| Same, repeated | 222 | 156 | 1.15 s |

The USB `sessionID` in `ioreg` was identical before and after every run, so
the device never re-enumerated. The misses are host-side.

With stderr visible, each miss carries:

```
WARN:  Device with serial E7E47917A0C2B0CE could not be opened - ignored
  Failed to claim USB interface on 1209:f542: could not open interface for exclusive access (error 0xe00002c5)
```

So the CLI already detects and reports the case. The batch script was hiding
it with `2>/dev/null`, which is why it looked like a random dropout.

## What would make this an upstream issue

Only if the batch bench shows misses whose WARN line is something other than
"could not be opened", for example a picoboot timeout while the board is
being read on the bus by the Lab. That would point at the usb plugin not
servicing picoboot while serving at speed. The gaps seen on the bench (up to
about 1.6 s) match the contention gaps measured above, which argues against
it, but it has not been ruled out.

## Possible small CLI request regardless

`scan` could print the skipped-device warning at INFO level even when other
devices were found only if `--verbose`, but at WARN level when the skipped
device is the one named by `--serial`. Today `program --serial X` fails with
"One ROM not found: X" when X is present but held by another process, which
sends the user looking for a cable fault.
