# Suspected issues that are not upstream bugs

## "The CLI buffers its output when not talking to a terminal"

The script comment blamed the CLI for holding back "DO NOT DISCONNECT" when
piped. The CLI prints with `println!`, and Rust's stdout is line-buffered
regardless of whether it is a terminal, so every line is flushed at its
newline. The likely culprit was the `sed` on the other side of the pipe,
which block-buffers when its own stdout is not a terminal. The script already
uses `sed -l` for the build step for that reason. Not reportable.

## "The Lab's CS polarity has to be answered interactively"

Not true. `cmd_read` takes the CS1, CS2 and CS3 polarities as optional
tokens after the format, so `r:2364:0:0:cs:0` answers the prompt up front.
The script's prompt-detection loop in `lab_read` can be replaced by passing
the token. Script improvement, not a report.
