#include "coilfind.h"

size_t sift_filter_bloom(const uint8_t *blocks, size_t stride, uint32_t first, uint32_t end,
                         const uint32_t *bits, const SiftBloomSpan *terms,
                         const SiftBloomSpan *clauses, size_t clause_count, uint32_t *out) {
    size_t count = 0;
    for (uint32_t i = first; i < end; ++i) {
        const uint8_t *block = blocks + (size_t)i * stride;
        int accepted = 1;
        for (size_t c = 0; c < clause_count && accepted; ++c) {
            SiftBloomSpan clause = clauses[c];
            int passed = 0;
            for (uint32_t t = clause.start; t < clause.start + clause.count && !passed; ++t) {
                SiftBloomSpan term = terms[t];
                int present = term.count != 0;
                for (uint32_t b = term.start; b < term.start + term.count && present; ++b) {
                    uint32_t bit = bits[b];
                    present = bit < stride * 8 && (block[bit >> 3] & (1u << (bit & 7))) != 0;
                }
                passed = present;
            }
            accepted = passed;
        }
        if (accepted) out[count++] = i;
    }
    return count;
}

#include <pthread.h>
#include <wctype.h>
#include <xlocale.h>
static locale_t unicode_locale;
static pthread_once_t unicode_once = PTHREAD_ONCE_INIT;
static void init_unicode_locale(void) { unicode_locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL); }
static uint32_t scalar(const uint8_t *s, size_t length, size_t *offset) {
    uint32_t c = s[(*offset)++];
    size_t extra = c < 128 ? 0 : c < 224 ? 1 : c < 240 ? 2 : 3;
    if (extra && *offset + extra <= length) {
        c &= (1u << (6 - extra)) - 1;
        while (extra--) c = (c << 6) | (s[(*offset)++] & 63);
    }
    return c;
}
static uint32_t lower_scalar(uint32_t c) {
    if (c < 128) return c >= 'A' && c <= 'Z' ? c + 32 : c;
    return unicode_locale ? (uint32_t)towlower_l((wint_t)c, unicode_locale) : c;
}
int sift_contains_unicode_folded(const uint8_t *text, size_t length, const uint8_t *needle, size_t needle_length) {
    if (!needle_length) return 0;
    pthread_once(&unicode_once, init_unicode_locale);
    for (size_t start = 0; start < length;) {
        size_t next = start;
        uint32_t first = lower_scalar(scalar(text, length, &next));
        size_t n = 0;
        if (first == lower_scalar(scalar(needle, needle_length, &n))) {
            if (n == needle_length) return 1;
            size_t t = next;
            while (n < needle_length && t < length) {
                if (lower_scalar(scalar(text, length, &t)) != lower_scalar(scalar(needle, needle_length, &n))) break;
                if (n == needle_length) return 1;
            }
        }
        start = next;
    }
    return 0;
}

int sift_fuzzy_name_score(const uint8_t *name, size_t length, const uint8_t *needle, size_t needle_length) {
    if (!needle_length) return 0;
    size_t next = 0;
    uint32_t wanted = scalar(needle, needle_length, &next);
    int unicode_ready = 0;
    if (wanted >= 128) { pthread_once(&unicode_once, init_unicode_locale); unicode_ready = 1; }
    wanted = lower_scalar(wanted);
    size_t gaps = 0, leading = 0;
    int started = 0;
    for (size_t offset = 0; offset < length;) {
        uint32_t value = scalar(name, length, &offset);
        if (value >= 128 && !unicode_ready) {
            pthread_once(&unicode_once, init_unicode_locale);
            unicode_ready = 1;
        }
        if (lower_scalar(value) != wanted) {
            if (started) gaps++;
            else leading++;
            continue;
        }
        if (next == needle_length) {
            // Keep subsequences below contiguous matches and reward shorter gaps.
            return 360 - (int)(gaps < 96 ? gaps : 96) - (int)(leading < 24 ? leading : 24);
        }
        started = 1;
        wanted = scalar(needle, needle_length, &next);
        if (wanted >= 128 && !unicode_ready) {
            pthread_once(&unicode_once, init_unicode_locale);
            unicode_ready = 1;
        }
        wanted = lower_scalar(wanted);
    }
    return 0;
}
