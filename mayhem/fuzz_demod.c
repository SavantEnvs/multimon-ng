/*
 * fuzz_demod: run one multimon-ng demodulator over raw audio, the way input_file() in
 * unixinput.c feeds it (raw s16 samples, read in 16 KiB chunks, float conversion, overlap).
 *
 * Input layout: [0] demodulator index, [1..3] the CLI options a user could pass
 * (-v, --json, -A, -p, -u, -e, -P, -f, -b, -j, -x, -y), [4..] raw 16-bit samples.
 * unixinput.c is #included (main renamed by the build) to reuse its demodulator table,
 * dem_st[] and process_buffer() unchanged.
 */
#define _GNU_SOURCE
#include "unixinput.c"

#include <stddef.h>

extern int aprs_mode;
extern int flex_disable_timestamp;

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
    if (size < 6)
        return -1;

    unsigned idx = data[0] % NUMDEMOD;
    uint8_t a = data[1], b = data[2], c = data[3];
    const uint8_t *raw = data + 4;
    size_t nsamp = (size - 4) / sizeof(short);

    verbose_level = a & 3;
    json_mode = (a >> 2) & 1;
    aprs_mode = (a >> 3) & 1;
    pocsag_show_partial_decodes = (a >> 4) & 1;
    pocsag_heuristic_pruning = (a >> 5) & 1;
    pocsag_prune_empty = (a >> 6) & 1;
    fms_justhex = (a >> 7) & 1;
    pocsag_mode = b % 5;
    pocsag_polarity = ((b >> 3) & 3) % 3;
    pocsag_error_correction = ((b >> 5) & 3) % 3;
    cw_disable_auto_threshold = c & 1;
    cw_disable_auto_timing = (c >> 1) & 1;
    dont_flush = true;

    struct demod_state *st = dem_st + idx;
    memset(st, 0, sizeof(*st));
    st->dem_par = dem[idx];
    if (dem[idx]->init)
        dem[idx]->init(st);

    static short sbuf[8192];
    static float fbuf[16384];
    memset(sbuf, 0, sizeof(sbuf));
    memset(fbuf, 0, sizeof(fbuf));
    unsigned overlap = dem[idx]->overlap;
    unsigned fbuf_cnt = 0;
    bool use_float = dem[idx]->float_samples;

    size_t pos = 0;
    while (pos < nsamp) {
        size_t n = nsamp - pos;
        if (n > 8192)
            n = 8192;
        memcpy(sbuf, raw + pos * sizeof(short), n * sizeof(short));
        pos += n;
        if (use_float) {
            for (size_t i = 0; i < n; i++)
                fbuf[fbuf_cnt++] = sbuf[i] * (1.0f / 32768.0f);
        } else {
            fbuf_cnt = n;
        }
        if (fbuf_cnt > overlap) {
            process_buffer(fbuf, sbuf, fbuf_cnt - overlap);
            memmove(fbuf, fbuf + fbuf_cnt - overlap, overlap * sizeof(fbuf[0]));
            fbuf_cnt = overlap;
        }
    }

    if (dem[idx]->deinit)
        dem[idx]->deinit(st);
    return 0;
}
