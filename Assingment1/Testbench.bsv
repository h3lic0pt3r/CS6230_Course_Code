// Testbench for the parameterised floating point adder.
//
// Test vectors are produced by gen_vectors.py (an exact rational reference model, checked
// against NumPy and the public BASIC_TESTCASES) and loaded with $readmemh.  Each checker
// drives one adder instance with random back-pressure on BOTH sides:
//   phase 0 : operands every cycle, results collected every cycle (full throughput)
//   phase 1 : operands issued randomly, results collected every cycle
//   phase 2 : operands every cycle, results collected randomly (pipeline fills and stalls)
//   phase 3 : both sides random
// Results must come back in order and match the expected value and flags bit-for-bit.
//
// Build & run:
//   for each width: python3 gen_vectors.py E M 20000 SEED vec_eEmM.hex
//   mkdir -p build
//   bsc -u -sim -bdir build -simdir build -info-dir build -g mkTestbench Testbench.bsv
//   bsc -sim -bdir build -simdir build -e mkTestbench -o simTestbench
//   ./simTestbench

package Testbench;

import FloatingPointAdder :: *;
import DUT                :: *;
import RegFile            :: *;
import LFSR               :: *;
import Vector             :: *;

interface Ifc_checker;
   method Bool done;
   method Bit#(32) errors;
endinterface

module mkChecker#(String name, String vecFile, Integer nvec, Ifc_floating_point_adder#(e,m) dut) (Ifc_checker)
   provisos (Bits#(FP#(e,m), fpw), Add#(fpw, _a, 80));

   RegFile#(Bit#(20), Bit#(244)) vecs <- mkRegFileLoad(vecFile, 0, fromInteger(nvec - 1));
   Reg#(Bit#(20))  sendIdx  <- mkReg(0);
   Reg#(Bit#(20))  recvIdx  <- mkReg(0);
   Reg#(Bit#(32))  errCount <- mkReg(0);
   Reg#(Bit#(32))  cycle    <- mkReg(0);
   Reg#(Bool)      started  <- mkReg(False);
   Reg#(Bool)      finished <- mkReg(False);
   LFSR#(Bit#(16)) lfsr     <- mkLFSR_16;

   Bit#(2)  phase = cycle[10:9];         // 512-cycle phases, cycling through all four patterns
   Bit#(16) r     = lfsr.value;
   Bool goPut = case (phase) 0: True; 1: (r[3:0] < 7);  2: True;         default: (r[7:4] < 9);  endcase;
   Bool goGet = case (phase) 0: True; 1: True;          2: (r[11:8] < 5); default: (r[15:12] < 8); endcase;

   rule rl_init (!started);
      lfsr.seed(16'hACE1);
      started <= True;
   endrule

   rule rl_tick (started);
      cycle <= cycle + 1;
      lfsr.next;
   endrule

   rule rl_send (started && sendIdx < fromInteger(nvec) && goPut);
      Bit#(244) v = vecs.sub(sendIdx);
      FP#(e,m) op1 = unpack(truncate(v[243:164]));
      FP#(e,m) op2 = unpack(truncate(v[163:84]));
      dut.ma_put_operands(op1, op2);
      sendIdx <= sendIdx + 1;
   endrule

   rule rl_recv (started && recvIdx < fromInteger(nvec) && goGet);
      let res <- dut.mav_get_result;
      Bit#(244) v = vecs.sub(recvIdx);
      Bit#(80) expV = v[83:4];
      Bit#(4)  expF = v[3:0];
      Bit#(80) gotV = zeroExtend(pack(res.value));
      Bit#(4)  gotF = pack(res.flags);
      if (gotV != expV || gotF != expF) begin
         errCount <= errCount + 1;
         if (errCount < 10)
            $display("[%s] FAIL #%0d: op1=%h op2=%h  expected %h flags %b  got %h flags %b",
                     name, recvIdx, v[243:164], v[163:84], expV, expF, gotV, gotF);
      end
      recvIdx <= recvIdx + 1;
   endrule

   rule rl_finish (started && recvIdx == fromInteger(nvec) && !finished);
      $display("[%s] %0d vectors, %0d mismatches, %0d cycles", name, nvec, errCount, cycle);
      finished <= True;
   endrule

   method Bool done = finished;
   method Bit#(32) errors = errCount;
endmodule

(* synthesize *)
module mkTestbench (Empty);

   // the synthesis instance, exactly as built for the netlist
   Ifc_floating_point_adder#(8, 23) dut32 <- mkDUT;

   // the other graded widths, plus some deliberately odd ones
   Ifc_floating_point_adder#(4, 3)   dutFp8 <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(5, 10)  dut16  <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(8, 7)   dutBf  <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(11, 52) dut64  <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(2, 2)   dutA   <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(15, 63) dutB   <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(3, 17)  dutC   <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(6, 29)  dutD   <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(2, 63)  dutE   <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(15, 2)  dutF   <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(7, 26)  dutG   <- mkFloatingPointAdder;

   // exhaustively tested small formats (every operand pair)
   Ifc_floating_point_adder#(4, 3)   dutX1  <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(2, 2)   dutX2  <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(3, 4)   dutX3  <- mkFloatingPointAdder;
   Ifc_floating_point_adder#(2, 5)   dutX4  <- mkFloatingPointAdder;

   Vector#(16, Ifc_checker) chk;
   chk[0]  <- mkChecker("binary32/mkDUT", "vec_e8m23.hex", 20000, dut32);
   chk[1]  <- mkChecker("fp8 E4M3", "vec_e4m3.hex", 20000, dutFp8);
   chk[2]  <- mkChecker("binary16", "vec_e5m10.hex", 20000, dut16);
   chk[3]  <- mkChecker("bfloat16", "vec_e8m7.hex", 20000, dutBf);
   chk[4]  <- mkChecker("binary64", "vec_e11m52.hex", 20000, dut64);
   chk[5]  <- mkChecker("e2m2", "vec_e2m2.hex", 20000, dutA);
   chk[6]  <- mkChecker("e15m63", "vec_e15m63.hex", 20000, dutB);
   chk[7]  <- mkChecker("e3m17", "vec_e3m17.hex", 20000, dutC);
   chk[8]  <- mkChecker("e6m29", "vec_e6m29.hex", 20000, dutD);
   chk[9]  <- mkChecker("e2m63", "vec_e2m63.hex", 20000, dutE);
   chk[10] <- mkChecker("e15m2", "vec_e15m2.hex", 20000, dutF);
   chk[11] <- mkChecker("e7m26", "vec_e7m26.hex", 20000, dutG);
   chk[12] <- mkChecker("E4M3 exhaustive", "vec_x_e4m3.hex", 65536, dutX1);
   chk[13] <- mkChecker("e2m2 exhaustive", "vec_x_e2m2.hex", 1024,  dutX2);
   chk[14] <- mkChecker("e3m4 exhaustive", "vec_x_e3m4.hex", 65536, dutX3);
   chk[15] <- mkChecker("e2m5 exhaustive", "vec_x_e2m5.hex", 65536, dutX4);

   // timing probe on a separate binary32 instance: latency of a lone operation,
   // then the initiation interval over a burst of back-to-back operations
   Ifc_floating_point_adder#(8, 23) dutT <- mkDUT;
   Reg#(Bit#(32)) tCycle   <- mkReg(0);
   Reg#(Bit#(8))  tState   <- mkReg(0);
   Reg#(Bit#(32)) tMark    <- mkReg(0);
   Reg#(Bit#(8))  tSent    <- mkReg(0);
   Reg#(Bit#(8))  tGot     <- mkReg(0);
   rule rl_t_tick; tCycle <= tCycle + 1; endrule
   rule rl_t_put1 (tState == 0);
      dutT.ma_put_operands(unpack(32'h3FC00000), unpack(32'h40100000));
      tMark <= tCycle; tState <= 1;
   endrule
   rule rl_t_get1 (tState == 1);
      let r <- dutT.mav_get_result;
      $display("[timing] latency put->get = %0d cycles (1.5 + 2.25 = %h)", tCycle - tMark, pack(r.value));
      tState <= 2; tSent <= 0; tGot <= 0;
   endrule
   rule rl_t_burst_put (tState == 2 && tSent < 100);
      dutT.ma_put_operands(unpack(32'h3F800000), unpack(zeroExtend(tSent)));
      if (tSent == 0) tMark <= tCycle;
      tSent <= tSent + 1;
   endrule
   Reg#(Bit#(32)) tEnd <- mkReg(0);
   rule rl_t_burst_get (tState == 2 && tGot < 100);
      let r <- dutT.mav_get_result;
      if (tGot == 99) begin
         tEnd   <= tCycle;
         tState <= 3;
      end
      tGot <= tGot + 1;
   endrule
   rule rl_t_report (tState == 3);
      $display("[timing] 100 back-to-back ops: first put cycle %0d, last get cycle %0d => span %0d cycles (99 + latency => II = 1)",
               tMark, tEnd, tEnd - tMark);
      tState <= 4;
   endrule

   function Bool isDone(Ifc_checker c) = c.done;
   function Bit#(32) errs(Ifc_checker c) = c.errors;

   rule rl_all_done (all(isDone, chk));
      Bit#(32) total = fold(\+ , map(errs, chk));
      if (total == 0) $display("ALL CONFIGURATIONS PASSED");
      else            $display("TOTAL MISMATCHES: %0d", total);
      $finish(0);
   endrule

endmodule

endpackage
