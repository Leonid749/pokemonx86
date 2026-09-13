using System;

namespace Recomp.Sm83
{
    // Decodes SM83 machine code. The regular regions of the opcode map
    // (0x40-0xBF and the whole CB page) are decoded arithmetically; everything
    // else is an explicit case so it can be eyeballed against the opcode map.
    public static class Decoder
    {
        public interface IMem { byte Read(int addr); }

        public sealed class ArrayMem : IMem
        {
            readonly byte[] _d;
            readonly int _base;
            public ArrayMem(byte[] d, int baseAddr = 0) { _d = d; _base = baseAddr; }
            public byte Read(int addr)
            {
                int i = addr - _base;
                return (i >= 0 && i < _d.Length) ? _d[i] : (byte)0xFF;
            }
        }

        static Instr Mk(Mn op, Operand a, Operand b, int len, int cyc, int cycNot = 0)
        {
            return new Instr { Op = op, A = a, B = b, Length = len, Cycles = cyc, CyclesNotTaken = cycNot };
        }

        static Operand Imm8(int v) { return new Operand(OpKind.Imm8, v & 0xFF); }
        static Operand Imm16(int v) { return new Operand(OpKind.Imm16, v & 0xFFFF); }
        static Operand SImm8(int v) { return new Operand(OpKind.SImm8, (sbyte)v); }
        static Operand Cc(Cond c) { return new Operand(OpKind.Cc, (int)c); }

        public static Instr Decode(IMem mem, int addr)
        {
            byte op = mem.Read(addr);
            int n8 = mem.Read(addr + 1);
            int n16 = mem.Read(addr + 1) | (mem.Read(addr + 2) << 8);

            Instr r = DecodeInner(mem, addr, op, n8, n16);
            r.Addr = addr & 0xFFFF;
            r.Bytes = new byte[r.Length];
            for (int i = 0; i < r.Length; i++) r.Bytes[i] = mem.Read(addr + i);
            return r;
        }

        static Instr DecodeInner(IMem mem, int addr, byte op, int n8, int n16)
        {
            // --- 0x40-0x7F: LD r, r' (0x76 is HALT) ---
            if (op >= 0x40 && op <= 0x7F)
            {
                if (op == 0x76) return Mk(Mn.Halt, Operand.None, Operand.None, 1, 4);
                var dst = (R8)((op >> 3) & 7);
                var src = (R8)(op & 7);
                int cyc = (dst == R8.MemHL || src == R8.MemHL) ? 8 : 4;
                return Mk(Mn.Ld, Operand.Reg(dst), Operand.Reg(src), 1, cyc);
            }

            // --- 0x80-0xBF: ALU A, r ---
            if (op >= 0x80 && op <= 0xBF)
            {
                var src = (R8)(op & 7);
                Mn m = AluMn((op >> 3) & 7);
                int cyc = (src == R8.MemHL) ? 8 : 4;
                return Mk(m, Operand.Reg(R8.A), Operand.Reg(src), 1, cyc);
            }

            switch (op)
            {
                case 0x00: return Mk(Mn.Nop, Operand.None, Operand.None, 1, 4);
                case 0x01: return Mk(Mn.Ld, Operand.Reg(R16.BC), Imm16(n16), 3, 12);
                case 0x02: return Mk(Mn.Ld, new Operand(OpKind.MemReg16, (int)R16.BC), Operand.Reg(R8.A), 1, 8);
                case 0x03: return Mk(Mn.Inc, Operand.Reg(R16.BC), Operand.None, 1, 8);
                case 0x07: return Mk(Mn.Rlca, Operand.None, Operand.None, 1, 4);
                case 0x08: return Mk(Mn.Ld, new Operand(OpKind.MemImm16, n16), Operand.Reg(R16.SP), 3, 20);
                case 0x09: return Mk(Mn.Add, Operand.Reg(R16.HL), Operand.Reg(R16.BC), 1, 8);
                case 0x0A: return Mk(Mn.Ld, Operand.Reg(R8.A), new Operand(OpKind.MemReg16, (int)R16.BC), 1, 8);
                case 0x0B: return Mk(Mn.Dec, Operand.Reg(R16.BC), Operand.None, 1, 8);
                case 0x0F: return Mk(Mn.Rrca, Operand.None, Operand.None, 1, 4);

                case 0x10: return Mk(Mn.Stop, Operand.None, Operand.None, 2, 4);
                case 0x11: return Mk(Mn.Ld, Operand.Reg(R16.DE), Imm16(n16), 3, 12);
                case 0x12: return Mk(Mn.Ld, new Operand(OpKind.MemReg16, (int)R16.DE), Operand.Reg(R8.A), 1, 8);
                case 0x13: return Mk(Mn.Inc, Operand.Reg(R16.DE), Operand.None, 1, 8);
                case 0x17: return Mk(Mn.Rla, Operand.None, Operand.None, 1, 4);
                case 0x18: return Mk(Mn.Jr, SImm8(n8), Operand.None, 2, 12);
                case 0x19: return Mk(Mn.Add, Operand.Reg(R16.HL), Operand.Reg(R16.DE), 1, 8);
                case 0x1A: return Mk(Mn.Ld, Operand.Reg(R8.A), new Operand(OpKind.MemReg16, (int)R16.DE), 1, 8);
                case 0x1B: return Mk(Mn.Dec, Operand.Reg(R16.DE), Operand.None, 1, 8);
                case 0x1F: return Mk(Mn.Rra, Operand.None, Operand.None, 1, 4);

                case 0x20: return Mk(Mn.Jr, Cc(Cond.NZ), SImm8(n8), 2, 12, 8);
                case 0x21: return Mk(Mn.Ld, Operand.Reg(R16.HL), Imm16(n16), 3, 12);
                case 0x22: return Mk(Mn.Ld, new Operand(OpKind.MemHLInc, 0), Operand.Reg(R8.A), 1, 8);
                case 0x23: return Mk(Mn.Inc, Operand.Reg(R16.HL), Operand.None, 1, 8);
                case 0x27: return Mk(Mn.Daa, Operand.None, Operand.None, 1, 4);
                case 0x28: return Mk(Mn.Jr, Cc(Cond.Z), SImm8(n8), 2, 12, 8);
                case 0x29: return Mk(Mn.Add, Operand.Reg(R16.HL), Operand.Reg(R16.HL), 1, 8);
                case 0x2A: return Mk(Mn.Ld, Operand.Reg(R8.A), new Operand(OpKind.MemHLInc, 0), 1, 8);
                case 0x2B: return Mk(Mn.Dec, Operand.Reg(R16.HL), Operand.None, 1, 8);
                case 0x2F: return Mk(Mn.Cpl, Operand.None, Operand.None, 1, 4);

                case 0x30: return Mk(Mn.Jr, Cc(Cond.NC), SImm8(n8), 2, 12, 8);
                case 0x31: return Mk(Mn.Ld, Operand.Reg(R16.SP), Imm16(n16), 3, 12);
                case 0x32: return Mk(Mn.Ld, new Operand(OpKind.MemHLDec, 0), Operand.Reg(R8.A), 1, 8);
                case 0x33: return Mk(Mn.Inc, Operand.Reg(R16.SP), Operand.None, 1, 8);
                case 0x37: return Mk(Mn.Scf, Operand.None, Operand.None, 1, 4);
                case 0x38: return Mk(Mn.Jr, Cc(Cond.C), SImm8(n8), 2, 12, 8);
                case 0x39: return Mk(Mn.Add, Operand.Reg(R16.HL), Operand.Reg(R16.SP), 1, 8);
                case 0x3A: return Mk(Mn.Ld, Operand.Reg(R8.A), new Operand(OpKind.MemHLDec, 0), 1, 8);
                case 0x3B: return Mk(Mn.Dec, Operand.Reg(R16.SP), Operand.None, 1, 8);
                case 0x3F: return Mk(Mn.Ccf, Operand.None, Operand.None, 1, 4);

                case 0xC0: return Mk(Mn.Ret, Cc(Cond.NZ), Operand.None, 1, 20, 8);
                case 0xC1: return Mk(Mn.Pop, Operand.Reg(R16.BC), Operand.None, 1, 12);
                case 0xC2: return Mk(Mn.Jp, Cc(Cond.NZ), Imm16(n16), 3, 16, 12);
                case 0xC3: return Mk(Mn.Jp, Imm16(n16), Operand.None, 3, 16);
                case 0xC4: return Mk(Mn.Call, Cc(Cond.NZ), Imm16(n16), 3, 24, 12);
                case 0xC5: return Mk(Mn.Push, Operand.Reg(R16.BC), Operand.None, 1, 16);
                case 0xC6: return Mk(Mn.Add, Operand.Reg(R8.A), Imm8(n8), 2, 8);
                case 0xC8: return Mk(Mn.Ret, Cc(Cond.Z), Operand.None, 1, 20, 8);
                case 0xC9: return Mk(Mn.Ret, Operand.None, Operand.None, 1, 16);
                case 0xCA: return Mk(Mn.Jp, Cc(Cond.Z), Imm16(n16), 3, 16, 12);
                case 0xCB: return DecodeCb(mem.Read(addr + 1));
                case 0xCC: return Mk(Mn.Call, Cc(Cond.Z), Imm16(n16), 3, 24, 12);
                case 0xCD: return Mk(Mn.Call, Imm16(n16), Operand.None, 3, 24);
                case 0xCE: return Mk(Mn.Adc, Operand.Reg(R8.A), Imm8(n8), 2, 8);

                case 0xD0: return Mk(Mn.Ret, Cc(Cond.NC), Operand.None, 1, 20, 8);
                case 0xD1: return Mk(Mn.Pop, Operand.Reg(R16.DE), Operand.None, 1, 12);
                case 0xD2: return Mk(Mn.Jp, Cc(Cond.NC), Imm16(n16), 3, 16, 12);
                case 0xD4: return Mk(Mn.Call, Cc(Cond.NC), Imm16(n16), 3, 24, 12);
                case 0xD5: return Mk(Mn.Push, Operand.Reg(R16.DE), Operand.None, 1, 16);
                case 0xD6: return Mk(Mn.Sub, Operand.Reg(R8.A), Imm8(n8), 2, 8);
                case 0xD8: return Mk(Mn.Ret, Cc(Cond.C), Operand.None, 1, 20, 8);
                case 0xD9: return Mk(Mn.Reti, Operand.None, Operand.None, 1, 16);
                case 0xDA: return Mk(Mn.Jp, Cc(Cond.C), Imm16(n16), 3, 16, 12);
                case 0xDC: return Mk(Mn.Call, Cc(Cond.C), Imm16(n16), 3, 24, 12);
                case 0xDE: return Mk(Mn.Sbc, Operand.Reg(R8.A), Imm8(n8), 2, 8);

                case 0xE0: return Mk(Mn.Ldh, new Operand(OpKind.HighImm8, n8), Operand.Reg(R8.A), 2, 12);
                case 0xE1: return Mk(Mn.Pop, Operand.Reg(R16.HL), Operand.None, 1, 12);
                case 0xE2: return Mk(Mn.Ldh, new Operand(OpKind.HighC, 0), Operand.Reg(R8.A), 1, 8);
                case 0xE5: return Mk(Mn.Push, Operand.Reg(R16.HL), Operand.None, 1, 16);
                case 0xE6: return Mk(Mn.And, Operand.Reg(R8.A), Imm8(n8), 2, 8);
                case 0xE8: return Mk(Mn.Add, Operand.Reg(R16.SP), SImm8(n8), 2, 16);
                case 0xE9: return Mk(Mn.Jp, Operand.Reg(R16.HL), Operand.None, 1, 4);
                case 0xEA: return Mk(Mn.Ld, new Operand(OpKind.MemImm16, n16), Operand.Reg(R8.A), 3, 16);
                case 0xEE: return Mk(Mn.Xor, Operand.Reg(R8.A), Imm8(n8), 2, 8);

                case 0xF0: return Mk(Mn.Ldh, Operand.Reg(R8.A), new Operand(OpKind.HighImm8, n8), 2, 12);
                case 0xF1: return Mk(Mn.Pop, Operand.Reg(R16.AF), Operand.None, 1, 12);
                case 0xF2: return Mk(Mn.Ldh, Operand.Reg(R8.A), new Operand(OpKind.HighC, 0), 1, 8);
                case 0xF3: return Mk(Mn.Di, Operand.None, Operand.None, 1, 4);
                case 0xF5: return Mk(Mn.Push, Operand.Reg(R16.AF), Operand.None, 1, 16);
                case 0xF6: return Mk(Mn.Or, Operand.Reg(R8.A), Imm8(n8), 2, 8);
                case 0xF8: return Mk(Mn.Ld, Operand.Reg(R16.HL), new Operand(OpKind.SPPlusE8, (sbyte)n8), 2, 12);
                case 0xF9: return Mk(Mn.Ld, Operand.Reg(R16.SP), Operand.Reg(R16.HL), 1, 8);
                case 0xFA: return Mk(Mn.Ld, Operand.Reg(R8.A), new Operand(OpKind.MemImm16, n16), 3, 16);
                case 0xFB: return Mk(Mn.Ei, Operand.None, Operand.None, 1, 4);
                case 0xFE: return Mk(Mn.Cp, Operand.Reg(R8.A), Imm8(n8), 2, 8);
            }

            // 0x04/0x05/0x06 etc (INC/DEC/LD r,n8) fall out of the regular
            // low-column pattern: bits 3-5 select the register.
            if ((op & 0xC7) == 0x04) // INC r
            {
                var r = (R8)((op >> 3) & 7);
                return Mk(Mn.Inc, Operand.Reg(r), Operand.None, 1, r == R8.MemHL ? 12 : 4);
            }
            if ((op & 0xC7) == 0x05) // DEC r
            {
                var r = (R8)((op >> 3) & 7);
                return Mk(Mn.Dec, Operand.Reg(r), Operand.None, 1, r == R8.MemHL ? 12 : 4);
            }
            if ((op & 0xC7) == 0x06) // LD r, n8
            {
                var r = (R8)((op >> 3) & 7);
                return Mk(Mn.Ld, Operand.Reg(r), Imm8(n8), 2, r == R8.MemHL ? 12 : 8);
            }
            if ((op & 0xC7) == 0xC7) // RST
            {
                return Mk(Mn.Rst, new Operand(OpKind.RstVec, op & 0x38), Operand.None, 1, 16);
            }

            // D3 DB DD E3 E4 EB EC ED F4 FC FD have no encoding; the real CPU
            // locks up. Surface them rather than silently emitting a nop.
            return Mk(Mn.Invalid, Imm8(op), Operand.None, 1, 4);
        }

        static Instr DecodeCb(byte cb)
        {
            var r = (R8)(cb & 7);
            bool hl = r == R8.MemHL;
            int hi = cb >> 6;

            if (hi == 0)
            {
                Mn m = CbShiftMn((cb >> 3) & 7);
                return Mk(m, Operand.Reg(r), Operand.None, 2, hl ? 16 : 8);
            }

            int bit = (cb >> 3) & 7;
            var bitOp = new Operand(OpKind.BitIdx, bit);
            switch (hi)
            {
                case 1: return Mk(Mn.Bit, bitOp, Operand.Reg(r), 2, hl ? 12 : 8);
                case 2: return Mk(Mn.Res, bitOp, Operand.Reg(r), 2, hl ? 16 : 8);
                default: return Mk(Mn.Set, bitOp, Operand.Reg(r), 2, hl ? 16 : 8);
            }
        }

        static Mn AluMn(int i)
        {
            switch (i)
            {
                case 0: return Mn.Add;
                case 1: return Mn.Adc;
                case 2: return Mn.Sub;
                case 3: return Mn.Sbc;
                case 4: return Mn.And;
                case 5: return Mn.Xor;
                case 6: return Mn.Or;
                default: return Mn.Cp;
            }
        }

        static Mn CbShiftMn(int i)
        {
            switch (i)
            {
                case 0: return Mn.Rlc;
                case 1: return Mn.Rrc;
                case 2: return Mn.Rl;
                case 3: return Mn.Rr;
                case 4: return Mn.Sla;
                case 5: return Mn.Sra;
                case 6: return Mn.Swap;
                default: return Mn.Srl;
            }
        }
    }
}
