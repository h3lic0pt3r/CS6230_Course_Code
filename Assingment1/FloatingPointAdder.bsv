// Assignment 1: Floating Point Adder
//
// In this assignment, you will develop a fully parameterizable 
// floating point adder in BSV. The goal of the assignment is to 
// get you started on development with bluespec and appreciate the 
// paradigms that make the language powerful and unique.
//
// The skeleton of the requirement is specified in this file. You 
// are expected to ONLY implement the logic inside the mkFloatingPointAdder
// module and not change the interface. You are free to implement the internal
// logic in any way you wish, as long as the output methods fire only when the output
// itself is ready. You are free to implement any auxiliary modules and functions 
// that can aid in development. DO NOT CHANGE ANY EXISTING CODE.

// Remember that the goal of the assignemnt is to familiarise yourself with the language.
// Further assignments and project would build on other concepts and let you develop more
// complex designs.

package FloatingPointAdder;

import FIFOF :: *;
import List  :: *;

typedef struct {
   Bool     sign;
   Bit#(e)  expo;
   Bit#(m)  mant;
} FP#(numeric type e, numeric type m)
deriving (Bits, Eq, FShow);

typedef struct {
   Bool invalid;
   Bool overflow;
   Bool underflow;
   Bool inexact;
} FPException deriving (Bits, Eq, FShow);

typedef struct {
   FP#(e,m)     value;
   FPException  flags;
} FPResult#(numeric type e, numeric type m)
deriving (Bits, Eq, FShow);

interface Ifc_floating_point_adder#(numeric type e, numeric type m);
   method Action ma_put_operands (FP#(e,m) op1, FP#(e,m) op2);
   method ActionValue#(FPResult#(e,m)) mav_get_result ();
endinterface

// ==========================================================================================
// Micro-architecture (3-stage pipeline, initiation interval 1, latency 4 cycles):
//
//   ff_input --> [S1: classify, compare/swap, exponent diff, align + sticky] --> ff_s1
//            --> [S2: significand add/sub, leading-zero count, shift select ] --> ff_s2
//            --> [S3: normalise, round (RNE), exponent adjust, flags, pack  ] --> ff_output
//
// Inter-stage FIFOs are single-element "loopy" FIFOs (mkLFIFOF): an element can be
// dequeued and a new one enqueued in the same cycle, so the pipeline sustains one
// operation per cycle with one register per stage and stalls cleanly under back-pressure.
//
// Bit layout of the working significand (width m+4):
//     [m+3]     hidden bit
//     [m+2:3]   m trailing significand bits
//     [2]       G (guard)      [1] R (round)      [0] S (sticky)
// The sum (width m+5) carries one extra bit on top for the carry-out.
// ==========================================================================================

// Leading-zero counter built as an explicit balanced tree (log depth).
// Returns the number of leading zeros; returns valueOf(n) for an all-zero input.
// The result width cw must satisfy 2^cw > n (checked at elaboration).
function Bit#(cw) fn_lzc (Bit#(n) x);
   Integer nn = valueOf(n);
   if (2 ** valueOf(cw) <= nn)
      return error("fn_lzc: result width too narrow");
   else begin
      // pad to a power of two; the padding (below the LSB) is treated as ones, so that
      // an all-zero input yields the count nn
      Integer p = 1;
      while (p < nn) p = p * 2;
      List#(Tuple2#(Bool, Bit#(cw))) lvl = Nil;          // MSB block first
      for (Integer i = p - 1; i >= 0; i = i - 1) begin
         Bool z = (i < nn) ? (x[nn-1-i] == 0) : False;
         lvl = cons(tuple2(z, 0), lvl);
      end
      Integer j = 0;
      while (length(lvl) > 1) begin
         List#(Tuple2#(Bool, Bit#(cw))) nxt = Nil;
         List#(Tuple2#(Bool, Bit#(cw))) rest = lvl;
         while (length(rest) > 1) begin
            match {.zh, .ch} = head(rest);
            match {.zl, .cl} = head(tail(rest));
            Bit#(cw) c = zh ? (cl | fromInteger(2 ** j)) : ch;
            nxt  = cons(tuple2(zh && zl, c), nxt);
            rest = tail(tail(rest));
         end
         lvl = reverse(nxt);
         j = j + 1;
      end
      match {.zall, .cnt} = head(lvl);
      return zall ? fromInteger(nn) : cnt;
   end
endfunction

// Pipeline register contents after stage 1
typedef struct {
   Bool             sign;      // sign of the larger-magnitude operand (= sign of a non-zero result)
   Bool             zsign;     // sign to use if the datapath result is exactly zero
   Bit#(e)          expB;      // effective (unbiased-encoding) exponent of the larger operand, >= 1
   Bit#(TAdd#(m,1)) sigB;      // significand of the larger operand with hidden bit
   Bit#(TAdd#(m,4)) sigS;      // aligned significand of the smaller operand, G/R/S included
   Bool             sub;       // effective subtraction
   Bool             nan;       // result is the canonical quiet NaN
   Bool             inf;       // result is an infinity
   Bool             infSign;   // sign of that infinity
   Bool             invalid;   // invalid-operation flag
} Stage1#(numeric type e, numeric type m) deriving (Bits, FShow);

// Pipeline register contents after stage 2
typedef struct {
   Bool                    sign;
   Bool                    zsign;
   Bit#(e)                 expB;
   Bit#(TAdd#(m,5))        sum;       // carry, hidden, m bits, G, R, S
   Bit#(TLog#(TAdd#(m,6))) ks;        // left-normalisation shift amount (already exponent-limited)
   Bool                    nan;
   Bool                    inf;
   Bool                    infSign;
   Bool                    invalid;
} Stage2#(numeric type e, numeric type m) deriving (Bits, FShow);

module mkFloatingPointAdder (Ifc_floating_point_adder#(e, m))
   provisos (
      Add#(2, _e0, e),
      Add#(2, _m0, m),
      // width aliases
      NumAlias#(TAdd#(m,4), sw),               // working significand width
      NumAlias#(TAdd#(m,5), aw),               // sum width (with carry)
      NumAlias#(TLog#(TAdd#(m,6)), lw),        // shift-amount width, holds 0 .. m+5
      NumAlias#(TAdd#(e,7), dw),               // exponent-difference compare width, holds m+3
      NumAlias#(TAdd#(e,lw), mw),              // width for exponent arithmetic and the min(lzc, expB) compare
      // relations the compiler cannot derive on its own (all hold for 2<=e<=15, 2<=m<=63)
      Add#(lw, _lw0, dw),
      Add#(lw, _lw1, mw),
      Add#(e,  _e1,  mw),
      Add#(1,  _one, mw)
   );

   FIFOF#(Tuple2#(FP#(e,m), FP#(e,m))) ff_input  <- mkFIFOF;
   FIFOF#(FPResult#(e,m))              ff_output <- mkFIFOF;

   // =======================================================================================
   // Implement any internal logic here
   // (bsc requires methods to be the last items of a module body, so the datapath sits
   //  between the FIFO declarations and the two interface methods)
   // =======================================================================================

   Integer mi = valueOf(m);
   Integer ei = valueOf(e);

   FIFOF#(Stage1#(e,m)) ff_s1 <- mkLFIFOF;
   FIFOF#(Stage2#(e,m)) ff_s2 <- mkLFIFOF;

   // ---------------------------------------------------------------------------------------
   // Stage 1: classify, order the operands by magnitude, align the smaller significand
   // ---------------------------------------------------------------------------------------
   rule rl_stage1;
      match {.op1, .op2} = ff_input.first;
      ff_input.deq;

      // classification
      Bool expOnes1 = (op1.expo == '1);   Bool expOnes2 = (op2.expo == '1);
      Bool expZero1 = (op1.expo == 0);    Bool expZero2 = (op2.expo == 0);
      Bool manZero1 = (op1.mant == 0);    Bool manZero2 = (op2.mant == 0);
      Bool isInf1   = expOnes1 && manZero1;
      Bool isInf2   = expOnes2 && manZero2;
      Bool isNaN1   = expOnes1 && !manZero1;
      Bool isNaN2   = expOnes2 && !manZero2;
      Bool isSNaN1  = isNaN1 && (msb(op1.mant) == 0);
      Bool isSNaN2  = isNaN2 && (msb(op2.mant) == 0);

      Bool infClash = isInf1 && isInf2 && (op1.sign != op2.sign);
      Bool nanR     = isNaN1 || isNaN2 || infClash;
      Bool invalidR = isSNaN1 || isSNaN2 || infClash;
      Bool infR     = !nanR && (isInf1 || isInf2);
      Bool infSignR = isInf1 ? op1.sign : op2.sign;

      // magnitude ordering: for two magnitudes the packed {expo,mant} field orders correctly
      Bit#(TAdd#(e,m)) mag1 = {op1.expo, op1.mant};
      Bit#(TAdd#(e,m)) mag2 = {op2.expo, op2.mant};
      Bool swap = (mag1 < mag2);

      // effective exponents (subnormals are scaled as exponent 1) and both differences,
      // computed in parallel with the comparison
      Bit#(e) ex1 = expZero1 ? 1 : op1.expo;
      Bit#(e) ex2 = expZero2 ? 1 : op2.expo;
      Bit#(e) d12 = ex1 - ex2;
      Bit#(e) d21 = ex2 - ex1;

      FP#(e,m) big   = swap ? op2 : op1;
      FP#(e,m) opS = swap ? op1 : op2;
      Bit#(e)  expB  = swap ? ex2 : ex1;
      Bit#(e)  d     = swap ? d21 : d12;
      Bool     hidB  = swap ? !expZero2 : !expZero1;
      Bool     hidS  = swap ? !expZero1 : !expZero2;

      // alignment shift, saturated so that a far-away operand collapses into the sticky bit
      Bit#(dw) dx    = zeroExtend(d);
      Bool     far   = (dx > fromInteger(mi + 3));
      Bit#(lw) dc    = far ? fromInteger(mi + 3) : truncate(dx);

      Bit#(sw) sigSx = {pack(hidS), opS.mant, 3'b000};
      Bit#(sw) mask  = (1 << dc) - 1;                    // bits that fall below S
      Bool     stky  = ((sigSx & mask) != 0);
      Bit#(sw) sigSa = (sigSx >> dc) | zeroExtend(pack(stky));

      Bool sub = (op1.sign != op2.sign);

      ff_s1.enq(Stage1 { sign:    big.sign,
                         zsign:   big.sign && !sub,       // +0 for x + (-x); sign kept for (-0)+(-0)
                         expB:    expB,
                         sigB:    {pack(hidB), big.mant},
                         sigS:    sigSa,
                         sub:     sub,
                         nan:     nanR,
                         inf:     infR,
                         infSign: infSignR,
                         invalid: invalidR });
   endrule

   // ---------------------------------------------------------------------------------------
   // Stage 2: significand add / subtract, leading-zero count, normalisation shift amount
   // ---------------------------------------------------------------------------------------
   rule rl_stage2;
      let s = ff_s1.first;
      ff_s1.deq;

      Bit#(aw) a   = {1'b0, s.sigB, 3'b000};
      Bit#(aw) b   = {1'b0, s.sigS};
      Bit#(aw) bb  = s.sub ? ~b : b;
      Bit#(aw) sum = a + bb + zeroExtend(pack(s.sub));    // big - opS is never negative

      // Left shift needed to bring the leading one to the top of the sum:
      //   0 if there is a carry, 1 if the hidden bit is set, 1+k after k bits of cancellation.
      // It is capped at expB so that the exponent never drops below the subnormal exponent.
      Bit#(lw) lz  = fn_lzc(sum);
      Bit#(mw) lzx = zeroExtend(lz);
      Bit#(mw) ebx = zeroExtend(s.expB);
      Bit#(lw) ks  = (lzx < ebx) ? lz : truncate(ebx);

      ff_s2.enq(Stage2 { sign: s.sign, zsign: s.zsign, expB: s.expB,
                         sum: sum, ks: ks,
                         nan: s.nan, inf: s.inf, infSign: s.infSign, invalid: s.invalid });
   endrule

   // ---------------------------------------------------------------------------------------
   // Stage 3: normalise, round to nearest even, detect overflow / underflow, pack
   // ---------------------------------------------------------------------------------------
   rule rl_stage3;
      let s = ff_s2.first;
      ff_s2.deq;

      Bit#(aw)         sh   = s.sum << s.ks;
      Bit#(TAdd#(m,1)) sig  = truncateLSB(sh);            // hidden bit + m bits
      Bit#(4)          low  = truncate(sh);               // round bit and three sticky bits
      Bool             rnd  = (low[3] == 1);
      Bool             stk  = (low[2:0] != 0);
      Bool             lsb  = (sig[0] == 1);
      Bool             inc  = rnd && (stk || lsb);        // round to nearest, ties to even

      Bit#(TAdd#(m,2)) sigR = zeroExtend(sig) + zeroExtend(pack(inc));
      Bool             rc   = (msb(sigR) == 1);           // rounding carried out: 1.11..1 -> 10.00..0
      Bit#(m)          mantO = truncate(sigR);            // low m bits are all zero when rc
      Bool             hidO  = rc || (sigR[mi] == 1);     // hidden bit after rounding

      // exponent of the normalised result: expB + 1 - ks (+1 on rounding carry)
      Bit#(mw) expR = zeroExtend(s.expB) + 1 - zeroExtend(s.ks) + zeroExtend(pack(rc));
      Bool     ovf  = (expR >= fromInteger(2 ** ei - 1));
      Bit#(e)  expO = hidO ? truncate(expR) : 0;         // a result without hidden bit is subnormal
      Bool     isZero  = (s.sum == 0);
      Bool     inexact = rnd || stk;
      Bool     tiny    = !hidO;                           // tininess detected after rounding

      Bit#(m) qnanMant = 1 << (mi - 1);

      FP#(e,m)    v;
      FPException f = FPException { invalid: False, overflow: False, underflow: False, inexact: False };
      if (s.nan) begin
         v = FP { sign: False, expo: '1, mant: qnanMant };
         f.invalid = s.invalid;
      end
      else if (s.inf) begin
         v = FP { sign: s.infSign, expo: '1, mant: 0 };
      end
      else if (ovf) begin
         v = FP { sign: s.sign, expo: '1, mant: 0 };
         f.overflow = True;
         f.inexact  = True;
      end
      else if (isZero) begin
         v = FP { sign: s.zsign, expo: 0, mant: 0 };
      end
      else begin
         v = FP { sign: s.sign, expo: expO, mant: mantO };
         f.inexact   = inexact;
         f.underflow = inexact && tiny;
      end

      ff_output.enq(FPResult { value: v, flags: f });
   endrule

   method Action ma_put_operands (FP#(e,m) op1, FP#(e,m) op2);
      ff_input.enq(tuple2(op1, op2));
   endmethod

   method ActionValue#(FPResult#(e,m)) mav_get_result ();
      ff_output.deq;
      return ff_output.first;
   endmethod

endmodule : mkFloatingPointAdder

// ==========================================================================================
// Your module will be instantiated in the testbench as shown below, for different values
// of e and m. Here it is instantiated with 4 exponent bits and 3 mantissa bits.
//
//    Ifc_floating_point_adder#(4, 3) dut <- mkFloatingPointAdder;
//
// ==========================================================================================

endpackage : FloatingPointAdder
