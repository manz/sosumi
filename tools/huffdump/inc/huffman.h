#pragma once
#include "pv_audio_type_defs.h"
#include "hcbtables.h"
typedef struct { UInt32 usedBits; } BITS;
extern UInt32 g_window; /* 19-bit window, MSB first */
static inline UInt32 peek(Int n, BITS *b) { b->usedBits += n; return g_window >> (19 - n); }
static inline UInt32 getbits(Int n, BITS *b) { return peek(n, b); }
static inline UInt32 get9_n_lessbits(Int n, BITS *b) { return peek(n, b); }
static inline UInt32 get17_n_lessbits(Int n, BITS *b) { return peek(n, b); }
Int decode_huff_cw_tab1(BITS*); Int decode_huff_cw_tab2(BITS*); Int decode_huff_cw_tab3(BITS*);
Int decode_huff_cw_tab4(BITS*); Int decode_huff_cw_tab5(BITS*); Int decode_huff_cw_tab6(BITS*);
Int decode_huff_cw_tab7(BITS*); Int decode_huff_cw_tab8(BITS*); Int decode_huff_cw_tab9(BITS*);
Int decode_huff_cw_tab10(BITS*); Int decode_huff_cw_tab11(BITS*); Int decode_huff_scl(BITS*);
