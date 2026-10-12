# Draft: One ROM Lab checksum mode honouring a range

**Status: low priority, not filed.**

`output_checksum` in `rust/lab/src/cli/commands.rs` prints
"Warning: range ... ignored — reading full ROM." and carries a TODO to wire
up streaming range reads. A batch tester polls the Lab to find out whether a
board is seated on the pogo pins, and each poll currently costs a full read
of the chip. A honoured range, or a dedicated short presence probe, would
make that poll near instant and let a tester detect a lift-off within a
fraction of a second.

Suggested wording: "+1 on the TODO in output_checksum. Use case: polling for
a board on pogo pins before a full test read. A 256 byte range read, or any
cheap presence probe, is enough."
