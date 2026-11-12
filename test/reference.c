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

/* The lazy match finders' block test: as reference_blockTest, with the row
 * matcher's tag tables and salt, the dedicated dictionary search, and a
 * dictionary that is an earlier block compressed in the same context. The
 * tables are the caller's, zeroed; test/lazy_test.zig makes the same steps on
 * the port's side. */
typedef struct {
    ZSTD_compressionParameters cParams;
    int useRow;
    U64 hashSalt;
    U32* hashTable;
    U32* chainTable;
    BYTE* tagTable;
    /* 0 none, 1 loaded into the context, 2 attached as a dict match state,
     * 3 compressed as an earlier block of the same context. */
    int dictKind;
    const void* dict;
    size_t dictSize;
    ZSTD_compressionParameters dictCParams;
    int dictUseRow;
    int dictDedicatedSearch;
    U32* dictHashTable;
    U32* dictChainTable;
    BYTE* dictTagTable;
} reference_LazySetup;

typedef struct {
    SeqDef* seqs;
    size_t seqCapacity;
    BYTE* lits;
    size_t litCapacity;
    U32 rep[3];
    size_t nbSeq;
    size_t nbLit;
    U32 longLengthType;
    U32 longLengthPos;
    U32 nextToUpdate;
    U32 hashSaltEntropy;
    U32 lazySkipping;
    U32 hashCache[ZSTD_ROW_HASH_CACHE_SIZE];
} reference_LazyResult;

static void reference_lazyResetMs(ZSTD_MatchState_t* ms, ZSTD_compressionParameters const* cParams,
                                  int useRow, U64 hashSalt, U32* hashTable, U32* chainTable,
                                  BYTE* tagTable)
{
    memset(ms, 0, sizeof(*ms));
    ZSTD_window_init(&ms->window);
    ZSTD_window_clear(&ms->window);
    ms->nextToUpdate = ms->window.dictLimit;
    ms->hashTable = hashTable;
    ms->chainTable = chainTable;
    ms->cParams = *cParams;
    if (useRow) {
        U32 const rowLog = BOUNDED(4, cParams->searchLog, 6);
        ms->tagTable = tagTable;
        ms->rowHashLog = cParams->hashLog - rowLog;
        ms->hashSalt = hashSalt;
    }
}

/* ZSTD_loadDictionaryContent's steps for the lazy strategies' match state. */
static void reference_loadLazyDictContent(ZSTD_MatchState_t* ms, int useRow,
                                          const BYTE* dict, size_t dictSize)
{
    const BYTE* ip = dict;
    const BYTE* const iend = dict + dictSize;
    ZSTD_window_update(&ms->window, dict, dictSize, 0);
    {   U32 const maxLog = MIN(MAX(ms->cParams.hashLog + 3, ms->cParams.chainLog + 1), 31);
        U32 const maxDictSize = 1U << maxLog;
        if (dictSize > maxDictSize) {
            ip = iend - maxDictSize;
            dictSize = maxDictSize;
        }
    }
    ms->nextToUpdate = (U32)(ip - ms->window.base);
    ms->loadedDictEnd = (U32)(iend - ms->window.base);
    if (dictSize <= HASH_READ_SIZE) return;
    switch (ms->cParams.strategy) {
    case ZSTD_greedy:
    case ZSTD_lazy:
    case ZSTD_lazy2:
        if (ms->dedicatedDictSearch) {
            ZSTD_dedicatedDictSearch_lazy_loadDictionary(ms, iend - HASH_READ_SIZE);
        } else if (useRow) {
            memset(ms->tagTable, 0, (size_t)1 << ms->cParams.hashLog);
            ZSTD_row_update(ms, iend - HASH_READ_SIZE);
        } else {
            ZSTD_insertAndFindFirstIndex(ms, iend - HASH_READ_SIZE);
        }
        break;
    case ZSTD_btlazy2:
        ZSTD_updateTree(ms, iend - HASH_READ_SIZE, iend);
        break;
    default: assert(0);
    }
    ms->nextToUpdate = (U32)(iend - ms->window.base);
}

/* One block as ZSTD_compress_frameChunk and ZSTD_buildSeqStore run it. */
static size_t reference_lazyBlock(ZSTD_MatchState_t* ms, int useRow, const BYTE* src,
                                  size_t srcSize, SeqStore_t* seqStore, U32* rep)
{
    U32 const maxDist = 1U << ms->cParams.windowLog;
    size_t lastLLSize;
    if (!ZSTD_window_update(&ms->window, src, srcSize, ms->forceNonContiguous)) {
        ms->forceNonContiguous = 0;
        ms->nextToUpdate = ms->window.dictLimit;
    }
    ZSTD_checkDictValidity(&ms->window, src + srcSize, maxDist, &ms->loadedDictEnd, &ms->dictMatchState);
    ZSTD_window_enforceMaxDist(&ms->window, src, maxDist, &ms->loadedDictEnd, &ms->dictMatchState);
    if (ms->nextToUpdate < ms->window.lowLimit) ms->nextToUpdate = ms->window.lowLimit;
    {   U32 const curr = (U32)(src - ms->window.base);
        if (curr > ms->nextToUpdate + 384)
            ms->nextToUpdate = curr - MIN(192, (U32)(curr - ms->nextToUpdate - 384));
    }
    {   ZSTD_BlockCompressor_f const compressor = ZSTD_selectBlockCompressor(
            ms->cParams.strategy, useRow ? ZSTD_ps_enable : ZSTD_ps_disable,
            ZSTD_matchState_dictMode(ms));
        lastLLSize = compressor(ms, seqStore, rep, src, srcSize);
    }
    memcpy(seqStore->lit, src + srcSize - lastLLSize, lastLLSize);
    seqStore->lit += lastLLSize;
    return lastLLSize;
}

size_t reference_lazyBlockTest(const reference_LazySetup* setup, const void* src, size_t srcSize,
                               reference_LazyResult* result)
{
    ZSTD_MatchState_t ms;
    ZSTD_MatchState_t dms;
    SeqStore_t seqStore;
    size_t lastLLSize;

    reference_lazyResetMs(&ms, &setup->cParams, setup->useRow, setup->hashSalt,
                          setup->hashTable, setup->chainTable, setup->tagTable);
    seqStore.sequencesStart = result->seqs;
    seqStore.sequences = result->seqs;
    seqStore.litStart = result->lits;
    seqStore.lit = result->lits;
    seqStore.maxNbSeq = result->seqCapacity;
    seqStore.maxNbLit = result->litCapacity;
    seqStore.longLengthType = ZSTD_llt_none;
    seqStore.longLengthPos = 0;
    result->rep[0] = 1; result->rep[1] = 4; result->rep[2] = 8;

    switch (setup->dictKind) {
    case 1:
        reference_loadLazyDictContent(&ms, setup->useRow, (const BYTE*)setup->dict, setup->dictSize);
        break;
    case 2:
        reference_lazyResetMs(&dms, &setup->dictCParams, setup->dictUseRow, 0,
                              setup->dictHashTable, setup->dictChainTable, setup->dictTagTable);
        dms.dedicatedDictSearch = setup->dictDedicatedSearch;
        reference_loadLazyDictContent(&dms, setup->dictUseRow, (const BYTE*)setup->dict,
                                      setup->dictSize);
        {   U32 const cdictEnd = (U32)(dms.window.nextSrc - dms.window.base);
            if (cdictEnd - dms.window.dictLimit != 0) {
                ms.dictMatchState = &dms;
                if (ms.window.dictLimit < cdictEnd) {
                    ms.window.nextSrc = ms.window.base + cdictEnd;
                    ZSTD_window_clear(&ms.window);
                }
                ms.loadedDictEnd = ms.window.dictLimit;
        }   }
        break;
    case 3:
        /* The earlier block's sequences are not kept. */
        (void)reference_lazyBlock(&ms, setup->useRow, (const BYTE*)setup->dict, setup->dictSize,
                                  &seqStore, result->rep);
        seqStore.sequences = seqStore.sequencesStart;
        seqStore.lit = seqStore.litStart;
        seqStore.longLengthType = ZSTD_llt_none;
        seqStore.longLengthPos = 0;
        break;
    default: break;
    }

    lastLLSize = reference_lazyBlock(&ms, setup->useRow, (const BYTE*)src, srcSize, &seqStore,
                                     result->rep);

    result->nbSeq = (size_t)(seqStore.sequences - seqStore.sequencesStart);
    result->nbLit = (size_t)(seqStore.lit - seqStore.litStart);
    result->longLengthType = (U32)seqStore.longLengthType;
    result->longLengthPos = seqStore.longLengthPos;
    result->nextToUpdate = ms.nextToUpdate;
    result->hashSaltEntropy = ms.hashSaltEntropy;
    result->lazySkipping = ms.lazySkipping;
    memcpy(result->hashCache, ms.hashCache, sizeof(ms.hashCache));
    return lastLLSize;
}
