# 0194: the guest bytes at an instruction FEX could not decode

`build/ntdll-unix/signal_arm64_ios.c`, `ill_handler`: next to the existing `ILL diag` lines, one `[ill-guest-bytes]` line with the 64 guest bytes from `rip - 16` (the instruction starts at the 17th). Diagnostic only.

Why: Black Ops Cold War (1.3.101 log, 2026-11-08 22:57) got past its image rebuild (patch 0193) and then died with 0xC000001D (`E B0 Invalid instruction in entry block: 707145ECDA`, guest rip in anonymous executable memory the game had just filled). An instruction FEX lacks, or code that was never decrypted, look different in these bytes.
`tools/engine.sh accept`.
