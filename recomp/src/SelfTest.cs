using System;
using System.Collections.Generic;
using Recomp.Sm83;

namespace Recomp
{
    // Verifies the decoder against reference length/cycle tables transcribed
    // independently from the SM83 opcode map. If the decoder and these tables
    // disagree, one of them is wrong and the build should fail loudly.
    public static class SelfTest
    {
        // t-cycles, branch-taken. 0 = invalid opcode.
        static readonly int[] RefCycles = {
        //  0   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F
            4, 12,  8,  8,  4,  4,  8,  4, 20,  8,  8,  8,  4,  4,  8,  4, // 0
            4, 12,  8,  8,  4,  4,  8,  4, 12,  8,  8,  8,  4,  4,  8,  4, // 1
           12, 12,  8,  8,  4,  4,  8,  4, 12,  8,  8,  8,  4,  4,  8,  4, // 2
           12, 12,  8,  8, 12, 12, 12,  4, 12,  8,  8,  8,  4,  4,  8,  4, // 3
            4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8,  4, // 4
            4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8,  4, // 5
            4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8,  4, // 6
            8,  8,  8,  8,  8,  8,  4,  8,  4,  4,  4,  4,  4,  4,  8,  4, // 7
            4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8,  4, // 8
            4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8,  4, // 9
            4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8,  4, // A
            4,  4,  4,  4,  4,  4,  8,  4,  4,  4,  4,  4,  4,  4,  8,  4, // B
           20, 12, 16, 16, 24, 16,  8, 16, 20, 16, 16,  8, 24, 24,  8, 16, // C
           20, 12, 16,  0, 24, 16,  8, 16, 20, 16, 16,  0, 24,  0,  8, 16, // D
           12, 12,  8,  0,  0, 16,  8, 16, 16,  4, 16,  0,  0,  0,  8, 16, // E
           12, 12,  8,  4,  0, 16,  8, 16, 12,  8, 16,  4,  0,  0,  8, 16, // F
        };

        // Instruction length in bytes (0xCB counted as 2, incl. prefix).
        static readonly int[] RefLen = {
            1, 3, 1, 1, 1, 1, 2, 1, 3, 1, 1, 1, 1, 1, 2, 1, // 0
            2, 3, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1, // 1
            2, 3, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1, // 2
            2, 3, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 1, // 3
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 4
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 5
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 6
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 7
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 8
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 9
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // A
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // B
            1, 1, 3, 3, 3, 1, 2, 1, 1, 1, 3, 2, 3, 3, 2, 1, // C
            1, 1, 3, 0, 3, 1, 2, 1, 1, 1, 3, 0, 3, 0, 2, 1, // D
            2, 1, 1, 0, 0, 1, 2, 1, 2, 1, 3, 0, 0, 0, 2, 1, // E
            2, 1, 1, 1, 0, 1, 2, 1, 2, 1, 3, 1, 0, 0, 2, 1, // F
        };

        static readonly int[] InvalidOps = { 0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD };

        public static int Run()
        {
            var fails = new List<string>();

            // Decode every base opcode with distinguishable operand bytes.
            for (int op = 0; op < 256; op++)
            {
                if (op == 0xCB) continue; // covered separately
                var mem = new Decoder.ArrayMem(new byte[] { (byte)op, 0x34, 0x12 });
                var ins = Decoder.Decode(mem, 0);

                bool shouldBeInvalid = Array.IndexOf(InvalidOps, op) >= 0;
                if (shouldBeInvalid)
                {
                    if (ins.Op != Mn.Invalid)
                        fails.Add(Hex(op) + ": expected Invalid, got '" + ins + "'");
                    continue;
                }

                if (ins.Op == Mn.Invalid)
                { fails.Add(Hex(op) + ": unexpectedly Invalid"); continue; }

                if (ins.Length != RefLen[op])
                    fails.Add(Hex(op) + " '" + ins + "': length " + ins.Length + " != ref " + RefLen[op]);
                if (ins.Cycles != RefCycles[op])
                    fails.Add(Hex(op) + " '" + ins + "': cycles " + ins.Cycles + " != ref " + RefCycles[op]);
            }

            // The whole CB page: always 2 bytes; 8/12/16 cycles.
            for (int cb = 0; cb < 256; cb++)
            {
                var mem = new Decoder.ArrayMem(new byte[] { 0xCB, (byte)cb });
                var ins = Decoder.Decode(mem, 0);
                bool hl = (cb & 7) == 6;
                bool isBit = (cb >> 6) == 1;
                int expect = hl ? (isBit ? 12 : 16) : 8;

                if (ins.Length != 2) fails.Add("CB " + Hex(cb) + ": length " + ins.Length + " != 2");
                if (ins.Cycles != expect) fails.Add("CB " + Hex(cb) + " '" + ins + "': cycles " + ins.Cycles + " != " + expect);
                if (ins.Op == Mn.Invalid) fails.Add("CB " + Hex(cb) + ": Invalid (CB page has no holes)");
            }

            // Spot-checks on the SM83-specific encodings that differ from Z80.
            CheckText(fails, new byte[] { 0x08, 0x00, 0xC0 }, "ld [$c000], sp");
            CheckText(fails, new byte[] { 0x22 }, "ld [hl+], a");
            CheckText(fails, new byte[] { 0x3A }, "ld a, [hl-]");
            CheckText(fails, new byte[] { 0xE0, 0x40 }, "ldh [$ff40], a");
            CheckText(fails, new byte[] { 0xF0, 0x44 }, "ldh a, [$ff44]");
            CheckText(fails, new byte[] { 0xE2 }, "ldh [$ff00+c], a");
            CheckText(fails, new byte[] { 0xE8, 0xFE }, "add sp, -$02");
            CheckText(fails, new byte[] { 0xF8, 0x10 }, "ld hl, sp+$10");
            CheckText(fails, new byte[] { 0xE9 }, "jp hl");
            CheckText(fails, new byte[] { 0x76 }, "halt");
            CheckText(fails, new byte[] { 0xCB, 0x37 }, "swap a");
            CheckText(fails, new byte[] { 0xCB, 0x7E }, "bit 7, [hl]");
            CheckText(fails, new byte[] { 0xFF }, "rst $38");
            CheckText(fails, new byte[] { 0x18, 0xFE }, "jr -$02");

            // Branch target arithmetic: jr is relative to the *next* instruction.
            var jr = Decoder.Decode(new Decoder.ArrayMem(new byte[] { 0x18, 0x05 }, 0x1000), 0x1000);
            if (jr.BranchTarget != 0x1007)
                fails.Add("jr $05 at $1000: target $" + jr.BranchTarget.ToString("x4") + " != $1007");

            var jrb = Decoder.Decode(new Decoder.ArrayMem(new byte[] { 0x20, 0xFB }, 0x2000), 0x2000);
            if (jrb.BranchTarget != 0x1FFD)
                fails.Add("jr nz,-5 at $2000: target $" + jrb.BranchTarget.ToString("x4") + " != $1FFD");

            // Control-flow classification.
            Expect(fails, "ret falls through", !Dec(0xC9).FallsThrough);
            Expect(fails, "ret nz falls through", Dec(0xC0).FallsThrough);
            Expect(fails, "jp a16 does not fall through", !Dec(0xC3).FallsThrough);
            Expect(fails, "call falls through", Dec(0xCD).FallsThrough);
            Expect(fails, "reti does not fall through", !Dec(0xD9).FallsThrough);

            Console.WriteLine("decoder self-test: 244 base opcodes + 11 invalid + 256 CB "
                              + "= 511 encodings checked against reference tables");
            if (fails.Count == 0) { Console.WriteLine("PASS"); return 0; }

            Console.WriteLine("FAIL (" + fails.Count + "):");
            foreach (var f in fails) Console.WriteLine("  " + f);
            return 1;
        }

        static Instr Dec(params byte[] b) { return Decoder.Decode(new Decoder.ArrayMem(b), 0); }

        static void CheckText(List<string> fails, byte[] bytes, string expect)
        {
            var got = Decoder.Decode(new Decoder.ArrayMem(bytes), 0).ToString();
            if (got != expect) fails.Add("disasm: got '" + got + "' expected '" + expect + "'");
        }

        static void Expect(List<string> fails, string what, bool cond)
        {
            if (!cond) fails.Add("invariant: " + what);
        }

        static string Hex(int v) { return "$" + v.ToString("x2"); }
    }
}
