using System;
using System.Text;

namespace Recomp.Sm83
{
    // Sharp SM83 (LR35902) instruction model.
    //
    // Note this is NOT a Z80: no IX/IY, no ED prefix, no shadow registers.
    // The opcodes Z80 uses for those are either reassigned (0x08 LD [a16],SP;
    // 0x10 STOP; 0xE0/0xE2/0xF0/0xF2 high-page loads) or simply invalid.

    public enum Mn
    {
        Invalid, Nop, Ld, Ldh, Inc, Dec, Add, Adc, Sub, Sbc, And, Xor, Or, Cp,
        Rlca, Rrca, Rla, Rra, Daa, Cpl, Scf, Ccf,
        Jr, Jp, Call, Ret, Reti, Rst, Push, Pop,
        Halt, Stop, Di, Ei, Prefix,
        Rlc, Rrc, Rl, Rr, Sla, Sra, Swap, Srl, Bit, Res, Set
    }

    public enum R8 { B = 0, C = 1, D = 2, E = 3, H = 4, L = 5, MemHL = 6, A = 7 }

    public enum R16 { BC = 0, DE = 1, HL = 2, SP = 3, AF = 4 }

    public enum Cond { NZ = 0, Z = 1, NC = 2, C = 3 }

    public enum OpKind
    {
        None,
        Reg8,        // Val = R8 (MemHL means the [HL] pseudo-register)
        Reg16,       // Val = R16
        MemReg16,    // [BC] / [DE]           Val = R16
        MemHLInc,    // [HL+]
        MemHLDec,    // [HL-]
        Imm8,        // n8                    Val = value
        Imm16,       // n16                   Val = value
        SImm8,       // e8, signed            Val = value (sign-extended)
        MemImm16,    // [a16]                 Val = address
        HighImm8,    // [$FF00+a8]            Val = a8
        HighC,       // [$FF00+C]
        SPPlusE8,    // SP+e8                 Val = signed offset
        Cc,          // Val = Cond
        RstVec,      // Val = target ($00..$38)
        BitIdx       // Val = 0..7
    }

    public struct Operand
    {
        public OpKind Kind;
        public int Val;

        public Operand(OpKind k, int v) { Kind = k; Val = v; }

        public static readonly Operand None = new Operand(OpKind.None, 0);
        public static Operand Reg(R8 r) { return new Operand(OpKind.Reg8, (int)r); }
        public static Operand Reg(R16 r) { return new Operand(OpKind.Reg16, (int)r); }

        public bool IsMemHL { get { return Kind == OpKind.Reg8 && Val == (int)R8.MemHL; } }

        // True if evaluating this operand touches the GB address space.
        public bool TouchesMemory
        {
            get
            {
                switch (Kind)
                {
                    case OpKind.MemReg16:
                    case OpKind.MemHLInc:
                    case OpKind.MemHLDec:
                    case OpKind.MemImm16:
                    case OpKind.HighImm8:
                    case OpKind.HighC:
                        return true;
                    case OpKind.Reg8:
                        return Val == (int)R8.MemHL;
                    default:
                        return false;
                }
            }
        }

        static readonly string[] R8Names = { "b", "c", "d", "e", "h", "l", "[hl]", "a" };
        static readonly string[] R16Names = { "bc", "de", "hl", "sp", "af" };
        static readonly string[] CcNames = { "nz", "z", "nc", "c" };

        public override string ToString()
        {
            switch (Kind)
            {
                case OpKind.None: return "";
                case OpKind.Reg8: return R8Names[Val];
                case OpKind.Reg16: return R16Names[Val];
                case OpKind.MemReg16: return "[" + R16Names[Val] + "]";
                case OpKind.MemHLInc: return "[hl+]";
                case OpKind.MemHLDec: return "[hl-]";
                case OpKind.Imm8: return "$" + Val.ToString("x2");
                case OpKind.Imm16: return "$" + Val.ToString("x4");
                case OpKind.SImm8: return (Val < 0 ? "-$" + (-Val).ToString("x2") : "$" + Val.ToString("x2"));
                case OpKind.MemImm16: return "[$" + Val.ToString("x4") + "]";
                case OpKind.HighImm8: return "[$ff" + Val.ToString("x2") + "]";
                case OpKind.HighC: return "[$ff00+c]";
                case OpKind.SPPlusE8: return "sp" + (Val < 0 ? "-$" + (-Val).ToString("x2") : "+$" + Val.ToString("x2"));
                case OpKind.Cc: return CcNames[Val];
                case OpKind.RstVec: return "$" + Val.ToString("x2");
                case OpKind.BitIdx: return Val.ToString();
                default: return "?";
            }
        }
    }

    public sealed class Instr
    {
        public Mn Op;
        public Operand A;
        public Operand B;
        public int Length;        // bytes, including CB prefix
        public int Cycles;        // t-cycles, branch taken
        public int CyclesNotTaken; // t-cycles when a conditional branch falls through (0 if N/A)
        public int Addr;          // GB address this was decoded from
        public byte[] Bytes;

        public bool IsConditional { get { return A.Kind == OpKind.Cc; } }

        // Control flow: does execution continue at Addr+Length?
        public bool FallsThrough
        {
            get
            {
                switch (Op)
                {
                    case Mn.Jp:
                    case Mn.Jr:
                        return IsConditional;
                    case Mn.Ret:
                        return IsConditional;
                    case Mn.Reti:
                        return false;
                    default:
                        return true;
                }
            }
        }

        // Static branch target, or -1 if none / indirect.
        public int BranchTarget
        {
            get
            {
                switch (Op)
                {
                    case Mn.Jr:
                        {
                            var t = IsConditional ? B : A;
                            return (Addr + Length + t.Val) & 0xFFFF;
                        }
                    case Mn.Jp:
                    case Mn.Call:
                        {
                            var t = IsConditional ? B : A;
                            if (t.Kind == OpKind.Imm16) return t.Val;
                            return -1; // jp hl
                        }
                    case Mn.Rst:
                        return A.Val;
                    default:
                        return -1;
                }
            }
        }

        public string Mnemonic
        {
            get
            {
                var s = Op.ToString().ToLowerInvariant();
                return s;
            }
        }

        public override string ToString()
        {
            var sb = new StringBuilder();
            sb.Append(Mnemonic);
            if (A.Kind != OpKind.None)
            {
                sb.Append(' ').Append(A.ToString());
                if (B.Kind != OpKind.None) sb.Append(", ").Append(B.ToString());
            }
            return sb.ToString();
        }
    }
}
