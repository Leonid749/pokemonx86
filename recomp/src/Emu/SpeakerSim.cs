using System;
using System.IO;

namespace Recomp.Emu
{
    // Simulates the PC speaker driven by the PIT, so a change can be judged by
    // ear before any of it is written in assembly.
    //
    // The PIT can only produce a 50% square at one frequency, full amplitude,
    // no volume control. Timesharing rotates it between the audible channels
    // fast enough that the ear fuses them into a chord -- the ZX Spectrum
    // trick. Reprogramming the divisor restarts the counter, so every swap is
    // a phase discontinuity; that artefact is modelled here rather than
    // glossed over, because it is exactly what could make this sound worse.
    public static class SpeakerSim
    {
        const int Rate = 44100;
        const short Amp = 9000;

        public static int Run(string[] args)
        {
            if (args.Length < 2)
            {
                Console.Error.WriteLine("usage: recomp tonewav <rom> [seconds] [skipFrames] [mode] [swapHz] [out.wav]");
                Console.Error.WriteLine("  mode 1 = current (CH1, falling back to CH2)");
                Console.Error.WriteLine("  mode 2 = timeshare CH1+CH2");
                Console.Error.WriteLine("  mode 3 = timeshare CH1+CH2+CH3 (adds bass)");
                return 2;
            }

            int seconds = args.Length > 2 ? int.Parse(args[2]) : 20;
            int skip = args.Length > 3 ? int.Parse(args[3]) : 700;
            int mode = args.Length > 4 ? int.Parse(args[4]) : 2;
            int swapHz = args.Length > 5 ? int.Parse(args[5]) : 150;
            string outPath = args.Length > 6 ? args[6] : "tone.wav";

            var bus = new Bus(File.ReadAllBytes(args[1]));
            var ppu = new Ppu(bus);
            var apu = new Apu();
            bus.Ppu = ppu; bus.Apu = apu;
            var cpu = new Cpu(bus);
            cpu.Reset();

            var pcm = new MemoryStream();
            bool recording = false;

            double phase = 0;          // square wave phase, 0..1
            int voice = 0;             // which channel currently owns the PIT
            int swapCounter = 0;
            int swapPeriod = Rate / swapHz;
            int emitEvery = Apu.SampleRate / Rate;   // APU runs at 44100 too
            int emitCounter = 0;

            apu.OnSample = (l, r) =>
            {
                if (!recording) return;
                if (++emitCounter < emitEvery) return;
                emitCounter = 0;

                // Rotate the PIT between whichever channels are audible.
                if (mode > 1 && --swapCounter <= 0)
                {
                    swapCounter = swapPeriod;
                    int limit = mode >= 3 ? 3 : 2;
                    for (int i = 0; i < limit; i++)
                    {
                        voice = (voice + 1) % limit;
                        if (Audible(apu, voice)) break;
                    }
                    phase = 0;         // the counter restart: a real discontinuity
                }

                int chosen = -1;
                if (mode == 1)
                {
                    if (apu.Ch1Audible) chosen = 0;
                    else if (apu.Ch2Audible) chosen = 1;
                }
                else if (Audible(apu, voice)) chosen = voice;

                short s = 0;
                if (chosen >= 0)
                {
                    double f = FreqHz(apu, chosen);
                    if (f > 20 && f < 12000)
                    {
                        phase += f / Rate;
                        if (phase >= 1.0) phase -= 1.0;
                        s = phase < 0.5 ? Amp : (short)-Amp;
                    }
                }

                pcm.WriteByte((byte)(s & 0xFF));
                pcm.WriteByte((byte)((s >> 8) & 0xFF));
            };

            while (ppu.FramesDone < skip) { int c = cpu.Step(); ppu.Tick(c); apu.Step(c); }
            recording = true;
            long target = (long)seconds * Rate * 2;
            while (pcm.Length < target) { int c = cpu.Step(); ppu.Tick(c); apu.Step(c); }

            Runner.WriteWavPublic(outPath, pcm.ToArray(), Rate, 1);
            Console.WriteLine("wrote {0}  (mode {1}, swap {2}Hz)", outPath, mode, swapHz);
            return 0;
        }

        static bool Audible(Apu a, int ch)
        {
            switch (ch) { case 0: return a.Ch1Audible; case 1: return a.Ch2Audible; default: return a.Ch3Audible; }
        }

        static double FreqHz(Apu a, int ch)
        {
            // Pulse channels: 131072/(2048-x). The wave channel is half that.
            switch (ch)
            {
                case 0: return 131072.0 / (2048 - a.Ch1Freq);
                case 1: return 131072.0 / (2048 - a.Ch2Freq);
                default: return 65536.0 / (2048 - a.Ch3Freq);
            }
        }
    }
}
