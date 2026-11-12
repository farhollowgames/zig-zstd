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
