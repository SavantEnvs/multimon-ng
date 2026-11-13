# FMS CRC one-bit correction: `1 << (i+16)` shifts an `int` out of range

`fms.c:364` (and `:368`), in `fms_rxbit()`: when an FMS frame fails its CRC, the decoder tries to
repair a single bit with `msg ^ (1 << (i+16))` for `i` in 0..47. The literal `1` is an `int`, so for
`i >= 15` the shift is undefined behaviour (UBSan: `left shift of 1 by 31 places cannot be represented
in type 'int'`), and for `i >= 16` the repair can never touch the high bits of the 64-bit message at all.

Impact: every FMS frame with a bad CRC (i.e. any line noise after the 19-bit sync) reaches the UB; the
bit-flip repair is also silently wrong for the upper 32 bits.

Reproducer: `repro` (feed to `fuzz_rxbit` / `fuzz_rxbit-standalone`): decoder 4 (FMS), a sync pattern and a
48-bit frame with one flipped payload bit.

One-line fix: `(1ULL << (i+16))` in both places.
