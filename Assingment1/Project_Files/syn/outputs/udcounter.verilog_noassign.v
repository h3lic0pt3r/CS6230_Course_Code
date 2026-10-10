/////////////////////////////////////////////////////////////
// Created by: Synopsys DC Ultra(TM) in wire load mode
// Version   : U-2022.12
// Date      : Wed Sep  9 23:32:19 2026
/////////////////////////////////////////////////////////////


module udcounter ( Clk, reset, UpOrDown, Count );
  output [3:0] Count;
  input Clk, reset, UpOrDown;
  wire   N20, N22, N23, n1, n10, n11, n12, n13, n14, n15, n16, n17, n18, n19,
         n20, n21, n22;

  SAEDRVT14_FDPRBQ_V2LP_1 Count_reg_3_ ( .D(N23), .CK(Clk), .RD(n1), .Q(
        Count[3]) );
  SAEDRVT14_FDPRBQ_V2_1 Count_reg_2_ ( .D(N22), .CK(Clk), .RD(n1), .Q(Count[2]) );
  SAEDRVT14_FDPRBQ_V2LP_2 Count_reg_1_ ( .D(n22), .CK(Clk), .RD(n1), .Q(
        Count[1]) );
  SAEDRVT14_FDPRBQ_V2_2 Count_reg_0_ ( .D(N20), .CK(Clk), .RD(n1), .Q(Count[0]) );
  SAEDRVT14_MUXI2_1 U15 ( .D0(n22), .D1(n15), .S(n14), .X(N22) );
  SAEDRVT14_ND2_CDC_4 U16 ( .A1(n12), .A2(n11), .X(n18) );
  SAEDRVT14_ND2_0P5 U17 ( .A1(UpOrDown), .A2(Count[1]), .X(n12) );
  SAEDRVT14_BUF_S_1 U18 ( .A(n19), .X(n22) );
  SAEDRVT14_ND2_1P5 U19 ( .A1(n21), .A2(Count[3]), .X(n20) );
  SAEDRVT14_INV_6 U20 ( .A(n15), .X(n19) );
  SAEDRVT14_OAI21_2 U21 ( .A1(UpOrDown), .A2(Count[1]), .B(Count[0]), .X(n11)
         );
  SAEDRVT14_INV_S_1 U22 ( .A(n18), .X(n13) );
  SAEDRVT14_EN2_1P5 U23 ( .A1(Count[1]), .A2(Count[0]), .X(n10) );
  SAEDRVT14_INV_S_1 U24 ( .A(Count[0]), .X(N20) );
  SAEDRVT14_OAI22_1P5 U25 ( .A1(Count[2]), .A2(n18), .B1(n16), .B2(n19), .X(
        n17) );
  SAEDRVT14_INV_S_1 U26 ( .A(Count[2]), .X(n16) );
  SAEDRVT14_EN2_4 U27 ( .A1(UpOrDown), .A2(n10), .X(n15) );
  SAEDRVT14_OAI22_1 U28 ( .A1(n18), .A2(Count[2]), .B1(n13), .B2(n16), .X(n14)
         );
  SAEDRVT14_INV_S_0P5 U29 ( .A(reset), .X(n1) );
  SAEDRVT14_OAI21_V1_4 U30 ( .A1(n19), .A2(n18), .B(n17), .X(n21) );
  SAEDRVT14_OAI21_2 U31 ( .A1(Count[3]), .A2(n21), .B(n20), .X(N23) );
endmodule

