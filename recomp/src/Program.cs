using System;
using System.IO;
using Recomp.Sm83;

namespace Recomp
{
    public static class Program
    {
        public static int Main(string[] args)
        {
            if (args.Length == 0) { Usage(); return 2; }

            switch (args[0])
            {
                case "selftest":
                    {
                        int rc = SelfTest.Run();
                        rc |= Tools.PkmnCompress.RoundTripTest();
                        return rc;
                    }

                case "pkmncompress":
                    return Tools.PkmnCompress.Run(args);

                case "gfx":
                    return Tools.GfxTool.Run(args);

                case "run":
                    return Emu.Runner.Run(args);
                case "wav":
                    return Emu.Runner.Wav(args);
                case "pwmwav":
                    return Emu.Runner.PwmWav(args);
                case "tonewav":
                    return Emu.SpeakerSim.Run(args);




                case "trace":
                    return Emu.Runner.Trace(args);

                case "disasm":
                    return Disasm(args);

                case "translate":
                    return Translate(args);

                default:
                    Console.Error.WriteLine("unknown command: " + args[0]);
                    Usage();
                    return 2;
            }
        }

        static int Disasm(string[] args)
        {
            if (args.Length < 2) { Console.Error.WriteLine("disasm <file.gb> [start] [count]"); return 2; }
            var rom = File.ReadAllBytes(args[1]);
            int start = args.Length > 2 ? Convert.ToInt32(args[2], 16) : 0x150;
            int count = args.Length > 3 ? int.Parse(args[3]) : 32;

            var mem = new Decoder.ArrayMem(rom);
            int pc = start;
            for (int i = 0; i < count; i++)
            {
                var ins = Decoder.Decode(mem, pc);
                Console.WriteLine("{0:x4}  {1,-9}  {2}", pc, Hex(ins.Bytes), ins);
                pc += ins.Length;
            }
            return 0;
        }

        // translate <hexbytes> [org] -- e.g. translate f044fe9038fa 0150
        static int Translate(string[] args)
        {
            if (args.Length < 2) { Console.Error.WriteLine("translate <hexbytes> [org]"); return 2; }
            var hex = args[1].Replace(" ", "");
            var bytes = new byte[hex.Length / 2];
            for (int i = 0; i < bytes.Length; i++)
                bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);

            int org = args.Length > 2 ? Convert.ToInt32(args[2], 16) : 0x0150;
            var mem = new Decoder.ArrayMem(bytes, org);
            var em = new X86.Emitter(a => "gb_" + a.ToString("x4"));

            em.Label("gb_" + org.ToString("x4"));
            int pc = org;
            int end = org + bytes.Length;
            try
            {
                while (pc < end)
                {
                    var ins = Decoder.Decode(mem, pc);
                    em.Emit(ins);
                    pc += ins.Length;
                }
            }
            catch (X86.NotTranslatable e)
            {
                Console.Write(em.Text);
                Console.Error.WriteLine("\n!! " + e.Message);
                return 1;
            }

            Console.Write(em.Text);
            return 0;
        }

        static string Hex(byte[] b)
        {
            var s = "";
            foreach (var x in b) s += x.ToString("x2") + " ";
            return s.TrimEnd();
        }

        static void Usage()
        {
            Console.Error.WriteLine("usage: recomp <command>");
            Console.Error.WriteLine("  selftest              verify the SM83 decoder");
            Console.Error.WriteLine("  disasm <rom> [a] [n]  disassemble n instructions at hex address a");
        }
    }
}
