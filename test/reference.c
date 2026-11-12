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
    case ZSTD_btopt:
    case ZSTD_btultra:
    case ZSTD_btultra2: ZSTD_updateTree(ms, iend - HASH_READ_SIZE, iend); break;
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

/* ---- Long distance matching (zstd_ldm.c) ---- */

#include <stdlib.h>

/* A second copy of zstd_ldm.c, compiled here for its static functions (the
 * gear hash, maybeSplitSequence). Its exported functions are renamed so they
 * do not clash with the library's, which the helpers below call. */
#define ZSTD_ldm_fillHashTable reference_ldmCopy_fillHashTable
#define ZSTD_ldm_generateSequences reference_ldmCopy_generateSequences
#define ZSTD_ldm_blockCompress reference_ldmCopy_blockCompress
#define ZSTD_ldm_skipSequences reference_ldmCopy_skipSequences
#define ZSTD_ldm_skipRawSeqStoreBytes reference_ldmCopy_skipRawSeqStoreBytes
#define ZSTD_ldm_getTableSize reference_ldmCopy_getTableSize
#define ZSTD_ldm_getMaxNbSeq reference_ldmCopy_getMaxNbSeq
#define ZSTD_ldm_adjustParameters reference_ldmCopy_adjustParameters
#include "compress/zstd_ldm.c"
#undef ZSTD_ldm_fillHashTable
#undef ZSTD_ldm_generateSequences
#undef ZSTD_ldm_blockCompress
#undef ZSTD_ldm_skipSequences
#undef ZSTD_ldm_skipRawSeqStoreBytes
#undef ZSTD_ldm_getTableSize
#undef ZSTD_ldm_getMaxNbSeq
#undef ZSTD_ldm_adjustParameters

/* The library's own, as zstd_ldm.h declares them. */
void ZSTD_ldm_fillHashTable(ldmState_t* state, const BYTE* ip, const BYTE* iend,
                            ldmParams_t const* params);
size_t ZSTD_ldm_generateSequences(ldmState_t* ldms, RawSeqStore_t* sequences,
                                  ldmParams_t const* params, void const* src, size_t srcSize);
void ZSTD_ldm_skipSequences(RawSeqStore_t* rawSeqStore, size_t srcSize, U32 const minMatch);
void ZSTD_ldm_skipRawSeqStoreBytes(RawSeqStore_t* rawSeqStore, size_t nbBytes);
size_t ZSTD_ldm_getTableSize(ldmParams_t params);
size_t ZSTD_ldm_getMaxNbSeq(ldmParams_t params, size_t maxChunkSize);
void ZSTD_ldm_adjustParameters(ldmParams_t* params, ZSTD_compressionParameters const* cParams);

/* ldmParams_t as six numbers: enableLdm, hashLog, bucketSizeLog,
 * minMatchLength, hashRateLog, windowLog. */
static ldmParams_t reference_ldmParams(const unsigned p[6])
{
    ldmParams_t params;
    params.enableLdm = (ZSTD_ParamSwitch_e)p[0];
    params.hashLog = p[1];
    params.bucketSizeLog = p[2];
    params.minMatchLength = p[3];
    params.hashRateLog = p[4];
    params.windowLog = p[5];
    return params;
}

static void reference_ldmParamsOut(const ldmParams_t* params, unsigned p[6])
{
    p[0] = (unsigned)params->enableLdm;
    p[1] = params->hashLog;
    p[2] = params->bucketSizeLog;
    p[3] = params->minMatchLength;
    p[4] = params->hashRateLog;
    p[5] = params->windowLog;
}

void reference_ldm_adjustParameters(unsigned p[6], const ZSTD_compressionParameters* cParams)
{
    ldmParams_t params = reference_ldmParams(p);
    ZSTD_ldm_adjustParameters(&params, cParams);
    reference_ldmParamsOut(&params, p);
}

size_t reference_ldm_getTableSize(const unsigned p[6])
{
    return ZSTD_ldm_getTableSize(reference_ldmParams(p));
}

size_t reference_ldm_getMaxNbSeq(const unsigned p[6], size_t maxChunkSize)
{
    return ZSTD_ldm_getMaxNbSeq(reference_ldmParams(p), maxChunkSize);
}

/* The gear hash state as two numbers: rolling, stopMask. */
void reference_ldm_gearInit(U64 state[2], unsigned minMatchLength, unsigned hashRateLog)
{
    ldmRollingHashState_t s;
    unsigned p[6] = { 1, 0, 0, 0, 0, 0 };
    ldmParams_t params;
    p[3] = minMatchLength;
    p[4] = hashRateLog;
    params = reference_ldmParams(p);
    ZSTD_ldm_gear_init(&s, &params);
    state[0] = s.rolling;
    state[1] = s.stopMask;
}

void reference_ldm_gearReset(U64 state[2], const BYTE* data, size_t minMatchLength)
{
    ldmRollingHashState_t s;
    s.rolling = state[0];
    s.stopMask = state[1];
    ZSTD_ldm_gear_reset(&s, data, minMatchLength);
    state[0] = s.rolling;
}

size_t reference_ldm_gearFeed(U64 state[2], const BYTE* data, size_t size,
                              size_t splits[LDM_BATCH_SIZE], unsigned* numSplits)
{
    ldmRollingHashState_t s;
    size_t hashed;
    s.rolling = state[0];
    s.stopMask = state[1];
    hashed = ZSTD_ldm_gear_feed(&s, data, size, splits, numSplits);
    state[0] = s.rolling;
    return hashed;
}

/* A raw sequence store over `seqs`, an array of (offset, litLength,
 * matchLength) triples. */
static RawSeqStore_t reference_rawSeqStore(rawSeq* seqs, size_t size, size_t pos,
                                           size_t posInSequence)
{
    RawSeqStore_t store;
    store.seq = seqs;
    store.pos = pos;
    store.posInSequence = posInSequence;
    store.size = size;
    store.capacity = size;
    return store;
}

void reference_ldm_skipSequences(rawSeq* seqs, size_t size, size_t* pos, size_t srcSize,
                                 unsigned minMatch)
{
    RawSeqStore_t store = reference_rawSeqStore(seqs, size, *pos, 0);
    ZSTD_ldm_skipSequences(&store, srcSize, minMatch);
    *pos = store.pos;
}

void reference_ldm_skipRawSeqStoreBytes(rawSeq* seqs, size_t size, size_t* pos,
                                        size_t* posInSequence, size_t nbBytes)
{
    RawSeqStore_t store = reference_rawSeqStore(seqs, size, *pos, *posInSequence);
    ZSTD_ldm_skipRawSeqStoreBytes(&store, nbBytes);
    *pos = store.pos;
    *posInSequence = store.posInSequence;
}

void reference_ldm_maybeSplitSequence(rawSeq* seqs, size_t size, size_t* pos, unsigned remaining,
                                      unsigned minMatch, rawSeq* out)
{
    RawSeqStore_t store = reference_rawSeqStore(seqs, size, *pos, 0);
    *out = maybeSplitSequence(&store, remaining, minMatch);
    *pos = store.pos;
}

/* A long distance matcher's state as a fresh context sets it up: zeroed
 * tables, an empty window. */
typedef struct {
    ldmState_t state;
    ldmParams_t params;
    rawSeq* seqs;
} reference_Ldm;

reference_Ldm* reference_ldm_create(const unsigned p[6])
{
    reference_Ldm* ldm = (reference_Ldm*)calloc(1, sizeof(reference_Ldm));
    if (ldm == NULL) return NULL;
    ldm->params = reference_ldmParams(p);
    ldm->state.hashTable =
        (ldmEntry_t*)calloc((size_t)1 << ldm->params.hashLog, sizeof(ldmEntry_t));
    ldm->state.bucketOffsets =
        (BYTE*)calloc((size_t)1 << (ldm->params.hashLog - ldm->params.bucketSizeLog), 1);
    ZSTD_window_init(&ldm->state.window);
    ldm->state.loadedDictEnd = 0;
    return ldm;
}

void reference_ldm_free(reference_Ldm* ldm)
{
    if (ldm == NULL) return;
    free(ldm->state.hashTable);
    free(ldm->state.bucketOffsets);
    free(ldm->seqs);
    free(ldm);
}

const ldmEntry_t* reference_ldm_hashTable(const reference_Ldm* ldm)
{
    return ldm->state.hashTable;
}

const BYTE* reference_ldm_bucketOffsets(const reference_Ldm* ldm)
{
    return ldm->state.bucketOffsets;
}

/* The window and dictionary state: base, dictBase, nextSrc as addresses,
 * then dictLimit, lowLimit, nbOverflowCorrections, loadedDictEnd. */
void reference_ldm_window(const reference_Ldm* ldm, size_t out[7])
{
    const ZSTD_window_t* w = &ldm->state.window;
    out[0] = (size_t)w->base;
    out[1] = (size_t)w->dictBase;
    out[2] = (size_t)w->nextSrc;
    out[3] = w->dictLimit;
    out[4] = w->lowLimit;
    out[5] = w->nbOverflowCorrections;
    out[6] = ldm->state.loadedDictEnd;
}

/* Moves the window's indexes up by `shift`, as if that much input had come
 * before, to reach the overflow correction. */
void reference_ldm_shiftIndexes(reference_Ldm* ldm, unsigned shift)
{
    ZSTD_window_t* w = &ldm->state.window;
    w->base -= shift;
    w->dictBase -= shift;
    w->dictLimit += shift;
    w->lowLimit += shift;
}

/* ZSTD_window_update on the matcher's window; returns whether src followed
 * the previous input. */
unsigned reference_ldm_update(reference_Ldm* ldm, const void* src, size_t size)
{
    return ZSTD_window_update(&ldm->state.window, src, size, 0);
}

/* A dictionary's content loaded as ZSTD_loadDictionaryContent loads it. */
void reference_ldm_loadDictionary(reference_Ldm* ldm, const BYTE* dict, size_t size,
                                  int forceWindow)
{
    ldmState_t* ls = &ldm->state;
    ZSTD_window_update(&ls->window, dict, size, 0);
    ls->loadedDictEnd = forceWindow ? 0 : (U32)(dict + size - ls->window.base);
    ZSTD_ldm_fillHashTable(ls, dict, dict + size, &ldm->params);
}

void reference_ldm_fillHashTable(reference_Ldm* ldm, const BYTE* src, size_t size)
{
    ZSTD_ldm_fillHashTable(&ldm->state, src, src + size, &ldm->params);
}

/* ZSTD_ldm_generateSequences into a fresh store of `capacity` sequences,
 * kept until the next call; `*seqs` and `*nbSeqs` give them. */
size_t reference_ldm_generateSequences(reference_Ldm* ldm, const void* src, size_t size,
                                       size_t capacity, const rawSeq** seqs, size_t* nbSeqs)
{
    RawSeqStore_t store = kNullRawSeqStore;
    size_t code;
    free(ldm->seqs);
    ldm->seqs = (rawSeq*)malloc((capacity ? capacity : 1) * sizeof(rawSeq));
    if (ldm->seqs == NULL) return (size_t)-1;
    store.seq = ldm->seqs;
    store.capacity = capacity;
    code = ZSTD_ldm_generateSequences(&ldm->state, &store, &ldm->params, src, size);
    *seqs = ldm->seqs;
    *nbSeqs = store.size;
    return code;
}

size_t ZSTD_ldm_blockCompress(RawSeqStore_t* rawSeqStore, ZSTD_MatchState_t* ms,
                              SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
                              ZSTD_ParamSwitch_e useRowMatchFinder, void const* src,
                              size_t srcSize);

/* One block compressed with long distance matching, as ZSTD_buildSeqStore
 * does it: the match state set up as reference_blockTest sets it up without
 * a dictionary, `ldm`'s window updated with the block, its sequences
 * generated into a store of `rawCapacity`, then ZSTD_ldm_blockCompress with
 * the row match finder off. Returns the size of the last literals, or the
 * generator's error; `*nbRaw` is the number of long matches found. */
size_t reference_ldmBlockTest(ZSTD_compressionParameters const* cParams, reference_Ldm* ldm,
                              const void* src, size_t srcSize, size_t rawCapacity,
                              U32* hashTable, U32* chainTable,
                              SeqDef* seqs, size_t seqCapacity, BYTE* lits, size_t litCapacity,
                              U32* rep, size_t* nbSeq, size_t* nbLit,
                              U32* longLengthType, U32* longLengthPos, size_t* nbRaw)
{
    ZSTD_MatchState_t ms;
    SeqStore_t seqStore;
    RawSeqStore_t ldmSeqStore = kNullRawSeqStore;
    U32 const maxDist = 1U << cParams->windowLog;
    const BYTE* const ip = (const BYTE*)src;
    size_t lastLLSize;

    memset(&ms, 0, sizeof(ms));
    ZSTD_window_init(&ms.window);
    ZSTD_window_clear(&ms.window);
    ms.nextToUpdate = ms.window.dictLimit;
    ms.hashTable = hashTable;
    ms.chainTable = chainTable;
    ms.cParams = *cParams;

    ZSTD_window_update(&ldm->state.window, src, srcSize, 0);
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

    free(ldm->seqs);
    ldm->seqs = (rawSeq*)malloc((rawCapacity ? rawCapacity : 1) * sizeof(rawSeq));
    if (ldm->seqs == NULL) return (size_t)-1;
    ldmSeqStore.seq = ldm->seqs;
    ldmSeqStore.capacity = rawCapacity;
    {   size_t const code = ZSTD_ldm_generateSequences(&ldm->state, &ldmSeqStore, &ldm->params,
                                                       src, srcSize);
        if (ZSTD_isError(code)) return code;
    }
    *nbRaw = ldmSeqStore.size;
    lastLLSize = ZSTD_ldm_blockCompress(&ldmSeqStore, &ms, &seqStore, rep, ZSTD_ps_disable,
                                        src, srcSize);
    memcpy(seqStore.lit, ip + srcSize - lastLLSize, lastLLSize);
    seqStore.lit += lastLLSize;

    *nbSeq = (size_t)(seqStore.sequences - seqStore.sequencesStart);
    *nbLit = (size_t)(seqStore.lit - seqStore.litStart);
    *longLengthType = (U32)seqStore.longLengthType;
    *longLengthPos = seqStore.longLengthPos;
    return lastLLSize;
}

/* The optimal parser over several blocks, after the setup of a fresh
 * compression (reference_blockTest's), with the parser's own state: its
 * statistics tables, the 3-byte hash table, the previous block's entropy
 * tables it prices from, the literal compression mode, and long distance
 * match candidates. Each block takes the per-block steps of
 * ZSTD_compressContinue_internal, ZSTD_compress_frameChunk and
 * ZSTD_buildSeqStore. test/opt_test.zig makes the same steps on the port. */
#include "compress/zstd_ldm.h"

typedef struct {
    ZSTD_MatchState_t ms;
    ZSTD_MatchState_t dms;
    ZSTD_entropyCTables_t entropy;
    SeqStore_t seqStore;
    U32 rep[ZSTD_REP_NUM];
    ZSTD_ParamSwitch_e literalCompressionMode;
    RawSeqStore_t ldm;
    void* buffers[16];
} reference_OptTest;

/* What a block leaves, for the comparison. */
typedef struct {
    const SeqDef* seqs;
    size_t nbSeq;
    const BYTE* lits;
    size_t nbLit;
    U32 longLengthType;
    U32 longLengthPos;
    U32 rep[ZSTD_REP_NUM];
    U32 nextToUpdate;
    U32 dictLimit;
    U32 lowLimit;
    U32 loadedDictEnd;
    const BYTE* base;
    const U32* litFreq;
    const U32* litLengthFreq;
    const U32* matchLengthFreq;
    const U32* offCodeFreq;
    U32 litSum;
    U32 litLengthSum;
    U32 matchLengthSum;
    U32 offCodeSum;
    U32 litSumBasePrice;
    U32 litLengthSumBasePrice;
    U32 matchLengthSumBasePrice;
    U32 offCodeSumBasePrice;
    U32 priceType;
    U32 hashLog3;
    const U32* hashTable;
    const U32* chainTable;
    const U32* hashTable3;
    const U32* dictHashTable;
    const U32* dictChainTable;
    size_t ldmPos;
    size_t ldmPosInSequence;
} reference_OptResult;

static void* reference_optAlloc(reference_OptTest* t, size_t size)
{
    size_t i;
    for (i = 0; i < sizeof(t->buffers) / sizeof(t->buffers[0]); i++) {
        if (t->buffers[i] == NULL) {
            t->buffers[i] = calloc(1, size ? size : 1);
            return t->buffers[i];
        }
    }
    return NULL;
}

void reference_optTestFree(reference_OptTest* t)
{
    size_t i;
    if (t == NULL) return;
    for (i = 0; i < sizeof(t->buffers) / sizeof(t->buffers[0]); i++) free(t->buffers[i]);
    free(t);
}

/* dictKind as reference_blockTest's. hufCTable and the three FSE tables are
 * the previous block's entropy, with hufRepeat its Huffman repeat mode;
 * NULL for a fresh context's. ldm holds nbLdm candidates for the whole input. */
reference_OptTest* reference_optTestCreate(ZSTD_compressionParameters const* cParams,
                                           int dictKind, const void* dict, size_t dictSize,
                                           ZSTD_compressionParameters const* dictCParams,
                                           size_t blockSizeMax, unsigned literalCompressionMode,
                                           const size_t* hufCTable, unsigned hufRepeat,
                                           const U32* ofCTable, const U32* mlCTable,
                                           const U32* llCTable,
                                           const rawSeq* ldm, size_t nbLdm)
{
    reference_OptTest* const t = (reference_OptTest*)calloc(1, sizeof(*t));
    ZSTD_MatchState_t* const ms = &t->ms;
    if (t == NULL) return NULL;
    ZSTD_window_init(&ms->window);
    ZSTD_window_clear(&ms->window);
    ms->nextToUpdate = ms->window.dictLimit;
    ms->cParams = *cParams;
    ms->hashTable = (U32*)reference_optAlloc(t, sizeof(U32) << cParams->hashLog);
    ms->chainTable = (U32*)reference_optAlloc(t, sizeof(U32) << cParams->chainLog);
    ms->hashLog3 = cParams->minMatch == 3 ? MIN(17, cParams->windowLog) : 0;
    ms->hashTable3 = (U32*)reference_optAlloc(t, ms->hashLog3 ? sizeof(U32) << ms->hashLog3 : 0);
    ms->opt.litFreq = (unsigned*)reference_optAlloc(t, (1 << Litbits) * sizeof(unsigned));
    ms->opt.litLengthFreq = (unsigned*)reference_optAlloc(t, (MaxLL + 1) * sizeof(unsigned));
    ms->opt.matchLengthFreq = (unsigned*)reference_optAlloc(t, (MaxML + 1) * sizeof(unsigned));
    ms->opt.offCodeFreq = (unsigned*)reference_optAlloc(t, (MaxOff + 1) * sizeof(unsigned));
    ms->opt.matchTable = (ZSTD_match_t*)reference_optAlloc(t, ZSTD_OPT_SIZE * sizeof(ZSTD_match_t));
    ms->opt.priceTable =
        (ZSTD_optimal_t*)reference_optAlloc(t, ZSTD_OPT_SIZE * sizeof(ZSTD_optimal_t));
    t->seqStore.sequencesStart =
        (SeqDef*)reference_optAlloc(t, (blockSizeMax / 3 + 1) * sizeof(SeqDef));
    t->seqStore.litStart = (BYTE*)reference_optAlloc(t, blockSizeMax + WILDCOPY_OVERLENGTH);
    t->seqStore.maxNbSeq = blockSizeMax / 3 + 1;
    t->seqStore.maxNbLit = blockSizeMax;
    if (t->seqStore.litStart == NULL) { reference_optTestFree(t); return NULL; }
    t->rep[0] = 1; t->rep[1] = 4; t->rep[2] = 8;
    t->literalCompressionMode = (ZSTD_ParamSwitch_e)literalCompressionMode;
    t->entropy.huf.repeatMode = HUF_repeat_none;
    t->entropy.fse.offcode_repeatMode = FSE_repeat_none;
    t->entropy.fse.matchlength_repeatMode = FSE_repeat_none;
    t->entropy.fse.litlength_repeatMode = FSE_repeat_none;
    if (hufCTable != NULL) {
        memcpy(t->entropy.huf.CTable, hufCTable, sizeof(t->entropy.huf.CTable));
        t->entropy.huf.repeatMode = (HUF_repeat)hufRepeat;
        memcpy(t->entropy.fse.offcodeCTable, ofCTable, sizeof(t->entropy.fse.offcodeCTable));
        memcpy(t->entropy.fse.matchlengthCTable, mlCTable,
               sizeof(t->entropy.fse.matchlengthCTable));
        memcpy(t->entropy.fse.litlengthCTable, llCTable, sizeof(t->entropy.fse.litlengthCTable));
    }
    if (nbLdm != 0) {
        t->ldm.seq = (rawSeq*)reference_optAlloc(t, nbLdm * sizeof(rawSeq));
        if (t->ldm.seq == NULL) { reference_optTestFree(t); return NULL; }
        memcpy(t->ldm.seq, ldm, nbLdm * sizeof(rawSeq));
        t->ldm.size = nbLdm;
        t->ldm.capacity = nbLdm;
    }

    if (dictKind == 1) {
        reference_loadDictContent(ms, (const BYTE*)dict, dictSize, ZSTD_dtlm_fast,
                                  ZSTD_tfp_forCCtx);
    } else if (dictKind == 2) {
        ZSTD_MatchState_t* const dms = &t->dms;
        ZSTD_window_init(&dms->window);
        ZSTD_window_clear(&dms->window);
        dms->nextToUpdate = dms->window.dictLimit;
        dms->cParams = *dictCParams;
        dms->hashTable = (U32*)reference_optAlloc(t, sizeof(U32) << dictCParams->hashLog);
        dms->chainTable = (U32*)reference_optAlloc(t, sizeof(U32) << dictCParams->chainLog);
        if (dms->chainTable == NULL) { reference_optTestFree(t); return NULL; }
        reference_loadDictContent(dms, (const BYTE*)dict, dictSize, ZSTD_dtlm_full,
                                  ZSTD_tfp_forCDict);
        {   U32 const cdictEnd = (U32)(dms->window.nextSrc - dms->window.base);
            if (cdictEnd - dms->window.dictLimit != 0) {
                ms->dictMatchState = dms;
                if (ms->window.dictLimit < cdictEnd) {
                    ms->window.nextSrc = ms->window.base + cdictEnd;
                    ZSTD_window_clear(&ms->window);
                }
                ms->loadedDictEnd = ms->window.dictLimit;
        }   }
    }
    return t;
}

/* Compresses one block, the next part of the input. Returns the size of its
 * last literals. */
size_t reference_optTestBlock(reference_OptTest* t, const void* src, size_t srcSize)
{
    ZSTD_MatchState_t* const ms = &t->ms;
    U32 const maxDist = 1U << ms->cParams.windowLog;
    const BYTE* const ip = (const BYTE*)src;
    size_t lastLLSize;

    if (!ZSTD_window_update(&ms->window, src, srcSize, ms->forceNonContiguous)) {
        ms->forceNonContiguous = 0;
        ms->nextToUpdate = ms->window.dictLimit;
    }
    ZSTD_checkDictValidity(&ms->window, ip + srcSize, maxDist, &ms->loadedDictEnd,
                           &ms->dictMatchState);
    ZSTD_window_enforceMaxDist(&ms->window, ip, maxDist, &ms->loadedDictEnd, &ms->dictMatchState);
    if (ms->nextToUpdate < ms->window.lowLimit) ms->nextToUpdate = ms->window.lowLimit;

    ZSTD_resetSeqStore(&t->seqStore);
    ms->opt.symbolCosts = &t->entropy;
    ms->opt.literalCompressionMode = t->literalCompressionMode;
    {   U32 const curr = (U32)(ip - ms->window.base);
        if (curr > ms->nextToUpdate + 384)
            ms->nextToUpdate = curr - MIN(192, (U32)(curr - ms->nextToUpdate - 384));
    }

    {   ZSTD_BlockCompressor_f const compressor = ZSTD_selectBlockCompressor(
            ms->cParams.strategy, ZSTD_ps_disable, ZSTD_matchState_dictMode(ms));
        if (t->ldm.size != 0) {
            /* ZSTD_ldm_blockCompress's path for the optimal parser. */
            ms->ldmSeqStore = &t->ldm;
            lastLLSize = compressor(ms, &t->seqStore, t->rep, src, srcSize);
            ZSTD_ldm_skipRawSeqStoreBytes(&t->ldm, srcSize);
        } else {
            lastLLSize = compressor(ms, &t->seqStore, t->rep, src, srcSize);
        }
        ms->ldmSeqStore = NULL;
    }
    memcpy(t->seqStore.lit, ip + srcSize - lastLLSize, lastLLSize);
    t->seqStore.lit += lastLLSize;
    return lastLLSize;
}

void reference_optTestResult(const reference_OptTest* t, reference_OptResult* r)
{
    const ZSTD_MatchState_t* const ms = &t->ms;
    r->seqs = t->seqStore.sequencesStart;
    r->nbSeq = (size_t)(t->seqStore.sequences - t->seqStore.sequencesStart);
    r->lits = t->seqStore.litStart;
    r->nbLit = (size_t)(t->seqStore.lit - t->seqStore.litStart);
    r->longLengthType = (U32)t->seqStore.longLengthType;
    r->longLengthPos = t->seqStore.longLengthPos;
    memcpy(r->rep, t->rep, sizeof(r->rep));
    r->nextToUpdate = ms->nextToUpdate;
    r->dictLimit = ms->window.dictLimit;
    r->lowLimit = ms->window.lowLimit;
    r->loadedDictEnd = ms->loadedDictEnd;
    r->base = ms->window.base;
    r->litFreq = ms->opt.litFreq;
    r->litLengthFreq = ms->opt.litLengthFreq;
    r->matchLengthFreq = ms->opt.matchLengthFreq;
    r->offCodeFreq = ms->opt.offCodeFreq;
    r->litSum = ms->opt.litSum;
    r->litLengthSum = ms->opt.litLengthSum;
    r->matchLengthSum = ms->opt.matchLengthSum;
    r->offCodeSum = ms->opt.offCodeSum;
    r->litSumBasePrice = ms->opt.litSumBasePrice;
    r->litLengthSumBasePrice = ms->opt.litLengthSumBasePrice;
    r->matchLengthSumBasePrice = ms->opt.matchLengthSumBasePrice;
    r->offCodeSumBasePrice = ms->opt.offCodeSumBasePrice;
    r->priceType = (U32)ms->opt.priceType;
    r->hashLog3 = ms->hashLog3;
    r->hashTable = ms->hashTable;
    r->chainTable = ms->chainTable;
    r->hashTable3 = ms->hashTable3;
    r->dictHashTable = t->dms.hashTable;
    r->dictChainTable = t->dms.chainTable;
    r->ldmPos = t->ldm.pos;
    r->ldmPosInSequence = t->ldm.posInSequence;
}

/* Entropy tables as a dictionary's: a Huffman table built from the byte
 * counts of `sample`, up to its largest byte, and FSE tables from counts made from `seed`, every
 * symbol present. Returns 0, or 1 on an error. */
int reference_optEntropy(const void* sample, size_t sampleSize, unsigned seed,
                         size_t* hufCTable, U32* ofCTable, U32* mlCTable, U32* llCTable)
{
    unsigned count[256];
    unsigned maxSymbol = 255;
    U64 wksp[HUF_WORKSPACE_SIZE_U64];
    size_t i;
    memset(count, 0, sizeof(count));
    for (i = 0; i < sampleSize; i++) count[((const BYTE*)sample)[i]]++;
    while (maxSymbol > 0 && count[maxSymbol] == 0) maxSymbol--;
    /* Every symbol up to the largest present, so no code is longer than 11 bits
     * below it; the symbols above have no code. */
    for (i = 0; i <= maxSymbol; i++) count[i] += 1;
    {   size_t const maxBits = HUF_buildCTable_wksp((HUF_CElt*)hufCTable, count, maxSymbol, 11,
                                                    wksp, sizeof(wksp));
        if (HUF_isError(maxBits)) return 1;
    }
    {   struct { U32* table; unsigned maxSymbol; unsigned tableLog; } const fse[3] = {
            { ofCTable, MaxOff, OffFSELog },
            { mlCTable, MaxML, MLFSELog },
            { llCTable, MaxLL, LLFSELog } };
        int k;
        U32 state = seed * 2654435761U + 1;
        for (k = 0; k < 3; k++) {
            short norm[MaxSeq + 1];
            unsigned c[MaxSeq + 1];
            size_t total = 0;
            unsigned s;
            for (s = 0; s <= fse[k].maxSymbol; s++) {
                state = state * 1103515245U + 12345U;
                c[s] = 1 + ((state >> 16) % (s < 8 ? 400 : 40));
                total += c[s];
            }
            if (FSE_isError(FSE_normalizeCount(norm, fse[k].tableLog, c, total,
                                               fse[k].maxSymbol, 1)))
                return 1;
            if (FSE_isError(FSE_buildCTable_wksp(fse[k].table, norm, fse[k].maxSymbol,
                                                  fse[k].tableLog, wksp, sizeof(wksp))))
                return 1;
        }
    }
    return 0;
}
