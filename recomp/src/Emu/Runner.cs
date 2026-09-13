using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

namespace Recomp.Emu
{
    public static class Runner
    {
        // Classic DMG green palette, shade 0 (lightest) .. 3 (darkest).
        static readonly int[] Palette = {
            unchecked((int)0xFF9BBC0F), unchecked((int)0xFF8BAC0F),
            unchecked((int)0xFF306230), unchecked((int)0xFF0F380F),
        };

        // Emits the same one-line-per-instruction format as the bare-metal
        // build's trace_line, so the two can be diffed directly.
        public static int Trace(string[] args)
        {
            if (args.Length < 2) { Console.Error.WriteLine("usage: recomp trace <rom> [count] [out.txt]"); return 2; }
            int count = args.Length > 2 ? int.Parse(args[2]) : 400;
            string outPath = args.Length > 3 ? args[3] : null;

            var bus = new Bus(File.ReadAllBytes(args[1]));
            var ppu = new Ppu(bus);
            bus.Ppu = ppu;
            var cpu = new Cpu(bus);
            cpu.Reset();

            var sb = new System.Text.StringBuilder();
            for (int i = 0; i < count; i++)
            {
                sb.AppendFormat("{0:x4} {1:x2}{2:x2} {3:x2}{4:x2} {5:x2}{6:x2} {7:x2}{8:x2} {9:x4}\r\n",
                    cpu.PC, cpu.A, cpu.F, cpu.B, cpu.C, cpu.D, cpu.E, cpu.H, cpu.L, cpu.SP);
                int cyc = cpu.Step();
                ppu.Tick(cyc);
            }

            if (outPath != null) { File.WriteAllText(outPath, sb.ToString()); Console.WriteLine("wrote " + outPath); }
            else Console.Write(sb.ToString());
            return 0;
        }

        // Renders the game's audio to a WAV so it can be judged by ear without
        // booting hardware. Skips ahead past the silent copyright screen.
        public static int Wav(string[] args)
        {
            if (args.Length < 2) { Console.Error.WriteLine("usage: recomp wav <rom> [seconds] [skipFrames] [out.wav]"); return 2; }
            int seconds = args.Length > 2 ? int.Parse(args[2]) : 20;
            int skipFrames = args.Length > 3 ? int.Parse(args[3]) : 260;
            string outPath = args.Length > 4 ? args[4] : "sound.wav";

            var bus = new Bus(File.ReadAllBytes(args[1]));
            var ppu = new Ppu(bus);
            var apu = new Apu();
            bus.Ppu = ppu;
            bus.Apu = apu;
            var cpu = new Cpu(bus);
            cpu.Reset();

            var pcm = new System.IO.MemoryStream();
            bool recording = false;
            apu.OnSample = (l, r) =>
            {
                if (!recording) return;
                pcm.WriteByte((byte)(l & 0xFF)); pcm.WriteByte((byte)((l >> 8) & 0xFF));
                pcm.WriteByte((byte)(r & 0xFF)); pcm.WriteByte((byte)((r >> 8) & 0xFF));
            };

            long targetSamples = (long)seconds * Apu.SampleRate;
            while (ppu.FramesDone < skipFrames)
            {
                int c = cpu.Step(); ppu.Tick(c); apu.Step(c);
            }
            recording = true;
            while (pcm.Length < targetSamples * 4)
            {
                int c = cpu.Step(); ppu.Tick(c); apu.Step(c);
            }

            WriteWav(outPath, pcm.ToArray(), Apu.SampleRate, 2);
            Console.WriteLine("wrote {0} ({1:0.0}s stereo @ {2}Hz)", outPath, pcm.Length / 4.0 / Apu.SampleRate, Apu.SampleRate);
            return 0;
        }

        // Simulates the bare-metal output stage exactly: quantise to the same
        // 0..255 byte the assembly produces, run the same delta-sigma at
        // PWM_HZ, then low-pass the 1-bit stream the way a speaker cone does.
        // The resulting WAV is what the physical speaker would actually emit.
        public static int PwmWav(string[] args)
        {
            if (args.Length < 2) { Console.Error.WriteLine("usage: recomp pwmwav <rom> [seconds] [skipFrames] [out.wav]"); return 2; }
            int seconds = args.Length > 2 ? int.Parse(args[2]) : 20;
            int skipFrames = args.Length > 3 ? int.Parse(args[3]) : 300;
            string outPath = args.Length > 4 ? args[4] : "sound-pwm.wav";

            const int SampleHz = 32000;    // must match apu.asm
            const int PwmHz = 256000;
            const int Slots = PwmHz / SampleHz;

            var bus = new Bus(File.ReadAllBytes(args[1]));
            var ppu = new Ppu(bus);
            var apu = new Apu();
            bus.Ppu = ppu; bus.Apu = apu;
            var cpu = new Cpu(bus);
            cpu.Reset();

            var pcm = new System.IO.MemoryStream();
            bool recording = false;

            int dsig = 0;
            double lp = 0.0;                       // speaker cone low-pass
            double outAcc = 0; int outCount = 0;
            // 1-pole RC at roughly 6kHz against the 256kHz bit rate
            const double A = 0.12;
            int emitEvery = PwmHz / 44100;
            int emitCounter = 0;

            apu.OnSample = (l, r) =>
            {
                if (!recording) return;

                // Mirror the assembly's quantisation: the asm channel sum is
                // 15x the C# one, and it shifts >>7 after the 8.8 scale.
                int b = 128 + (int)(l / 22000.0 * 4.0 * 30.0);
                if (b < 0) b = 0; if (b > 255) b = 255;

                for (int s = 0; s < Slots; s++)
                {
                    dsig += b;
                    int bit = 0;
                    if (dsig >= 256) { dsig -= 256; bit = 1; }

                    lp += A * (bit - lp);          // cone response

                    if (++emitCounter >= emitEvery)
                    {
                        emitCounter = 0;
                        double v = (lp - 0.5) * 2.0 * 26000.0;
                        short sv = v > 32000 ? (short)32000 : v < -32000 ? (short)-32000 : (short)v;
                        pcm.WriteByte((byte)(sv & 0xFF));
                        pcm.WriteByte((byte)((sv >> 8) & 0xFF));
                    }
                }
                outAcc += 0; outCount++;
            };

            while (ppu.FramesDone < skipFrames) { int c = cpu.Step(); ppu.Tick(c); apu.Step(c); }
            recording = true;
            long target = (long)seconds * 44100 * 2;
            while (pcm.Length < target) { int c = cpu.Step(); ppu.Tick(c); apu.Step(c); }

            WriteWav(outPath, pcm.ToArray(), 44100, 1);
            Console.WriteLine("wrote {0} — simulated PC speaker output ({1} slots/sample, carrier {2}Hz)",
                              outPath, Slots, SampleHz);
            return 0;
        }

        public static void WriteWavPublic(string p, byte[] d, int rate, int ch) { WriteWav(p, d, rate, ch); }

        static void WriteWav(string path, byte[] pcm, int rate, int channels)
        {
            using (var fs = new FileStream(path, FileMode.Create))
            using (var w = new BinaryWriter(fs))
            {
                int byteRate = rate * channels * 2;
                w.Write(new[] { 'R', 'I', 'F', 'F' });
                w.Write(36 + pcm.Length);
                w.Write(new[] { 'W', 'A', 'V', 'E' });
                w.Write(new[] { 'f', 'm', 't', ' ' });
                w.Write(16);
                w.Write((short)1);                 // PCM
                w.Write((short)channels);
                w.Write(rate);
                w.Write(byteRate);
                w.Write((short)(channels * 2));    // block align
                w.Write((short)16);                // bits per sample
                w.Write(new[] { 'd', 'a', 't', 'a' });
                w.Write(pcm.Length);
                w.Write(pcm);
            }
        }

        public static int Run(string[] args)
        {
            if (args.Length < 2)
            {
                Console.Error.WriteLine("usage: recomp run <rom.gbc> [frames] [out.png]");
                return 2;
            }

            string romPath = args[1];
            int frames = args.Length > 2 ? int.Parse(args[2]) : 60;
            string outPng = args.Length > 3 ? args[3] : "frame.png";

            var rom = File.ReadAllBytes(romPath);
            var bus = new Bus(rom);
            var ppu = new Ppu(bus);
            bus.Ppu = ppu;
            var cpu = new Cpu(bus);
            cpu.Reset();

            long steps = 0;
            long divAcc = 0;
            var sw = System.Diagnostics.Stopwatch.StartNew();

            try
            {
                while (ppu.FramesDone < frames)
                {
                    int cyc = cpu.Step();
                    ppu.Tick(cyc);

                    // DIV ticks at 16384Hz = every 256 t-cycles.
                    divAcc += cyc;
                    while (divAcc >= 256) { divAcc -= 256; bus.Io[0x04]++; }

                    if (++steps > 400_000_000L)
                    {
                        Console.Error.WriteLine("step limit hit at frame " + ppu.FramesDone);
                        break;
                    }
                }
            }
            catch (Exception e)
            {
                Console.Error.WriteLine("CPU fault at PC=$" + cpu.PC.ToString("x4")
                                        + " bank=" + bus.RomBank + " after " + steps + " steps");
                Console.Error.WriteLine("  " + e.Message);
                Dump(ppu, outPng);
                return 1;
            }

            sw.Stop();
            Console.WriteLine("ran {0} frames, {1} instructions in {2} ms", ppu.FramesDone, steps, sw.ElapsedMilliseconds);
            Console.WriteLine("  PC=${0:x4} bank={1} LCDC=${2:x2} LY={3}",
                              cpu.PC, bus.RomBank, bus.Io[0x40], ppu.Ly);

            Dump(ppu, outPng);
            Console.WriteLine("wrote " + outPng);
            return 0;
        }

        static void Dump(Ppu ppu, string path)
        {
            const int scale = 3;
            using (var bmp = new Bitmap(Ppu.W * scale, Ppu.Hgt * scale, PixelFormat.Format32bppArgb))
            {
                var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
                var bits = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                var row = new int[bmp.Width];
                for (int y = 0; y < bmp.Height; y++)
                {
                    int sy = y / scale;
                    for (int x = 0; x < bmp.Width; x++)
                        row[x] = Palette[ppu.Frame[sy * Ppu.W + x / scale] & 3];
                    System.Runtime.InteropServices.Marshal.Copy(
                        row, 0, bits.Scan0 + y * bits.Stride, row.Length);
                }
                bmp.UnlockBits(bits);
                bmp.Save(path, ImageFormat.Png);
            }
        }
    }
}
