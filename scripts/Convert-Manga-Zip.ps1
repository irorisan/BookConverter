# Streaming ZIP Store / ZIP64 writer compiled with Add-Type on .NET 10.
# Keep the documented Store contract with a streaming, dependency-free writer.
if (-not ('MangaStoredZip' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class MangaStoredZip
{
    private sealed class Entry
    {
        public byte[] Name;
        public uint Crc;
        public ulong Size, Offset;
    }
    private static readonly uint[] CrcTable = BuildCrcTable();
    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xedb88320U ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }
    // ZIP64 extras contain only fields whose 32-bit counterparts are saturated.
    private static byte[] Extra(Entry e, bool central)
    {
        using (var stream = new MemoryStream())
        using (var writer = new BinaryWriter(stream))
        {
            bool largeSize = e.Size >= uint.MaxValue;
            bool largeOffset = central && e.Offset >= uint.MaxValue;
            if (largeSize || largeOffset)
            {
                writer.Write((ushort)1);
                writer.Write((ushort)((largeSize ? 16 : 0) + (largeOffset ? 8 : 0)));
                if (largeSize) { writer.Write(e.Size); writer.Write(e.Size); }
                if (largeOffset) writer.Write(e.Offset);
            }
            return stream.ToArray();
        }
    }
    private static uint U32(ulong value) { return (uint)Math.Min(value, uint.MaxValue); }
    public static void Write(string destination, string[] sources, string[] names)
    {
        if (sources.Length != names.Length) throw new ArgumentException("Entry count mismatch");
        var entries = new List<Entry>();
        var utf8 = new UTF8Encoding(false, true);
        var buffer = new byte[65536];
        using (var stream = new FileStream(destination, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
        using (var writer = new BinaryWriter(stream))
        {
            for (int i = 0; i < sources.Length; i++)
            {
                using (var input = new FileStream(sources[i], FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    var e = new Entry { Name = utf8.GetBytes(names[i]), Size = (ulong)input.Length, Offset = (ulong)stream.Position };
                    if (e.Name.Length == 0 || e.Name.Length > ushort.MaxValue) throw new IOException("Invalid ZIP entry name length");
                    byte[] extra = Extra(e, false);
                    writer.Write(0x04034b50U);
                    writer.Write((ushort)(extra.Length > 0 ? 45 : 20));
                    writer.Write((ushort)0x800); // UTF-8 names
                    writer.Write((ushort)0); // Store
                    writer.Write((ushort)0); writer.Write((ushort)33); // 1980-01-01
                    writer.Write(0U); // CRC patched after streaming
                    writer.Write(U32(e.Size)); writer.Write(U32(e.Size));
                    writer.Write((ushort)e.Name.Length); writer.Write((ushort)extra.Length);
                    writer.Write(e.Name); writer.Write(extra);
                    uint crc = uint.MaxValue;
                    ulong copied = 0;
                    int read;
                    while ((read = input.Read(buffer, 0, buffer.Length)) != 0)
                    {
                        writer.Write(buffer, 0, read);
                        copied += (ulong)read;
                        for (int j = 0; j < read; j++) crc = CrcTable[(crc ^ buffer[j]) & 255] ^ (crc >> 8);
                    }
                    if (copied != e.Size) throw new IOException("Input size changed during ZIP creation");
                    e.Crc = crc ^ uint.MaxValue;
                    long end = stream.Position;
                    stream.Position = checked((long)e.Offset + 14);
                    writer.Write(e.Crc);
                    stream.Position = end;
                    entries.Add(e);
                }
            }
            ulong centralOffset = (ulong)stream.Position;
            foreach (var e in entries)
            {
                byte[] extra = Extra(e, true);
                writer.Write(0x02014b50U);
                writer.Write((ushort)45); writer.Write((ushort)(extra.Length > 0 ? 45 : 20));
                writer.Write((ushort)0x800); writer.Write((ushort)0);
                writer.Write((ushort)0); writer.Write((ushort)33);
                writer.Write(e.Crc); writer.Write(U32(e.Size)); writer.Write(U32(e.Size));
                writer.Write((ushort)e.Name.Length); writer.Write((ushort)extra.Length);
                writer.Write((ushort)0); writer.Write((ushort)0); writer.Write((ushort)0);
                writer.Write(0U); writer.Write(U32(e.Offset)); writer.Write(e.Name); writer.Write(extra);
            }
            ulong centralSize = (ulong)stream.Position - centralOffset;
            ulong count = (ulong)entries.Count;
            if (count >= ushort.MaxValue || centralSize >= uint.MaxValue || centralOffset >= uint.MaxValue)
            {
                ulong zip64Offset = (ulong)stream.Position;
                writer.Write(0x06064b50U); writer.Write(44UL);
                writer.Write((ushort)45); writer.Write((ushort)45);
                writer.Write(0U); writer.Write(0U); writer.Write(count); writer.Write(count);
                writer.Write(centralSize); writer.Write(centralOffset);
                writer.Write(0x07064b50U); writer.Write(0U); writer.Write(zip64Offset); writer.Write(1U);
            }
            writer.Write(0x06054b50U); writer.Write((ushort)0); writer.Write((ushort)0);
            writer.Write((ushort)Math.Min(count, ushort.MaxValue)); writer.Write((ushort)Math.Min(count, ushort.MaxValue));
            writer.Write(U32(centralSize)); writer.Write(U32(centralOffset)); writer.Write((ushort)0);
        }
    }
}
'@
}

function Write-MangaStoredZip {
    param([string]$Path, [System.Collections.Generic.List[object]]$Entries)
    [MangaStoredZip]::Write($Path, [string[]]@($Entries | ForEach-Object { $_.SourcePath }),
        [string[]]@($Entries | ForEach-Object { $_.EntryName }))
}
