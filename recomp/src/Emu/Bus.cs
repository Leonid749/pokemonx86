using System;

namespace Recomp.Emu
{
    // GB address space + MBC3 banking.
    //
    // Pokemon Red is MBC3+RAM+BATTERY (per the rgbfix flags in the Makefile):
    // 1MB ROM = 64 banks of 16KB, 32KB SRAM = 4 banks of 8KB.
    public sealed class Bus
    {
        public readonly byte[] Rom;
        public readonly byte[] Vram = new byte[0x2000];
        public readonly byte[] Wram = new byte[0x2000];
        public readonly byte[] Oam = new byte[0xA0];
        public readonly byte[] Hram = new byte[0x7F];
        public readonly byte[] Io = new byte[0x80];
        public readonly byte[] Sram = new byte[0x8000];
        public byte Ie;

        int _romBank = 1;
        int _sramBank;
        bool _sramEnable;

        public Ppu Ppu;
        public Apu Apu;

        // Joypad: bit set = pressed. Low nibble dpad, high nibble buttons.
        public byte Buttons;   // Start Select B A
        public byte Dpad;      // Down Up Left Right

        public Bus(byte[] rom) { Rom = rom; }

        public int RomBank { get { return _romBank; } }

        public byte Read(int a)
        {
            a &= 0xFFFF;
            if (a < 0x4000) return Rom[a];
            if (a < 0x8000)
            {
                int off = _romBank * 0x4000 + (a - 0x4000);
                return off < Rom.Length ? Rom[off] : (byte)0xFF;
            }
            if (a < 0xA000) return Vram[a - 0x8000];
            if (a < 0xC000)
            {
                if (!_sramEnable) return 0xFF;
                int off = _sramBank * 0x2000 + (a - 0xA000);
                return off < Sram.Length ? Sram[off] : (byte)0xFF;
            }
            if (a < 0xE000) return Wram[a - 0xC000];
            if (a < 0xFE00) return Wram[a - 0xE000];        // echo
            if (a < 0xFEA0) return Oam[a - 0xFE00];
            if (a < 0xFF00) return 0xFF;                     // unusable
            if (a < 0xFF80) return ReadIo(a);
            if (a < 0xFFFF) return Hram[a - 0xFF80];
            return Ie;
        }

        byte ReadIo(int a)
        {
            switch (a)
            {
                case 0xFF00: return ReadJoypad();
                case 0xFF44: return Ppu != null ? (byte)Ppu.Ly : (byte)0;
                case 0xFF41: return Ppu != null ? Ppu.Stat : (byte)0;
                default: return Io[a - 0xFF00];
            }
        }

        // P1: bit 4 selects dpad, bit 5 selects buttons; 0 = pressed.
        byte ReadJoypad()
        {
            byte sel = Io[0x00];
            int res = 0x0F;
            if ((sel & 0x10) == 0) res &= ~Dpad & 0x0F;
            if ((sel & 0x20) == 0) res &= ~Buttons & 0x0F;
            return (byte)((sel & 0x30) | res | 0xC0);
        }

        public void Write(int a, byte v)
        {
            a &= 0xFFFF;

            if (a < 0x8000) { WriteMbc(a, v); return; }
            if (a < 0xA000) { Vram[a - 0x8000] = v; return; }
            if (a < 0xC000)
            {
                if (!_sramEnable) return;
                int off = _sramBank * 0x2000 + (a - 0xA000);
                if (off < Sram.Length) Sram[off] = v;
                return;
            }
            if (a < 0xE000) { Wram[a - 0xC000] = v; return; }
            if (a < 0xFE00) { Wram[a - 0xE000] = v; return; }
            if (a < 0xFEA0) { Oam[a - 0xFE00] = v; return; }
            if (a < 0xFF00) return;
            if (a < 0xFF80) { WriteIo(a, v); return; }
            if (a < 0xFFFF) { Hram[a - 0xFF80] = v; return; }
            Ie = v;
        }

        void WriteMbc(int a, byte v)
        {
            if (a < 0x2000) { _sramEnable = (v & 0x0F) == 0x0A; return; }
            if (a < 0x4000)
            {
                int b = v & 0x7F;
                _romBank = b == 0 ? 1 : b;   // MBC3 maps bank 0 to 1
                return;
            }
            if (a < 0x6000)
            {
                if (v <= 0x03) _sramBank = v;   // >0x03 selects RTC registers
                return;
            }
            // 0x6000-0x7FFF: RTC latch. Pokemon Red has no RTC.
        }

        void WriteIo(int a, byte v)
        {
            switch (a)
            {
                case 0xFF46:   // OAM DMA: copy 160 bytes from v*0x100
                    {
                        int srcBase = v << 8;
                        for (int i = 0; i < 0xA0; i++) Oam[i] = Read(srcBase + i);
                        Io[0x46] = v;
                        return;
                    }
                case 0xFF44:   // LY is read-only; writing resets it
                    if (Ppu != null) Ppu.ResetLy();
                    return;
                default:
                    Io[a - 0xFF00] = v;
                    // Sound registers and wave RAM also go to the APU, which
                    // needs to see triggers, not just the final register value.
                    if (a >= 0xFF10 && a <= 0xFF3F && Apu != null) Apu.Write(a, v);
                    return;
            }
        }

        public byte If
        {
            get { return Io[0x0F]; }
            set { Io[0x0F] = value; }
        }

        public void RequestInterrupt(int bit) { Io[0x0F] |= (byte)(1 << bit); }
    }
}
