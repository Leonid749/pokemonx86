using System;

namespace Recomp.Emu
{
    // Game Boy APU, cycle-stepped.
    //
    // The previous bare-metal attempt approximated this per video frame, which
    // is far too coarse: the real frame sequencer runs at 512Hz and drives
    // length counters (256Hz), sweep (128Hz) and envelopes (64Hz) at different
    // rates. Notes have to stop by *length*, not just by envelope decay, or
    // everything blurs together.
    public sealed class Apu
    {
        public const int SampleRate = 44100;
        const int CpuHz = 4194304;

        // Duty patterns, 8 steps each.
        static readonly byte[][] Duty = {
            new byte[] { 0,0,0,0,0,0,0,1 },   // 12.5%
            new byte[] { 1,0,0,0,0,0,0,1 },   // 25%
            new byte[] { 1,0,0,0,0,1,1,1 },   // 50%
            new byte[] { 0,1,1,1,1,1,1,0 },   // 75%
        };

        static readonly int[] NoiseDivisor = { 8, 16, 32, 48, 64, 80, 96, 112 };

        readonly byte[] _reg = new byte[0x30];   // $FF10..$FF3F
        bool _powered;

        // frame sequencer
        int _fsCounter;
        int _fsStep;

        // ---- channel state ----
        sealed class Ch
        {
            public bool Enabled;
            public int Timer;
            public int DutyPos;
            public int Length;
            public bool LengthEnable;
            public int Volume;          // current envelope volume
            public int EnvPeriod, EnvTimer;
            public bool EnvUp;
            public int Freq;
        }

        readonly Ch _c1 = new Ch(), _c2 = new Ch(), _c3 = new Ch(), _c4 = new Ch();

        // sweep (channel 1 only)
        int _sweepTimer, _sweepPeriod, _sweepShift, _sweepShadow;
        bool _sweepNegate, _sweepEnabled;

        // wave
        int _wavePos;

        // noise
        int _lfsr = 0x7FFF;

        // sampling
        double _sampleAcc;
        readonly double _cyclesPerSample = (double)CpuHz / SampleRate;

        public Action<short, short> OnSample;

        byte R(int addr) { return _reg[addr - 0xFF10]; }

        // Exposed for the PC-speaker prototype: what a PIT-driven tone would
        // need to know about each channel. Volume matters only as "audible or
        // not" -- the speaker has no amplitude control.
        public bool Ch1Audible { get { return _c1.Enabled && _c1.Volume > 0 && Dac1; } }
        public bool Ch2Audible { get { return _c2.Enabled && _c2.Volume > 0 && Dac2; } }
        public bool Ch3Audible { get { return _c3.Enabled && Dac3 && ((R(0xFF1C) >> 5) & 3) != 0; } }
        public int Ch1Freq { get { return _c1.Freq; } }
        public int Ch2Freq { get { return _c2.Freq; } }
        public int Ch3Freq { get { return _c3.Freq; } }

        public void Write(int addr, byte v)
        {
            if (addr == 0xFF26)   // NR52: power control
            {
                bool on = (v & 0x80) != 0;
                if (!on && _powered) Array.Clear(_reg, 0, 0x16);   // powering off clears regs
                _powered = on;
                _reg[0x16] = (byte)(v & 0x80);
                return;
            }
            if (!_powered && addr < 0xFF30) return;   // writes ignored while off

            _reg[addr - 0xFF10] = v;

            switch (addr)
            {
                case 0xFF11: _c1.Length = 64 - (v & 0x3F); break;
                case 0xFF16: _c2.Length = 64 - (v & 0x3F); break;
                case 0xFF1B: _c3.Length = 256 - v; break;
                case 0xFF20: _c4.Length = 64 - (v & 0x3F); break;

                case 0xFF14: FreqHi(_c1, v); if ((v & 0x80) != 0) Trigger1(); break;
                case 0xFF19: FreqHi(_c2, v); if ((v & 0x80) != 0) Trigger(_c2, 0xFF17, 64); break;
                case 0xFF1E: FreqHi(_c3, v); if ((v & 0x80) != 0) Trigger3(); break;
                case 0xFF23:
                    _c4.LengthEnable = (v & 0x40) != 0;
                    if ((v & 0x80) != 0) Trigger4();
                    break;

                case 0xFF13: _c1.Freq = (_c1.Freq & 0x700) | v; break;
                case 0xFF18: _c2.Freq = (_c2.Freq & 0x700) | v; break;
                case 0xFF1D: _c3.Freq = (_c3.Freq & 0x700) | v; break;
            }
        }

        static void FreqHi(Ch c, byte v)
        {
            c.Freq = (c.Freq & 0xFF) | ((v & 7) << 8);
            c.LengthEnable = (v & 0x40) != 0;
        }

        void LoadEnvelope(Ch c, int nrx2)
        {
            byte e = R(nrx2);
            c.Volume = e >> 4;
            c.EnvUp = (e & 0x08) != 0;
            c.EnvPeriod = e & 0x07;
            c.EnvTimer = c.EnvPeriod;
        }

        void Trigger(Ch c, int nrx2, int maxLen)
        {
            c.Enabled = true;
            if (c.Length == 0) c.Length = maxLen;
            c.Timer = (2048 - c.Freq) * 4;
            LoadEnvelope(c, nrx2);
            if ((R(nrx2) & 0xF8) == 0) c.Enabled = false;   // DAC off
        }

        void Trigger1()
        {
            Trigger(_c1, 0xFF12, 64);

            byte s = R(0xFF10);
            _sweepShadow = _c1.Freq;
            _sweepPeriod = (s >> 4) & 7;
            _sweepNegate = (s & 0x08) != 0;
            _sweepShift = s & 7;
            _sweepTimer = _sweepPeriod != 0 ? _sweepPeriod : 8;
            _sweepEnabled = _sweepPeriod != 0 || _sweepShift != 0;
            if (_sweepShift != 0) SweepCalc();
        }

        void Trigger3()
        {
            _c3.Enabled = (R(0xFF1A) & 0x80) != 0;
            if (_c3.Length == 0) _c3.Length = 256;
            _c3.Timer = (2048 - _c3.Freq) * 2;
            _wavePos = 0;
        }

        void Trigger4()
        {
            _c4.Enabled = true;
            if (_c4.Length == 0) _c4.Length = 64;
            LoadEnvelope(_c4, 0xFF21);
            _lfsr = 0x7FFF;
            _c4.Timer = NoisePeriod();
            if ((R(0xFF21) & 0xF8) == 0) _c4.Enabled = false;
        }

        int NoisePeriod()
        {
            byte n = R(0xFF22);
            int d = NoiseDivisor[n & 7];
            int shift = (n >> 4) & 0x0F;
            return d << shift;
        }

        int SweepCalc()
        {
            int newFreq = _sweepShadow >> _sweepShift;
            newFreq = _sweepNegate ? _sweepShadow - newFreq : _sweepShadow + newFreq;
            if (newFreq > 2047) _c1.Enabled = false;
            return newFreq;
        }

        public void Step(int cycles)
        {
            for (int i = 0; i < cycles; i++)
            {
                // --- frame sequencer: 512Hz ---
                if (++_fsCounter >= 8192)
                {
                    _fsCounter = 0;
                    switch (_fsStep)
                    {
                        case 0: case 4: ClockLength(); break;
                        case 2: case 6: ClockLength(); ClockSweep(); break;
                        case 7: ClockEnvelope(); break;
                    }
                    _fsStep = (_fsStep + 1) & 7;
                }

                // --- channel timers ---
                if (--_c1.Timer <= 0) { _c1.Timer = (2048 - _c1.Freq) * 4; _c1.DutyPos = (_c1.DutyPos + 1) & 7; }
                if (--_c2.Timer <= 0) { _c2.Timer = (2048 - _c2.Freq) * 4; _c2.DutyPos = (_c2.DutyPos + 1) & 7; }
                if (--_c3.Timer <= 0) { _c3.Timer = (2048 - _c3.Freq) * 2; _wavePos = (_wavePos + 1) & 31; }
                if (--_c4.Timer <= 0)
                {
                    _c4.Timer = NoisePeriod();
                    int x = (_lfsr & 1) ^ ((_lfsr >> 1) & 1);
                    _lfsr = (_lfsr >> 1) | (x << 14);
                    if ((R(0xFF22) & 0x08) != 0)
                        _lfsr = (_lfsr & ~0x40) | (x << 6);
                }

                // --- emit a sample when due ---
                _sampleAcc += 1.0;
                if (_sampleAcc >= _cyclesPerSample)
                {
                    _sampleAcc -= _cyclesPerSample;
                    EmitSample();
                }
            }
        }

        void ClockLength()
        {
            ClockLen(_c1); ClockLen(_c2); ClockLen(_c3); ClockLen(_c4);
        }

        static void ClockLen(Ch c)
        {
            if (c.LengthEnable && c.Length > 0 && --c.Length == 0) c.Enabled = false;
        }

        void ClockEnvelope()
        {
            ClockEnv(_c1); ClockEnv(_c2); ClockEnv(_c4);
        }

        static void ClockEnv(Ch c)
        {
            if (c.EnvPeriod == 0) return;
            if (--c.EnvTimer > 0) return;
            c.EnvTimer = c.EnvPeriod;
            if (c.EnvUp) { if (c.Volume < 15) c.Volume++; }
            else { if (c.Volume > 0) c.Volume--; }
        }

        void ClockSweep()
        {
            if (--_sweepTimer > 0) return;
            _sweepTimer = _sweepPeriod != 0 ? _sweepPeriod : 8;
            if (!_sweepEnabled || _sweepPeriod == 0) return;

            int nf = SweepCalc();
            if (nf <= 2047 && _sweepShift != 0)
            {
                _sweepShadow = nf;
                _c1.Freq = nf;
                SweepCalc();
            }
        }

        int Ch1Out() { return _c1.Enabled ? Duty[R(0xFF11) >> 6][_c1.DutyPos] * _c1.Volume : 0; }
        int Ch2Out() { return _c2.Enabled ? Duty[R(0xFF16) >> 6][_c2.DutyPos] * _c2.Volume : 0; }

        int Ch3Out()
        {
            if (!_c3.Enabled || (R(0xFF1A) & 0x80) == 0) return 0;
            byte b = _reg[0x20 + (_wavePos >> 1)];        // $FF30 is index 0x20
            int s = (_wavePos & 1) == 0 ? (b >> 4) : (b & 0x0F);
            int level = (R(0xFF1C) >> 5) & 3;
            if (level == 0) return 0;
            return s >> (level - 1);
        }

        int Ch4Out() { return _c4.Enabled ? (~_lfsr & 1) * _c4.Volume : 0; }
        static short Clamp(int v)
        {
            if (v > 32000) return 32000;
            if (v < -32000) return -32000;
            return (short)v;
        }


        // Each channel's DAC maps digital 0..15 onto -1..+1. Summing the raw
        // unipolar values instead leaves a big DC offset that jumps whenever a
        // channel starts or stops -- audible as harsh clicking.
        static double Dac(int digital, bool dacOn)
        {
            return dacOn ? (digital / 7.5) - 1.0 : 0.0;
        }

        bool Dac1 { get { return (R(0xFF12) & 0xF8) != 0; } }
        bool Dac2 { get { return (R(0xFF17) & 0xF8) != 0; } }
        bool Dac3 { get { return (R(0xFF1A) & 0x80) != 0; } }
        bool Dac4 { get { return (R(0xFF21) & 0xF8) != 0; } }

        double _capL, _capR;

        // The DMG's output capacitor acts as a high-pass, which is what removes
        // the standing DC the DACs produce. Coefficient is the per-cycle
        // 0.999958 raised to the cycles-per-sample.
        static double HighPass(double input, ref double cap)
        {
            double outv = input - cap;
            cap = input - outv * 0.996;
            return outv;
        }

        void EmitSample()
        {
            if (OnSample == null) return;

            double[] ch = {
                Dac(Ch1Out(), Dac1), Dac(Ch2Out(), Dac2),
                Dac(Ch3Out(), Dac3), Dac(Ch4Out(), Dac4),
            };

            byte pan = R(0xFF25);
            byte vol = R(0xFF24);

            double left = 0, right = 0;
            for (int i = 0; i < 4; i++)
            {
                if ((pan & (1 << (i + 4))) != 0) left += ch[i];
                if ((pan & (1 << i)) != 0) right += ch[i];
            }

            left *= (((vol >> 4) & 7) + 1) / 8.0;    // -4..+4
            right *= ((vol & 7) + 1) / 8.0;

            left = HighPass(left, ref _capL);
            right = HighPass(right, ref _capR);

            // /4 normalises the four-channel sum; headroom left for transients.
            OnSample(Clamp((int)(left / 4.0 * 22000)), Clamp((int)(right / 4.0 * 22000)));
        }
    }
}
