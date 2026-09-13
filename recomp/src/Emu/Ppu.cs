using System;

namespace Recomp.Emu
{
    // DMG PPU: background, window and sprites, rendered per scanline so that
    // mid-frame SCX/SCY/palette changes behave.
    //
    // Timing per line is 456 t-cycles; 144 visible lines then 10 of VBlank.
    // The VBlank interrupt at LY=144 is what releases DelayFrame's halt loop --
    // without it the game hangs forever and nothing renders.
    public sealed class Ppu
    {
        public const int W = 160, Hgt = 144;
        const int CyclesPerLine = 456;
        const int VisibleLines = 144;
        const int TotalLines = 154;

        public readonly byte[] Frame = new byte[W * Hgt];   // shade 0..3
        public int Ly;
        public long FramesDone;

        readonly Bus _bus;
        int _dot;
        int _windowLine;

        public Ppu(Bus bus) { _bus = bus; }

        byte Io(int a) { return _bus.Io[a - 0xFF00]; }

        byte Lcdc { get { return Io(0xFF40); } }
        bool LcdOn { get { return (Lcdc & 0x80) != 0; } }

        public byte Stat
        {
            get
            {
                int mode;
                if (Ly >= VisibleLines) mode = 1;
                else if (_dot < 80) mode = 2;
                else if (_dot < 252) mode = 3;
                else mode = 0;
                int lyc = Io(0xFF45) == Ly ? 0x04 : 0;
                return (byte)((Io(0xFF41) & 0xF8) | lyc | mode);
            }
        }

        public void ResetLy() { Ly = 0; _dot = 0; _windowLine = 0; }

        public void Tick(int cycles)
        {
            if (!LcdOn)
            {
                // LCD off: LY reads 0 and no interrupts fire.
                Ly = 0; _dot = 0; _windowLine = 0;
                return;
            }

            _dot += cycles;
            while (_dot >= CyclesPerLine)
            {
                _dot -= CyclesPerLine;

                if (Ly < VisibleLines) RenderScanline(Ly);

                Ly++;
                if (Ly == VisibleLines)
                {
                    _bus.RequestInterrupt(0);      // VBlank
                    FramesDone++;
                }
                if ((Io(0xFF41) & 0x40) != 0 && Io(0xFF45) == Ly)
                    _bus.RequestInterrupt(1);      // STAT LY=LYC

                if (Ly >= TotalLines) { Ly = 0; _windowLine = 0; }
            }
        }

        static int Shade(byte palette, int color) { return (palette >> (color * 2)) & 3; }

        void RenderScanline(int ly)
        {
            var vram = _bus.Vram;
            byte lcdc = Lcdc;
            int rowBase = ly * W;

            // ---- background ----
            bool bgOn = (lcdc & 0x01) != 0;
            byte scy = Io(0xFF42), scx = Io(0xFF43), bgp = Io(0xFF47);
            int bgMap = (lcdc & 0x08) != 0 ? 0x1C00 : 0x1800;   // vram-relative
            bool unsignedTiles = (lcdc & 0x10) != 0;

            // Per-pixel BG colour index, kept for sprite priority.
            var bgColor = new int[W];

            if (bgOn)
            {
                int y = (ly + scy) & 0xFF;
                int tileRow = (y >> 3) * 32;
                int inTileY = y & 7;
                for (int x = 0; x < W; x++)
                {
                    int bx = (x + scx) & 0xFF;
                    int idx = vram[bgMap + tileRow + (bx >> 3)];
                    int dataAddr = unsignedTiles ? idx * 16 : 0x1000 + (sbyte)idx * 16;
                    byte lo = vram[dataAddr + inTileY * 2];
                    byte hi = vram[dataAddr + inTileY * 2 + 1];
                    int bit = 7 - (bx & 7);
                    int c = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
                    bgColor[x] = c;
                    Frame[rowBase + x] = (byte)Shade(bgp, c);
                }
            }
            else
            {
                for (int x = 0; x < W; x++) { bgColor[x] = 0; Frame[rowBase + x] = 0; }
            }

            // ---- window ----
            bool winOn = (lcdc & 0x20) != 0;
            byte wy = Io(0xFF4A), wx = Io(0xFF4B);
            if (winOn && ly >= wy && wx < 167)
            {
                int winMap = (lcdc & 0x40) != 0 ? 0x1C00 : 0x1800;
                int wline = _windowLine;
                int tileRow = (wline >> 3) * 32;
                int inTileY = wline & 7;
                bool drew = false;

                for (int x = 0; x < W; x++)
                {
                    int wxPix = x - (wx - 7);
                    if (wxPix < 0) continue;
                    drew = true;
                    int idx = vram[winMap + tileRow + (wxPix >> 3)];
                    int dataAddr = unsignedTiles ? idx * 16 : 0x1000 + (sbyte)idx * 16;
                    byte lo = vram[dataAddr + inTileY * 2];
                    byte hi = vram[dataAddr + inTileY * 2 + 1];
                    int bit = 7 - (wxPix & 7);
                    int c = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
                    bgColor[x] = c;
                    Frame[rowBase + x] = (byte)Shade(bgp, c);
                }
                if (drew) _windowLine++;
            }

            // ---- sprites ----
            if ((lcdc & 0x02) == 0) return;

            int spriteH = (lcdc & 0x04) != 0 ? 16 : 8;
            var oam = _bus.Oam;
            int drawn = 0;

            for (int i = 0; i < 40 && drawn < 10; i++)   // hardware limit: 10 per line
            {
                int sy = oam[i * 4] - 16;
                int sx = oam[i * 4 + 1] - 8;
                int tile = oam[i * 4 + 2];
                int attr = oam[i * 4 + 3];

                if (ly < sy || ly >= sy + spriteH) continue;
                drawn++;

                bool yflip = (attr & 0x40) != 0;
                bool xflip = (attr & 0x20) != 0;
                bool behind = (attr & 0x80) != 0;
                byte pal = (attr & 0x10) != 0 ? Io(0xFF49) : Io(0xFF48);

                int row = ly - sy;
                if (yflip) row = spriteH - 1 - row;
                if (spriteH == 16) tile &= 0xFE;

                int dataAddr = tile * 16 + row * 2;
                byte lo = vram[dataAddr];
                byte hi = vram[dataAddr + 1];

                for (int px = 0; px < 8; px++)
                {
                    int x = sx + px;
                    if (x < 0 || x >= W) continue;
                    int bit = xflip ? px : 7 - px;
                    int c = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
                    if (c == 0) continue;                       // colour 0 is transparent
                    if (behind && bgColor[x] != 0) continue;    // BG priority
                    Frame[rowBase + x] = (byte)Shade(pal, c);
                }
            }
        }
    }
}
