// Recovers (index, length, codeword) for every AAC codebook by running PV's decoders on
// every 19-bit input. Output: book index length codeword(hex), one line per symbol.
#include <stdio.h>
#include "huffman.h"
UInt32 g_window;
typedef Int (*Dec)(BITS*);
int main() {
  Dec decs[12] = {decode_huff_scl, decode_huff_cw_tab1, decode_huff_cw_tab2, decode_huff_cw_tab3,
    decode_huff_cw_tab4, decode_huff_cw_tab5, decode_huff_cw_tab6, decode_huff_cw_tab7,
    decode_huff_cw_tab8, decode_huff_cw_tab9, decode_huff_cw_tab10, decode_huff_cw_tab11};
  for (int book = 0; book < 12; book++) {
    static int len_of[512]; static UInt32 code_of[512];
    for (int i = 0; i < 512; i++) len_of[i] = 0;
    double kraft = 0; int bad = 0;
    for (UInt32 w = 0; w < (1u << 19); w++) {
      g_window = w; BITS b = {0};
      Int idx = decs[book](&b);
      int len = (int)b.usedBits; UInt32 code = w >> (19 - len);
      if (idx < 0 || idx >= 512 || len < 1 || len > 19) { bad++; continue; }
      if (len_of[idx] == 0) { len_of[idx] = len; code_of[idx] = code; kraft += 1.0 / (1u << len); }
      else if (len_of[idx] != len || code_of[idx] != code) bad++;
    }
    int n = 0; for (int i = 0; i < 512; i++) if (len_of[i]) { printf("%d %d %d %x\n", book, i, len_of[i], code_of[i]); n++; }
    fprintf(stderr, "book %2d: %3d symbols, kraft %.9f, inconsistencies %d\n", book, n, kraft, bad);
  }
}
