using System;
using System.Collections.Generic;
using System.IO;

namespace Recomp.Tools
{
    // Port of pokered's tools/gfx.c -- the post-processing passes applied to
    // rgbgfx output. Only the options the Makefile actually uses are
    // implemented; the rest throw rather than silently doing nothing, so a
    // missed rule shows up as a build failure instead of a wrong ROM.
    //
    // Used by the Makefile:
    //   --trim-whitespace     gfx/tilesets/*, move_anim_0/1, *_slots_1
    //   --remove-duplicates   gfx/intro/gengar, gfx/trade/game_boy
    //   --interleave --png    gfx/credits/the_end
    //   --preserve            reds_house (0x48), gengar (0x19,0x76)
    public static class GfxTool
    {
        sealed class Opts
        {
            public bool TrimWhitespace;
            public bool Interleave;
            public bool RemoveDuplicates;
            public int Depth = 2;
            public string PngFile;
            public string OutFile;
            public List<int> Preserved = new List<int>();
        }

        static bool IsPreserved(Opts o, int index) { return o.Preserved.Contains(index); }

        static void ShiftPreserved(Opts o, int removedIndex)
        {
            for (int i = 0; i < o.Preserved.Count; i++)
                if (o.Preserved[i] >= removedIndex) o.Preserved[i]--;
        }

        static bool IsWhitespace(byte[] d, int off, int tileSize)
        {
            for (int i = 0; i < tileSize; i++) if (d[off + i] != 0) return false;
            return true;
        }

        static int GetTileSize(Opts o) { return o.Depth * (o.Interleave ? 16 : 8); }

        static long TrimWhitespace(Opts o, byte[] data, long size)
        {
            int tileSize = o.Depth * 8;
            for (long i = size - tileSize; i > 0; i -= tileSize)
            {
                if (IsWhitespace(data, (int)i, tileSize) && !IsPreserved(o, (int)(i / tileSize)))
                    size = i;
                else
                    break;
            }
            return size;
        }

        static bool TileExists(byte[] tile, int tileOff, byte[] tiles, int tileSize, int numTiles)
        {
            for (int i = 0; i < numTiles; i++)
            {
                bool match = true;
                for (int j = 0; j < tileSize; j++)
                    if (tile[tileOff + j] != tiles[i * tileSize + j]) { match = false; break; }
                if (match) return true;
            }
            return false;
        }

        static long RemoveDuplicates(Opts o, byte[] data, long size)
        {
            int tileSize = GetTileSize(o);
            size &= ~(long)(tileSize - 1);
            int numTiles = 0;

            for (long i = 0, j = 0, d = 0; i < size && j < size; i += tileSize, j += tileSize)
            {
                for (; j < size && TileExists(data, (int)j, data, tileSize, numTiles); j += tileSize, d++)
                {
                    if (IsPreserved(o, (int)(j / tileSize - d))) break;
                    ShiftPreserved(o, (int)(j / tileSize - d));
                }
                if (j >= size) break;
                if (j > i) Array.Copy(data, j, data, i, tileSize);
                numTiles++;
            }
            return (long)numTiles * tileSize;
        }

        static long Interleave(Opts o, byte[] data, long size, int width)
        {
            int tileSize = o.Depth * 8;
            int widthTiles = width / 8;
            int numTiles = (int)(size / tileSize);
            var interleaved = new byte[size];

            for (int i = 0; i < numTiles; i++)
            {
                int row = i / widthTiles;
                int tile = i * 2 - (row % 2 != 0 ? widthTiles * (row + 1) - 1 : widthTiles * row);
                Array.Copy(data, (long)i * tileSize, interleaved, (long)tile * tileSize, tileSize);
            }

            size = (long)numTiles * tileSize;
            Array.Copy(interleaved, data, size);
            return size;
        }

        // PNG width lives in the IHDR chunk at a fixed offset, so this needs no
        // zlib and no pixel decoding: 8-byte signature, 4-byte length,
        // 4-byte "IHDR", then the width as a big-endian u32.
        static int ReadPngWidth(string path)
        {
            var h = new byte[24];
            using (var fs = File.OpenRead(path))
                if (fs.Read(h, 0, 24) != 24) throw new InvalidDataException("short PNG: " + path);

            if (h[0] != 0x89 || h[1] != 'P' || h[2] != 'N' || h[3] != 'G')
                throw new InvalidDataException("not a PNG: " + path);
            if (h[12] != 'I' || h[13] != 'H' || h[14] != 'D' || h[15] != 'R')
                throw new InvalidDataException("first chunk is not IHDR: " + path);

            return (h[16] << 24) | (h[17] << 16) | (h[18] << 8) | h[19];
        }

        public static int Run(string[] args)
        {
            var o = new Opts();
            string infile = null;

            for (int i = 1; i < args.Length; i++)
            {
                var a = args[i];
                if (a == "--trim-whitespace") o.TrimWhitespace = true;
                else if (a == "--interleave") o.Interleave = true;
                else if (a == "--remove-duplicates") o.RemoveDuplicates = true;
                else if (a.StartsWith("--preserve="))
                    foreach (var t in a.Substring(11).Split(','))
                        o.Preserved.Add(Convert.ToInt32(t.Trim(), t.Trim().StartsWith("0x") ? 16 : 10));
                else if (a.StartsWith("--png=")) o.PngFile = a.Substring(6);
                else if (a == "--png") o.PngFile = args[++i];
                else if (a == "-d" || a == "--depth") o.Depth = int.Parse(args[++i]);
                else if (a == "-o" || a == "--out") o.OutFile = args[++i];
                else if (a.StartsWith("-"))
                    throw new NotSupportedException("gfx option not ported (unused by pokered's Makefile): " + a);
                else infile = a;
            }

            if (infile == null) { Console.Error.WriteLine("usage: recomp gfx [opts] -o out.2bpp in.2bpp"); return 2; }
            if (o.Depth != 1 && o.Depth != 2) throw new ArgumentException("bit depth must be 1 or 2");

            var data = File.ReadAllBytes(infile);
            long size = data.Length;

            // Order matters and matches main() in gfx.c.
            if (o.TrimWhitespace) size = TrimWhitespace(o, data, size);
            if (o.Interleave)
            {
                if (o.PngFile == null) throw new ArgumentException("--interleave needs --png to infer dimensions");
                size = Interleave(o, data, size, ReadPngWidth(o.PngFile));
            }
            if (o.RemoveDuplicates) size = RemoveDuplicates(o, data, size);

            if (o.OutFile != null)
            {
                var outBytes = new byte[size];
                Array.Copy(data, outBytes, size);
                File.WriteAllBytes(o.OutFile, outBytes);
            }
            return 0;
        }
    }
}
