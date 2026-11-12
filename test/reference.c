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

/* The original's block compressors on their own, for the block-level oracle
 * tests. The setup is the one a fresh compression of one block makes, and
 * test/core_test.zig's port side (BlockTest in compress_internal.zig) makes
 * the same steps: */
#include "compress/zstd_compress_internal.h"
#include "compress/zstd_fast.h"
#include "compress/zstd_double_fast.h"
#include "compress/zstd_lazy.h"
#include "compress/zstd_opt.h"

/* ZSTD_loadDictionaryContent's steps for the match state alone. */
static void reference_loadDictContent(ZSTD_MatchState_t* ms, const BYTE* dict, size_t dictSize,
                                      ZSTD_dictTableLoadMethod_e dtlm,
                                      ZSTD_tableFillPurpose_e tfp)
{
    const BYTE* const iend = dict + dictSize;
    ZSTD_window_update(&ms->window, dict, dictSize, 0);
    ms->nextToUpdate = (U32)(dict - ms->window.base);
    ms->loadedDictEnd = (U32)(iend - ms->window.base);
    if (dictSize <= HASH_READ_SIZE) return;
    switch (ms->cParams.strategy) {
    case ZSTD_fast: ZSTD_fillHashTable(ms, iend, dtlm, tfp); break;
    case ZSTD_dfast: ZSTD_fillDoubleHashTable(ms, iend, dtlm, tfp); break;
    default: assert(0);
    }
    ms->nextToUpdate = (U32)(iend - ms->window.base);
}

/* dictKind: 0 no dictionary, 1 an external dictionary loaded into the
 * context, 2 a dictionary attached as a dict match state. The tables and
 * buffers are the caller's, the tables zeroed. Returns the size of the last
 * literals. */
size_t reference_blockTest(ZSTD_compressionParameters const* cParams, int dictKind,
                           const void* dict, size_t dictSize,
                           ZSTD_compressionParameters const* dictCParams,
                           const void* src, size_t srcSize,
                           U32* hashTable, U32* chainTable,
                           U32* dictHashTable, U32* dictChainTable,
                           SeqDef* seqs, size_t seqCapacity, BYTE* lits, size_t litCapacity,
                           U32* rep, size_t* nbSeq, size_t* nbLit,
                           U32* longLengthType, U32* longLengthPos)
{
    ZSTD_MatchState_t ms;
    ZSTD_MatchState_t dms;
    SeqStore_t seqStore;
    U32 const maxDist = 1U << cParams->windowLog;
    const BYTE* const ip = (const BYTE*)src;
    size_t lastLLSize;

    memset(&ms, 0, sizeof(ms));
    memset(&dms, 0, sizeof(dms));
    ZSTD_window_init(&ms.window);
    ZSTD_window_clear(&ms.window);
    ms.nextToUpdate = ms.window.dictLimit;
    ms.hashTable = hashTable;
    ms.chainTable = chainTable;
    ms.cParams = *cParams;

    if (dictKind == 1) {
        reference_loadDictContent(&ms, (const BYTE*)dict, dictSize, ZSTD_dtlm_fast, ZSTD_tfp_forCCtx);
    } else if (dictKind == 2) {
        ZSTD_window_init(&dms.window);
        ZSTD_window_clear(&dms.window);
        dms.nextToUpdate = dms.window.dictLimit;
        dms.hashTable = dictHashTable;
        dms.chainTable = dictChainTable;
        dms.cParams = *dictCParams;
        reference_loadDictContent(&dms, (const BYTE*)dict, dictSize, ZSTD_dtlm_full, ZSTD_tfp_forCDict);
        {   U32 const cdictEnd = (U32)(dms.window.nextSrc - dms.window.base);
            if (cdictEnd - dms.window.dictLimit != 0) {
                ms.dictMatchState = &dms;
                if (ms.window.dictLimit < cdictEnd) {
                    ms.window.nextSrc = ms.window.base + cdictEnd;
                    ZSTD_window_clear(&ms.window);
                }
                ms.loadedDictEnd = ms.window.dictLimit;
        }   }
    }

    if (!ZSTD_window_update(&ms.window, src, srcSize, ms.forceNonContiguous)) {
        ms.forceNonContiguous = 0;
        ms.nextToUpdate = ms.window.dictLimit;
    }
    ZSTD_checkDictValidity(&ms.window, ip + srcSize, maxDist, &ms.loadedDictEnd, &ms.dictMatchState);
    ZSTD_window_enforceMaxDist(&ms.window, ip, maxDist, &ms.loadedDictEnd, &ms.dictMatchState);
    if (ms.nextToUpdate < ms.window.lowLimit) ms.nextToUpdate = ms.window.lowLimit;

    {   U32 const curr = (U32)(ip - ms.window.base);
        if (curr > ms.nextToUpdate + 384)
            ms.nextToUpdate = curr - MIN(192, (U32)(curr - ms.nextToUpdate - 384));
    }

    seqStore.sequencesStart = seqs;
    seqStore.sequences = seqs;
    seqStore.litStart = lits;
    seqStore.lit = lits;
    seqStore.maxNbSeq = seqCapacity;
    seqStore.maxNbLit = litCapacity;
    seqStore.longLengthType = ZSTD_llt_none;
    seqStore.longLengthPos = 0;
    rep[0] = 1; rep[1] = 4; rep[2] = 8;

    {   ZSTD_BlockCompressor_f const compressor = ZSTD_selectBlockCompressor(
            cParams->strategy, ZSTD_ps_disable, ZSTD_matchState_dictMode(&ms));
        lastLLSize = compressor(&ms, &seqStore, rep, src, srcSize);
    }
    memcpy(seqStore.lit, ip + srcSize - lastLLSize, lastLLSize);
    seqStore.lit += lastLLSize;

    *nbSeq = (size_t)(seqStore.sequences - seqStore.sequencesStart);
    *nbLit = (size_t)(seqStore.lit - seqStore.litStart);
    *longLengthType = (U32)seqStore.longLengthType;
    *longLengthPos = seqStore.longLengthPos;
    return lastLLSize;
}

/* The compression parameters a context applied in its last compression. */
void reference_appliedCParams(const ZSTD_CCtx* cctx, ZSTD_compressionParameters* cParams)
{
    *cParams = cctx->appliedParams.cParams;
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
