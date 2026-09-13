using System;
using Recomp.Sm83;

namespace Recomp.Emu
{
    // SM83 interpreter. Decode comes from the verified Recomp.Sm83.Decoder, so
    // instruction lengths and cycle counts are the ones the self-test checks.
    public sealed class Cpu : Decoder.IMem
    {
        public byte A, B, C, D, E, H, L;
        public bool FZ, FN, FH, FC;
        public int SP, PC;
        public bool Ime, Halted;
        public long Cycles;

        readonly Bus _bus;

        public Cpu(Bus bus) { _bus = bus; }

        public byte Read(int addr) { return _bus.Read(addr); }

        public int HL { get { return (H << 8) | L; } set { H = (byte)(value >> 8); L = (byte)value; } }
        public int BC { get { return (B << 8) | C; } set { B = (byte)(value >> 8); C = (byte)value; } }
        public int DE { get { return (D << 8) | E; } set { D = (byte)(value >> 8); E = (byte)value; } }

        public byte F
        {
            get { return (byte)((FZ ? 0x80 : 0) | (FN ? 0x40 : 0) | (FH ? 0x20 : 0) | (FC ? 0x10 : 0)); }
            set { FZ = (value & 0x80) != 0; FN = (value & 0x40) != 0; FH = (value & 0x20) != 0; FC = (value & 0x10) != 0; }
        }

        // Post-boot-ROM state, as the DMG leaves it.
        public void Reset()
        {
            A = 0x01; F = 0xB0; B = 0x00; C = 0x13; D = 0x00; E = 0xD8; H = 0x01; L = 0x4D;
            SP = 0xFFFE; PC = 0x0100; Ime = false; Halted = false;
            _bus.Write(0xFF40, 0x91);  // LCDC on
            _bus.Write(0xFF47, 0xFC);  // BGP
        }

        void Push(int v)
        {
            SP = (SP - 1) & 0xFFFF; _bus.Write(SP, (byte)(v >> 8));
            SP = (SP - 1) & 0xFFFF; _bus.Write(SP, (byte)v);
        }

        int Pop()
        {
            int lo = _bus.Read(SP); SP = (SP + 1) & 0xFFFF;
            int hi = _bus.Read(SP); SP = (SP + 1) & 0xFFFF;
            return (hi << 8) | lo;
        }

        public int Step()
        {
            // Interrupt dispatch. HALT wakes on a pending interrupt even when
            // IME is clear, which is how DelayFrame's halt loop exits.
            int pending = _bus.Ie & _bus.If & 0x1F;
            if (pending != 0)
            {
                Halted = false;
                if (Ime)
                {
                    for (int bit = 0; bit < 5; bit++)
                    {
                        if ((pending & (1 << bit)) == 0) continue;
                        _bus.If &= (byte)~(1 << bit);
                        Ime = false;
                        Push(PC);
                        PC = 0x40 + bit * 8;
                        Cycles += 20;
                        return 20;
                    }
                }
            }
            if (Halted) { Cycles += 4; return 4; }

            var ins = Decoder.Decode(this, PC);
            int next = (PC + ins.Length) & 0xFFFF;
            int cyc = ins.Cycles;
            PC = next;
            Execute(ins, ref cyc);
            Cycles += cyc;
            return cyc;
        }

        // ---- operand access ------------------------------------------------

        byte GetR8(R8 r)
        {
            switch (r)
            {
                case R8.A: return A; case R8.B: return B; case R8.C: return C;
                case R8.D: return D; case R8.E: return E; case R8.H: return H;
                case R8.L: return L; default: return _bus.Read(HL);
            }
        }

        void SetR8(R8 r, byte v)
        {
            switch (r)
            {
                case R8.A: A = v; break; case R8.B: B = v; break; case R8.C: C = v; break;
                case R8.D: D = v; break; case R8.E: E = v; break; case R8.H: H = v; break;
                case R8.L: L = v; break; default: _bus.Write(HL, v); break;
            }
        }

        int GetR16(R16 r)
        {
            switch (r) { case R16.BC: return BC; case R16.DE: return DE; case R16.HL: return HL; case R16.SP: return SP; default: return (A << 8) | F; }
        }

        void SetR16(R16 r, int v)
        {
            v &= 0xFFFF;
            switch (r)
            {
                case R16.BC: BC = v; break; case R16.DE: DE = v; break; case R16.HL: HL = v; break;
                case R16.SP: SP = v; break; default: A = (byte)(v >> 8); F = (byte)(v & 0xF0); break;
            }
        }

        byte LoadOp(Operand o)
        {
            switch (o.Kind)
            {
                case OpKind.Reg8: return GetR8((R8)o.Val);
                case OpKind.Imm8: return (byte)o.Val;
                case OpKind.MemReg16: return _bus.Read(GetR16((R16)o.Val));
                case OpKind.MemImm16: return _bus.Read(o.Val);
                case OpKind.HighImm8: return _bus.Read(0xFF00 | o.Val);
                case OpKind.HighC: return _bus.Read(0xFF00 | C);
                case OpKind.MemHLInc: { var v = _bus.Read(HL); HL = (HL + 1) & 0xFFFF; return v; }
                case OpKind.MemHLDec: { var v = _bus.Read(HL); HL = (HL - 1) & 0xFFFF; return v; }
                default: throw new InvalidOperationException("load " + o.Kind);
            }
        }

        void StoreOp(Operand o, byte v)
        {
            switch (o.Kind)
            {
                case OpKind.Reg8: SetR8((R8)o.Val, v); break;
                case OpKind.MemReg16: _bus.Write(GetR16((R16)o.Val), v); break;
                case OpKind.MemImm16: _bus.Write(o.Val, v); break;
                case OpKind.HighImm8: _bus.Write(0xFF00 | o.Val, v); break;
                case OpKind.HighC: _bus.Write(0xFF00 | C, v); break;
                case OpKind.MemHLInc: _bus.Write(HL, v); HL = (HL + 1) & 0xFFFF; break;
                case OpKind.MemHLDec: _bus.Write(HL, v); HL = (HL - 1) & 0xFFFF; break;
                default: throw new InvalidOperationException("store " + o.Kind);
            }
        }

        bool TestCond(Cond c)
        {
            switch (c) { case Cond.Z: return FZ; case Cond.NZ: return !FZ; case Cond.C: return FC; default: return !FC; }
        }

        // ---- execution -----------------------------------------------------

        void Execute(Instr ins, ref int cyc)
        {
            switch (ins.Op)
            {
                case Mn.Nop: case Mn.Stop: break;
                case Mn.Halt: Halted = true; break;
                case Mn.Di: Ime = false; break;
                case Mn.Ei: Ime = true; break;

                case Mn.Ld: ExecLd(ins); break;
                case Mn.Ldh: StoreOp(ins.A, LoadOp(ins.B)); break;

                case Mn.Add: ExecAdd(ins); break;
                case Mn.Adc: { int v = LoadOp(ins.B); int c = FC ? 1 : 0; int r = A + v + c;
                               FH = ((A & 0xF) + (v & 0xF) + c) > 0xF; FC = r > 0xFF; A = (byte)r; FZ = A == 0; FN = false; break; }
                case Mn.Sub: { int v = LoadOp(ins.B); int r = A - v;
                               FH = (A & 0xF) < (v & 0xF); FC = r < 0; A = (byte)r; FZ = A == 0; FN = true; break; }
                case Mn.Sbc: { int v = LoadOp(ins.B); int c = FC ? 1 : 0; int r = A - v - c;
                               FH = (A & 0xF) < ((v & 0xF) + c); FC = r < 0; A = (byte)r; FZ = A == 0; FN = true; break; }
                case Mn.And: A &= LoadOp(ins.B); FZ = A == 0; FN = false; FH = true; FC = false; break;
                case Mn.Or:  A |= LoadOp(ins.B); FZ = A == 0; FN = false; FH = false; FC = false; break;
                case Mn.Xor: A ^= LoadOp(ins.B); FZ = A == 0; FN = false; FH = false; FC = false; break;
                case Mn.Cp:  { int v = LoadOp(ins.B); int r = A - v;
                               FH = (A & 0xF) < (v & 0xF); FC = r < 0; FZ = (byte)r == 0; FN = true; break; }

                case Mn.Inc: ExecIncDec(ins, true); break;
                case Mn.Dec: ExecIncDec(ins, false); break;

                case Mn.Jp: ExecJump(ins, ref cyc); break;
                case Mn.Jr: ExecJump(ins, ref cyc); break;
                case Mn.Call: ExecCall(ins, ref cyc); break;
                case Mn.Ret:
                    if (ins.IsConditional) { if (TestCond((Cond)ins.A.Val)) PC = Pop(); else cyc = ins.CyclesNotTaken; }
                    else PC = Pop();
                    break;
                case Mn.Reti: PC = Pop(); Ime = true; break;
                case Mn.Rst: Push(PC); PC = ins.A.Val; break;

                case Mn.Push: Push(GetR16((R16)ins.A.Val)); break;
                case Mn.Pop: SetR16((R16)ins.A.Val, Pop()); break;

                case Mn.Rlca: { int c = (A >> 7) & 1; A = (byte)((A << 1) | c); FZ = false; FN = false; FH = false; FC = c != 0; break; }
                case Mn.Rrca: { int c = A & 1; A = (byte)((A >> 1) | (c << 7)); FZ = false; FN = false; FH = false; FC = c != 0; break; }
                case Mn.Rla:  { int c = FC ? 1 : 0; FC = (A & 0x80) != 0; A = (byte)((A << 1) | c); FZ = false; FN = false; FH = false; break; }
                case Mn.Rra:  { int c = FC ? 1 : 0; FC = (A & 1) != 0; A = (byte)((A >> 1) | (c << 7)); FZ = false; FN = false; FH = false; break; }

                case Mn.Cpl: A = (byte)~A; FN = true; FH = true; break;
                case Mn.Scf: FC = true; FN = false; FH = false; break;
                case Mn.Ccf: FC = !FC; FN = false; FH = false; break;
                case Mn.Daa: ExecDaa(); break;

                case Mn.Rlc: case Mn.Rrc: case Mn.Rl: case Mn.Rr:
                case Mn.Sla: case Mn.Sra: case Mn.Swap: case Mn.Srl:
                    ExecCbShift(ins); break;

                case Mn.Bit: { byte v = GetR8((R8)ins.B.Val); FZ = (v & (1 << ins.A.Val)) == 0; FN = false; FH = true; break; }
                case Mn.Res: SetR8((R8)ins.B.Val, (byte)(GetR8((R8)ins.B.Val) & ~(1 << ins.A.Val))); break;
                case Mn.Set: SetR8((R8)ins.B.Val, (byte)(GetR8((R8)ins.B.Val) | (1 << ins.A.Val))); break;

                case Mn.Invalid:
                    throw new InvalidOperationException("invalid opcode $" + ins.A.Val.ToString("x2") + " at $" + ins.Addr.ToString("x4"));

                default:
                    throw new InvalidOperationException("unimplemented " + ins.Op);
            }
        }

        void ExecLd(Instr ins)
        {
            var d = ins.A; var s = ins.B;

            if (d.Kind == OpKind.Reg16 && s.Kind == OpKind.Imm16) { SetR16((R16)d.Val, s.Val); return; }
            if (d.Kind == OpKind.Reg16 && s.Kind == OpKind.Reg16) { SetR16((R16)d.Val, GetR16((R16)s.Val)); return; }

            if (d.Kind == OpKind.MemImm16 && s.Kind == OpKind.Reg16)
            {
                int v = GetR16((R16)s.Val);
                _bus.Write(d.Val, (byte)v);
                _bus.Write((d.Val + 1) & 0xFFFF, (byte)(v >> 8));
                return;
            }

            if (s.Kind == OpKind.SPPlusE8)
            {
                int r = (SP + s.Val) & 0xFFFF;
                FZ = false; FN = false;
                FH = ((SP & 0xF) + (s.Val & 0xF)) > 0xF;
                FC = ((SP & 0xFF) + (s.Val & 0xFF)) > 0xFF;
                SetR16((R16)d.Val, r);
                return;
            }

            StoreOp(d, LoadOp(s));
        }

        void ExecAdd(Instr ins)
        {
            if (ins.A.Kind == OpKind.Reg16 && ins.B.Kind == OpKind.Reg16)
            {
                int hl = HL, v = GetR16((R16)ins.B.Val), r = hl + v;
                FN = false;
                FH = ((hl & 0x0FFF) + (v & 0x0FFF)) > 0x0FFF;
                FC = r > 0xFFFF;
                HL = r & 0xFFFF;
                return;
            }
            if (ins.A.Kind == OpKind.Reg16 && ins.B.Kind == OpKind.SImm8)
            {
                int e = ins.B.Val;
                FZ = false; FN = false;
                FH = ((SP & 0xF) + (e & 0xF)) > 0xF;
                FC = ((SP & 0xFF) + (e & 0xFF)) > 0xFF;
                SP = (SP + e) & 0xFFFF;
                return;
            }
            {
                int v = LoadOp(ins.B), r = A + v;
                FH = ((A & 0xF) + (v & 0xF)) > 0xF; FC = r > 0xFF; A = (byte)r; FZ = A == 0; FN = false;
            }
        }

        void ExecIncDec(Instr ins, bool inc)
        {
            if (ins.A.Kind == OpKind.Reg16)
            {
                SetR16((R16)ins.A.Val, GetR16((R16)ins.A.Val) + (inc ? 1 : -1));
                return;   // 16-bit inc/dec touch no flags
            }
            var r = (R8)ins.A.Val;
            byte v = GetR8(r);
            byte n = (byte)(inc ? v + 1 : v - 1);
            SetR8(r, n);
            FZ = n == 0;
            FN = !inc;
            FH = inc ? (v & 0xF) == 0xF : (v & 0xF) == 0;
            // C preserved
        }

        void ExecJump(Instr ins, ref int cyc)
        {
            if (ins.Op == Mn.Jp && ins.A.Kind == OpKind.Reg16) { PC = HL; return; }
            int target = ins.BranchTarget;
            if (ins.IsConditional)
            {
                if (TestCond((Cond)ins.A.Val)) PC = target;
                else cyc = ins.CyclesNotTaken;
            }
            else PC = target;
        }

        void ExecCall(Instr ins, ref int cyc)
        {
            int target = ins.BranchTarget;
            if (ins.IsConditional)
            {
                if (!TestCond((Cond)ins.A.Val)) { cyc = ins.CyclesNotTaken; return; }
            }
            Push(PC);
            PC = target;
        }

        void ExecDaa()
        {
            int a = A;
            if (!FN)
            {
                if (FH || (a & 0x0F) > 9) a += 0x06;
                if (FC || a > 0x9F) { a += 0x60; FC = true; }
            }
            else
            {
                if (FH) a = (a - 0x06) & 0xFF;
                if (FC) a -= 0x60;
            }
            a &= 0xFF;
            FH = false;
            FZ = a == 0;
            A = (byte)a;
        }

        void ExecCbShift(Instr ins)
        {
            var r = (R8)ins.A.Val;
            byte v = GetR8(r);
            byte n;
            switch (ins.Op)
            {
                case Mn.Rlc:  FC = (v & 0x80) != 0; n = (byte)((v << 1) | (FC ? 1 : 0)); break;
                case Mn.Rrc:  FC = (v & 0x01) != 0; n = (byte)((v >> 1) | (FC ? 0x80 : 0)); break;
                case Mn.Rl:   { int c = FC ? 1 : 0; FC = (v & 0x80) != 0; n = (byte)((v << 1) | c); break; }
                case Mn.Rr:   { int c = FC ? 0x80 : 0; FC = (v & 0x01) != 0; n = (byte)((v >> 1) | c); break; }
                case Mn.Sla:  FC = (v & 0x80) != 0; n = (byte)(v << 1); break;
                case Mn.Sra:  FC = (v & 0x01) != 0; n = (byte)((v >> 1) | (v & 0x80)); break;
                case Mn.Swap: n = (byte)((v >> 4) | (v << 4)); FC = false; break;
                default:      FC = (v & 0x01) != 0; n = (byte)(v >> 1); break;   // Srl
            }
            SetR8(r, n);
            FZ = n == 0;
            FN = false;
            FH = false;
        }
    }
}
