using System;
using System.Collections.Generic;
using System.Text;
using Recomp.Sm83;

namespace Recomp.X86
{
    // SM83 -> x86-64 (NASM syntax).
    //
    // REGISTER MAPPING
    //   A  -> al          BC -> bx (B=bh, C=bl)
    //                     DE -> cx (D=ch, E=cl)
    //                     HL -> dx (H=dh, L=dl)
    //   SP -> r15w        GB address window base -> rbp
    //   scratch: rsi, rdi, r8-r11
    //
    // GB code reads B/C/D/E/H/L as often as the pairs, so mapping each pair to
    // a legacy register with addressable halves avoids a shift on every access.
    // The cost is that bh/ch/dh cannot appear in an instruction carrying a REX
    // prefix, so the emitter never mixes them with r8-r15.
    //
    // The upper 48 bits of rbx/rcx/rdx are zero on entry and every write we
    // emit targets a 16- or 8-bit subregister, which leaves the upper bits
    // alone. That invariant is what makes [rbp+rdx] a valid "[HL]" without a
    // movzx on every access.
    //
    // FLAGS
    //   GB Z <-> x86 ZF, GB C <-> x86 CF, GB H <-> x86 AF (auxiliary carry is
    //   exactly the GB half-carry for 8-bit add/sub). GB N has no x86
    //   counterpart, but N is only ever *read* by DAA, and whether the last
    //   flag-setting op was a subtract is known at translation time. So the
    //   emitter keeps flags live in the x86 flags register and tracks N as a
    //   compile-time constant, materialising the packed F byte only where
    //   something actually observes it (push af, daa).
    //
    //   The exceptions are marked below: logic ops leave AF undefined, and the
    //   16-bit adds have GB-specific H/C semantics that need explicit code.

    public class NotTranslatable : Exception
    {
        public NotTranslatable(string m) : base(m) { }
    }

    // What the x86 flags register currently holds relative to GB flags.
    public sealed class FlagState
    {
        public bool ZLive, CLive, HLive;  // GB flag validly held in ZF/CF/AF
        public int ZConst = -1, CConst = -1, HConst = -1; // when not live: 0/1, -1 unknown
        public int NConst;                // GB N; 0/1, -1 unknown

        public static FlagState AllUnknown()
        {
            return new FlagState { NConst = -1 };
        }

        // State on return from a translated routine. Our `ret` sequence uses
        // lea for the stack adjust precisely so Z/H/C survive the call, which
        // is how GB routines report status ("return with carry set"). N is the
        // one flag with no x86 home, so it lives in the gb_n byte, which the
        // callee spilled on its way out.
        public static FlagState AfterCall()
        {
            return new FlagState
            {
                ZLive = true, CLive = true, HLive = true,
                ZConst = -1, CConst = -1, HConst = -1,
                NConst = -1
            };
        }

        public FlagState Clone()
        {
            return new FlagState
            {
                ZLive = ZLive, CLive = CLive, HLive = HLive,
                ZConst = ZConst, CConst = CConst, HConst = HConst,
                NConst = NConst
            };
        }

        // After a normal 8-bit add/sub: everything lands in x86 flags.
        public void NativeAll(int n)
        {
            ZLive = CLive = HLive = true;
            ZConst = CConst = HConst = -1;
            NConst = n;
        }
    }

    public sealed class Emitter
    {
        readonly StringBuilder _sb = new StringBuilder();
        readonly Func<int, string> _labelFor;
        FlagState _f = FlagState.AllUnknown();

        // GB regions that are plain RAM: safe to touch directly through rbp
        // with no MMIO side effects and no bank indirection.
        static bool IsDirectRam(int addr)
        {
            return (addr >= 0xC000 && addr <= 0xDFFF)   // WRAM
                || (addr >= 0xFF80 && addr <= 0xFFFE);  // HRAM
        }

        public Emitter(Func<int, string> labelFor)
        {
            _labelFor = labelFor ?? (a => "gb_" + a.ToString("x4"));
        }

        public string Text { get { return _sb.ToString(); } }

        void E(string s) { _sb.Append("        ").Append(s).AppendLine(); }
        void Cmt(string s) { _sb.Append("        ; ").Append(s).AppendLine(); }
        public void Label(string s) { _sb.Append(s).AppendLine(":"); }

        static string R8Name(R8 r)
        {
            switch (r)
            {
                case R8.A: return "al";
                case R8.B: return "bh";
                case R8.C: return "bl";
                case R8.D: return "ch";
                case R8.E: return "cl";
                case R8.H: return "dh";
                case R8.L: return "dl";
                default: throw new NotTranslatable("[hl] is not a register");
            }
        }

        static string R16Name(R16 r)
        {
            switch (r)
            {
                case R16.BC: return "bx";
                case R16.DE: return "cx";
                case R16.HL: return "dx";
                case R16.SP: return "r15w";
                default: throw new NotTranslatable("af has no direct 16-bit mapping");
            }
        }

        // ---- memory ----------------------------------------------------

        // Loads an 8-bit value described by `o` into `dest` (an 8-bit x86 reg).
        void LoadOperand8(Operand o, string dest)
        {
            switch (o.Kind)
            {
                case OpKind.Reg8:
                    if (o.IsMemHL) { E("mov " + dest + ", [rbp+rdx]"); return; }
                    if (R8Name((R8)o.Val) != dest) E("mov " + dest + ", " + R8Name((R8)o.Val));
                    return;

                case OpKind.Imm8:
                    E("mov " + dest + ", " + o.Val);
                    return;

                case OpKind.MemReg16:
                    E("mov " + dest + ", [rbp+" + Wide(R16Name((R16)o.Val)) + "]");
                    return;

                case OpKind.MemImm16:
                    if (IsDirectRam(o.Val)) E("mov " + dest + ", [rbp+0x" + o.Val.ToString("x") + "]");
                    else ReadHelper(o.Val, dest);
                    return;

                case OpKind.HighImm8:
                    {
                        int a = 0xFF00 | o.Val;
                        if (IsDirectRam(a)) E("mov " + dest + ", [rbp+0x" + a.ToString("x") + "]");
                        else ReadHelper(a, dest);
                        return;
                    }

                case OpKind.HighC:
                    Cmt("[$ff00+c] - always MMIO-capable, goes through the helper");
                    E("movzx esi, bl");
                    E("or esi, 0xff00");
                    E("call gb_read8");
                    if (dest != "al") E("mov " + dest + ", al");
                    return;

                default:
                    throw new NotTranslatable("cannot load operand " + o.Kind);
            }
        }

        static string Wide(string w)
        {
            switch (w)
            {
                case "bx": return "rbx";
                case "cx": return "rcx";
                case "dx": return "rdx";
                case "r15w": return "r15";
                default: throw new NotTranslatable("no 64-bit form for " + w);
            }
        }

        void ReadHelper(int addr, string dest)
        {
            E("mov esi, 0x" + addr.ToString("x"));
            E("call gb_read8");
            if (dest != "al") E("mov " + dest + ", al");
        }

        // Stores the 8-bit x86 register `src` into the location described by `o`.
        void StoreOperand8(Operand o, string src)
        {
            switch (o.Kind)
            {
                case OpKind.Reg8:
                    if (o.IsMemHL) { E("mov [rbp+rdx], " + src); return; }
                    if (R8Name((R8)o.Val) != src) E("mov " + R8Name((R8)o.Val) + ", " + src);
                    return;

                case OpKind.MemReg16:
                    E("mov [rbp+" + Wide(R16Name((R16)o.Val)) + "], " + src);
                    return;

                case OpKind.MemHLInc:
                    E("mov [rbp+rdx], " + src);
                    E("lea dx, [rdx+1]");
                    return;

                case OpKind.MemHLDec:
                    E("mov [rbp+rdx], " + src);
                    E("lea dx, [rdx-1]");
                    return;

                case OpKind.MemImm16:
                    if (IsDirectRam(o.Val)) E("mov [rbp+0x" + o.Val.ToString("x") + "], " + src);
                    else WriteHelper(o.Val, src);
                    return;

                case OpKind.HighImm8:
                    {
                        int a = 0xFF00 | o.Val;
                        // $FF00-$FF7F is MMIO: writes have side effects (LCDC,
                        // bank select, DMA...) so they must go through the trap.
                        if (IsDirectRam(a)) E("mov [rbp+0x" + a.ToString("x") + "], " + src);
                        else WriteHelper(a, src);
                        return;
                    }

                case OpKind.HighC:
                    E("movzx esi, bl");
                    E("or esi, 0xff00");
                    if (src != "dil") E("movzx edi, " + src);
                    E("call gb_write8");
                    return;

                default:
                    throw new NotTranslatable("cannot store to operand " + o.Kind);
            }
        }

        void WriteHelper(int addr, string src)
        {
            E("mov esi, 0x" + addr.ToString("x"));
            E("movzx edi, " + src);
            E("call gb_write8");
        }

        // ---- instruction translation -----------------------------------

        public void Emit(Instr ins)
        {
            _sb.Append("        ; $").Append(ins.Addr.ToString("x4")).Append("  ").Append(ins).AppendLine();

            switch (ins.Op)
            {
                case Mn.Nop: E("nop"); return;

                case Mn.Ld: EmitLd(ins); return;
                case Mn.Ldh: EmitLd(ins); return;

                case Mn.Add: case Mn.Adc: case Mn.Sub: case Mn.Sbc:
                case Mn.And: case Mn.Xor: case Mn.Or: case Mn.Cp:
                    EmitAlu(ins); return;

                case Mn.Inc: EmitIncDec(ins, true); return;
                case Mn.Dec: EmitIncDec(ins, false); return;

                case Mn.Jr: case Mn.Jp: EmitJump(ins); return;
                case Mn.Call: EmitCall(ins); return;
                case Mn.Ret: EmitRet(ins); return;

                case Mn.Push: EmitPush(ins); return;
                case Mn.Pop: EmitPop(ins); return;

                case Mn.Di: Cmt("di"); E("mov byte [gb_ime], 0"); return;
                case Mn.Ei: Cmt("ei"); E("mov byte [gb_ime], 1"); return;
                case Mn.Halt: E("call gb_halt"); return;

                case Mn.Cpl:
                    E("not al");
                    _f.HLive = false; _f.HConst = 1;
                    _f.NConst = 1;
                    return;

                case Mn.Scf:
                    E("stc");
                    _f.CLive = true; _f.HLive = false; _f.HConst = 0; _f.NConst = 0;
                    return;

                case Mn.Ccf:
                    E("cmc");
                    _f.CLive = true; _f.HLive = false; _f.HConst = 0; _f.NConst = 0;
                    return;

                case Mn.Invalid:
                    throw new NotTranslatable("invalid opcode $" + ins.A.Val.ToString("x2")
                                              + " at $" + ins.Addr.ToString("x4"));

                default:
                    throw new NotTranslatable(ins.Op + " not yet implemented (at $"
                                              + ins.Addr.ToString("x4") + ": " + ins + ")");
            }
        }

        void EmitLd(Instr ins)
        {
            var d = ins.A; var s = ins.B;

            // 16-bit forms
            if (d.Kind == OpKind.Reg16 && s.Kind == OpKind.Imm16)
            { E("mov " + R16Name((R16)d.Val) + ", 0x" + s.Val.ToString("x")); return; }

            if (d.Kind == OpKind.Reg16 && s.Kind == OpKind.Reg16)
            { E("mov " + R16Name((R16)d.Val) + ", " + R16Name((R16)s.Val)); return; }

            if (d.Kind == OpKind.MemImm16 && s.Kind == OpKind.Reg16 && (R16)s.Val == R16.SP)
            {
                Cmt("ld [a16], sp - 16-bit store, little endian");
                E("mov esi, 0x" + d.Val.ToString("x"));
                E("movzx edi, r15w");
                E("call gb_write16");
                return;
            }

            // ld a, [hl+] / [hl-]
            if (s.Kind == OpKind.MemHLInc || s.Kind == OpKind.MemHLDec)
            {
                E("mov al, [rbp+rdx]");
                E(s.Kind == OpKind.MemHLInc ? "lea dx, [rdx+1]" : "lea dx, [rdx-1]");
                return;
            }

            // 8-bit register-to-register is a single mov.
            if (d.Kind == OpKind.Reg8 && !d.IsMemHL && s.Kind == OpKind.Reg8 && !s.IsMemHL)
            { E("mov " + R8Name((R8)d.Val) + ", " + R8Name((R8)s.Val)); return; }

            if (s.Kind == OpKind.Imm8 && (d.Kind == OpKind.Reg8 && !d.IsMemHL))
            { E("mov " + R8Name((R8)d.Val) + ", " + s.Val); return; }

            // Storing an immediate straight to memory: no courier register, so
            // `ld [hl], $50` leaves A alone the way the GB does.
            if (s.Kind == OpKind.Imm8 && d.IsMemHL)
            { E("mov byte [rbp+rdx], " + s.Val); return; }

            // Otherwise route through a courier. When the source is already a
            // plain register, use *that* register rather than al -- going via
            // al would clobber A on stores like `ld [hl], b`, which the GB
            // instruction does not touch.
            if (s.Kind == OpKind.Reg8 && !s.IsMemHL)
            { StoreOperand8(d, R8Name((R8)s.Val)); return; }

            LoadOperand8(s, "al");
            StoreOperand8(d, "al");
        }

        void EmitAlu(Instr ins)
        {
            // 16-bit: add hl, rr  (Z untouched; H from bit 11, C from bit 15)
            if (ins.A.Kind == OpKind.Reg16 && ins.B.Kind == OpKind.Reg16)
            {
                Cmt("add hl, rr - Z is preserved, so compute flags without disturbing ZF");
                E("mov si, " + R16Name((R16)ins.A.Val));
                E("mov di, " + R16Name((R16)ins.B.Val));
                E("call gb_add16");   // sets H/C in the F byte, leaves Z alone
                E("mov " + R16Name((R16)ins.A.Val) + ", si");
                _f.ZLive = false; _f.CLive = false; _f.HLive = false;
                _f.CConst = -1; _f.HConst = -1; _f.NConst = 0;
                return;
            }

            if (ins.A.Kind == OpKind.Reg16 && ins.B.Kind == OpKind.SImm8)
                throw new NotTranslatable("add sp, e8 needs the low-byte flag quirk (not yet implemented)");

            string rhs;
            if (ins.B.Kind == OpKind.Imm8) rhs = ins.B.Val.ToString();
            else if (ins.B.Kind == OpKind.Reg8 && !ins.B.IsMemHL) rhs = R8Name((R8)ins.B.Val);
            else { LoadOperand8(ins.B, "sil"); rhs = "sil"; }

            // GB carry-in ops need CF to already hold GB C.
            if ((ins.Op == Mn.Adc || ins.Op == Mn.Sbc) && !_f.CLive)
                RestoreCarryFromF();

            switch (ins.Op)
            {
                case Mn.Add: E("add al, " + rhs); _f.NativeAll(0); break;
                case Mn.Adc: E("adc al, " + rhs); _f.NativeAll(0); break;
                case Mn.Sub: E("sub al, " + rhs); _f.NativeAll(1); break;
                case Mn.Sbc: E("sbb al, " + rhs); _f.NativeAll(1); break;
                case Mn.Cp:  E("cmp al, " + rhs); _f.NativeAll(1); break;

                // Logic ops: x86 leaves AF undefined but GB defines H exactly.
                case Mn.And:
                    E("and al, " + rhs);
                    _f.ZLive = true; _f.CLive = false; _f.CConst = 0;
                    _f.HLive = false; _f.HConst = 1; _f.NConst = 0;
                    break;
                case Mn.Or:
                    E("or al, " + rhs);
                    _f.ZLive = true; _f.CLive = false; _f.CConst = 0;
                    _f.HLive = false; _f.HConst = 0; _f.NConst = 0;
                    break;
                case Mn.Xor:
                    E("xor al, " + rhs);
                    _f.ZLive = true; _f.CLive = false; _f.CConst = 0;
                    _f.HLive = false; _f.HConst = 0; _f.NConst = 0;
                    break;
            }
        }

        void EmitIncDec(Instr ins, bool inc)
        {
            // 16-bit inc/dec touch no flags at all - a straight x86 inc/dec on
            // a 16-bit register would clobber ZF, so use lea.
            if (ins.A.Kind == OpKind.Reg16)
            {
                var r = R16Name((R16)ins.A.Val);
                var w = Wide(r);
                // A 16-bit dest truncates the result and leaves the upper 48
                // bits of the host register alone, so this both wraps at $FFFF
                // and preserves the "upper bits are zero" invariant -- without
                // touching x86 flags, which `inc`/`and` would have clobbered.
                Cmt("16-bit " + (inc ? "inc" : "dec") + " affects no GB flags");
                E("lea " + r + ", [" + w + (inc ? "+1" : "-1") + "]");
                return;
            }

            // 8-bit inc/dec: GB preserves C, and so does x86 inc/dec. Exact match.
            if (ins.A.IsMemHL)
            {
                E((inc ? "inc" : "dec") + " byte [rbp+rdx]");
            }
            else
            {
                E((inc ? "inc" : "dec") + " " + R8Name((R8)ins.A.Val));
            }
            _f.ZLive = true; _f.HLive = true; _f.NConst = inc ? 0 : 1;
            // C is untouched: whatever it was, it still is.
        }

        static string Jcc(Cond c)
        {
            switch (c)
            {
                case Cond.Z: return "je";
                case Cond.NZ: return "jne";
                case Cond.C: return "jb";   // GB carry == x86 CF
                default: return "jae";
            }
        }

        void RequireLiveFlags(Cond c)
        {
            bool needZ = (c == Cond.Z || c == Cond.NZ);
            if (needZ && !_f.ZLive) throw new NotTranslatable("Z not live in x86 flags at branch");
            if (!needZ && !_f.CLive) RestoreCarryFromF();
        }

        void RestoreCarryFromF()
        {
            if (_f.CConst == 0) { E("clc"); _f.CLive = true; return; }
            if (_f.CConst == 1) { E("stc"); _f.CLive = true; return; }
            Cmt("reload GB carry into CF from the materialised F byte");
            E("bt word [gb_f], 4");   // GB F bit 4 = C
            _f.CLive = true;
        }

        void EmitJump(Instr ins)
        {
            int target = ins.BranchTarget;

            if (ins.Op == Mn.Jp && ins.A.Kind == OpKind.Reg16)
            {
                Cmt("jp hl - indirect, resolved at runtime through the dispatcher");
                E("movzx esi, dx");
                E("jmp gb_dispatch");
                return;
            }

            if (ins.IsConditional)
            {
                RequireLiveFlags((Cond)ins.A.Val);
                E(Jcc((Cond)ins.A.Val) + " " + _labelFor(target));
            }
            else
            {
                E("jmp " + _labelFor(target));
            }
        }

        void EmitCall(Instr ins)
        {
            int target = ins.BranchTarget;
            string skip = null;

            if (ins.IsConditional)
            {
                RequireLiveFlags((Cond)ins.A.Val);
                skip = _labelFor(ins.Addr) + "_nc" + ins.Addr.ToString("x4");
                // Invert the condition and skip over the call.
                var inv = (Cond)((int)(Cond)ins.A.Val ^ 1);
                E(Jcc(inv) + " " + skip);
            }

            // Dual stack: the return address is pushed onto the *GB* stack as
            // well as the native one, because GB code inspects and manipulates
            // its own stack (jump tables built from `push hl` + `ret`, and
            // routines that pop their return address to read inline data).
            Cmt("push GB return address $" + ((ins.Addr + ins.Length) & 0xFFFF).ToString("x4") + " onto the GB stack");
            E("lea r15w, [r15-2]");   // lea: GB push/call must not disturb flags
            E("mov esi, 0x" + ((ins.Addr + ins.Length) & 0xFFFF).ToString("x"));
            E("mov [rbp+r15], si");

            E("call " + _labelFor(target));

            if (skip != null) Label(skip);
            _f = FlagState.AfterCall();
        }

        void EmitRet(Instr ins)
        {
            if (ins.IsConditional)
            {
                RequireLiveFlags((Cond)ins.A.Val);
                var inv = (Cond)((int)(Cond)ins.A.Val ^ 1);
                string skip = "_ret_skip_" + ins.Addr.ToString("x4");
                E(Jcc(inv) + " " + skip);
                EmitReturnSequence();
                Label(skip);
                return;
            }

            EmitReturnSequence();
        }

        void EmitReturnSequence()
        {
            // Spill N so the caller can reconstruct F. `mov` touches no flags,
            // so Z/H/C still reach the caller intact -- which is the whole
            // point of using lea for the stack adjust.
            if (_f.NConst >= 0) E("mov byte [gb_n], " + _f.NConst);
            E("lea r15w, [r15+2]");   // drop the shadow return address
            E("ret");
        }

        void EmitPush(Instr ins)
        {
            var r = (R16)ins.A.Val;
            E("lea r15w, [r15-2]");   // lea: GB push/call must not disturb flags
            if (r == R16.AF)
            {
                MaterialiseF();
                E("mov ah, [gb_f]");
                E("mov [rbp+r15], ax");
                E("xor ah, ah");
                return;
            }
            E("mov [rbp+r15], " + R16Name(r));
        }

        void EmitPop(Instr ins)
        {
            var r = (R16)ins.A.Val;
            if (r == R16.AF)
            {
                E("mov ax, [rbp+r15]");
                E("mov [gb_f], ah");
                E("xor ah, ah");
                E("lea r15w, [r15+2]");   // lea: routines return status in the carry flag
                _f = FlagState.AllUnknown();  // flags now live in the F byte
                _f.NConst = -1;
                return;
            }
            E("mov " + R16Name(r) + ", [rbp+r15]");
            E("lea r15w, [r15+2]");   // lea: routines return status in the carry flag
        }

        // Packs the current GB flag state into the gb_f byte (bit 7=Z, 6=N, 5=H, 4=C).
        void MaterialiseF()
        {
            Cmt("materialise GB F byte (Z=7 N=6 H=5 C=4)");
            if (_f.ZLive || _f.CLive || _f.HLive)
            {
                // lahf lifts ZF/SF/AF/PF/CF into ah in one go; gb_pack_f
                // reshuffles them into GB bit order and ORs in the constant N.
                E("lahf");
                if (_f.NConst >= 0) E("mov sil, " + _f.NConst);
                else E("mov sil, [gb_n]");   // N came back from a callee
                E("call gb_pack_f");
            }
            if (!_f.HLive && _f.HConst >= 0)
                E((_f.HConst == 1 ? "or" : "and") + " byte [gb_f], " + (_f.HConst == 1 ? "0x20" : "0xdf"));
            if (!_f.CLive && _f.CConst >= 0)
                E((_f.CConst == 1 ? "or" : "and") + " byte [gb_f], " + (_f.CConst == 1 ? "0x10" : "0xef"));
        }
    }
}
