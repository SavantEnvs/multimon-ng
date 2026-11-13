/*
 * fuzz_rxbit: feed demodulated bits straight into multimon-ng's link-layer decoders
 * (POCSAG, HDLC/AX.25 + APRS, UART, CLIP, FMS), skipping the audio front end that the
 * fuzz_demod target would need to synthesise a valid signal for.
 *
 * Input layout: [0] decoder, [1..2] CLI options (as in fuzz_demod), [3..] bits, MSB first.
 */
#define _GNU_SOURCE
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "multimon.h"

extern int json_mode;
extern int aprs_mode;
extern int pocsag_mode;
extern int pocsag_polarity;
extern int pocsag_error_correction;
extern int pocsag_show_partial_decodes;
extern int pocsag_heuristic_pruning;
extern int pocsag_prune_empty;
extern bool fms_justhex;

static ssize_t discard_write(void *cookie, const char *buf, size_t n)
{
    (void)cookie; (void)buf;
    return (ssize_t)n;
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void)argc; (void)argv;
    /* decoders print every message; send stdout to a sink (no path involved) */
    cookie_io_functions_t sink = { .write = discard_write };
    FILE *fp = fopencookie(NULL, "w", sink);
    if (fp) {
        setvbuf(fp, NULL, _IOFBF, 1 << 16);
        stdout = fp;
    }
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 4)
        return -1;

    static const struct demod_param *const owner[] = {
        &demod_poc12, &demod_afsk1200, &demod_ufsk1200, &demod_clipfsk, &demod_fmsfsk,
    };
    unsigned which = data[0] % 5;
    uint8_t a = data[1], b = data[2];

    json_mode = (a >> 2) & 1;
    aprs_mode = (a >> 3) & 1;
    pocsag_show_partial_decodes = (a >> 4) & 1;
    pocsag_heuristic_pruning = (a >> 5) & 1;
    pocsag_prune_empty = (a >> 6) & 1;
    fms_justhex = (a >> 7) & 1;
    pocsag_mode = b % 5;
    pocsag_polarity = ((b >> 3) & 3) % 3;
    pocsag_error_correction = ((b >> 5) & 3) % 3;

    struct demod_state st;
    memset(&st, 0, sizeof(st));
    st.dem_par = owner[which];

    switch (which) {
    case 0: pocsag_init(&st); break;
    case 1: hdlc_init(&st); break;
    case 2: uart_init(&st); break;
    case 3: clip_init(&st); break;
    default: fms_init(&st); break;
    }

    for (size_t i = 3; i < size; i++) {
        for (int k = 7; k >= 0; k--) {
            int bit = (data[i] >> k) & 1;
            switch (which) {
            case 0: pocsag_rxbit(&st, bit); break;
            case 1: hdlc_rxbit(&st, bit); break;
            case 2: uart_rxbit(&st, bit); break;
            case 3: clip_rxbit(&st, bit); break;
            default: fms_rxbit(&st, bit); break;
            }
        }
    }

    if (which == 0)
        pocsag_deinit(&st);
    return 0;
}
