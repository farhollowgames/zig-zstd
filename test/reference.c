/* Entry points into the original that the oracle tests and the benchmark
 * call, for things zstd.h does not export as plain functions. */
#define ZSTD_STATIC_LINKING_ONLY
#include "zstd.h"
#include "datagen.h"

void reference_genBuffer(void* buffer, size_t size, double matchProba, double litProba,
                         unsigned seed)
{
    RDG_genBuffer(buffer, size, matchProba, litProba, seed);
}

/* The bit stream writer and the FSE symbol encoder are inline functions in
 * bitstream.h and fse.h, so the tests reach them through these. */
#define FSE_STATIC_LINKING_ONLY
#include "bitstream.h"
#include "fse.h"

/* Writes `n` fields into a bit stream and closes it. Field i adds the low
 * widths[i] bits of values[i], with BIT_addBitsFast when ops[i] & 1, then
 * flushes with BIT_flushBits when ops[i] & 2 or BIT_flushBitsFast when
 * ops[i] & 4. Returns BIT_initCStream's error, or BIT_closeCStream's
 * result. */
size_t reference_bitWrite(void* dst, size_t dstCapacity, const size_t* values,
                          const unsigned* widths, const unsigned char* ops, size_t n)
{
    BIT_CStream_t bitC;
    size_t const initError = BIT_initCStream(&bitC, dst, dstCapacity);
    size_t i;
    if (ERR_isError(initError)) return initError;
    for (i = 0; i < n; i++) {
        if (ops[i] & 1) BIT_addBitsFast(&bitC, values[i], widths[i]);
        else BIT_addBits(&bitC, values[i], widths[i]);
        if (ops[i] & 2) BIT_flushBits(&bitC);
        if (ops[i] & 4) BIT_flushBitsFast(&bitC);
    }
    return BIT_closeCStream(&bitC);
}

/* Encodes symbols[0..n] backward with one FSE state, as the sequence
 * encoder does, each symbol followed by extraBits[i] raw bits of
 * extra[i]. The last symbol starts the state with FSE_initCState2 when
 * `init2`, else the state starts with FSE_initCState and encodes it too.
 * Returns 0 when the stream cannot start or does not fit. */
size_t reference_fseEncode(void* dst, size_t dstCapacity, const FSE_CTable* ct,
                           const unsigned char* symbols, const unsigned* extra,
                           const unsigned* extraBits, size_t n, int init2)
{
    BIT_CStream_t bitC;
    FSE_CState_t state;
    size_t i = n;
    if (ERR_isError(BIT_initCStream(&bitC, dst, dstCapacity))) return 0;
    if (init2) {
        i--;
        FSE_initCState2(&state, ct, symbols[i]);
        BIT_addBits(&bitC, extra[i], extraBits[i]);
        BIT_flushBits(&bitC);
    } else {
        FSE_initCState(&state, ct);
    }
    while (i-- > 0) {
        FSE_encodeSymbol(&bitC, &state, symbols[i]);
        BIT_addBits(&bitC, extra[i], extraBits[i]);
        BIT_flushBits(&bitC);
    }
    FSE_flushCState(&bitC, &state);
    return BIT_closeCStream(&bitC);
}

unsigned reference_fseBitCost(const FSE_CTable* ct, unsigned tableLog, unsigned symbol,
                              unsigned accuracyLog)
{
    FSE_CState_t state;
    FSE_initCState(&state, ct);
    return FSE_bitCost(state.symbolTT, tableLog, symbol, accuracyLog);
}

unsigned reference_fseGetMaxNbBits(const FSE_CTable* ct, unsigned symbol)
{
    FSE_CState_t state;
    FSE_initCState(&state, ct);
    return FSE_getMaxNbBits(state.symbolTT, symbol);
}
