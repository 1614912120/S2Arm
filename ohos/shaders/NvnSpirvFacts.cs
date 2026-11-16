// SPDX-License-Identifier: MIT
// Shared by the OHOS offline translator and its runtime package consumer.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;

namespace S2Arm.Backends.Vulkan.Nvn;

public readonly record struct NvnSpirvBinding(uint Set, uint Binding, uint Type, uint Count);

public sealed class NvnSpirvFacts
{
    public const string Convention = "nvn-stage256-v1";
    public uint Version { get; private set; }
    public uint Stage { get; private set; }
    public uint[] Capabilities { get; private set; }
    public NvnSpirvBinding[] Bindings { get; private set; }
    public static int StageOrdinal(string stage) => stage switch
    {
        "vs" => 0, "ps" or "fs" => 1, "gs" => 2, "hs" or "tcs" => 3,
        "ds" or "tes" => 4, "cs" => 5, _ => throw new InvalidDataException("Unknown NVN shader stage")
    };

    public static string Canonical(JsonNode node)
    {
        if (node is JsonObject obj)
            return "{" + string.Join(",", obj.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x =>
                System.Text.Json.JsonSerializer.Serialize(x.Key) + ":" + Canonical(x.Value))) + "}";
        if (node is JsonArray arr) return "[" + string.Join(",", arr.Select(Canonical)) + "]";
        return node?.ToJsonString() ?? "null";
    }

    public static NvnSpirvFacts Read(byte[] bytes)
    {
        if (bytes.Length < 20 || bytes.Length % 4 != 0 || bytes.Length > 16 * 1024 * 1024)
            throw new InvalidDataException("SPIR-V byte length");
        uint[] w = new uint[bytes.Length / 4];
        for (int i = 0; i < w.Length; i++) w[i] = System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(i * 4, 4));
        if (w[0] != 0x07230203 || w[1] < 0x10000 || w[1] > 0x10600 || w[3] == 0 || w[3] > 4_000_000 || w[4] != 0)
            throw new InvalidDataException("SPIR-V header");
        var types = new Dictionary<uint, (uint Op, uint[] A)>();
        var constants = new Dictionary<uint, uint>();
        var decorations = new Dictionary<(uint, uint), uint>();
        var vars = new List<(uint Type, uint Id, uint Storage)>();
        var capabilities = new SortedSet<uint>();
        uint stage = 0; int entries = 0;
        for (int i = 5; i < w.Length;)
        {
            int count = (int)(w[i] >> 16); uint op = w[i] & 65535;
            if (count == 0 || count > w.Length - i) throw new InvalidDataException("SPIR-V instruction length");
            var a = w.AsSpan(i + 1, count - 1);
            if (op is >= 19 and <= 33)
            {
                if (a.Length < 1 || a[0] == 0 || a[0] >= w[3] || !types.TryAdd(a[0], (op, a[1..].ToArray())))
                    throw new InvalidDataException("SPIR-V type identity");
            }
            else if (op == 43 && a.Length == 3) constants.Add(a[1], a[2]);
            else if (op == 71)
            {
                if (a.Length < 2) throw new InvalidDataException("SPIR-V decoration");
                if (a[1] is 2 or 3 or 33 or 34)
                {
                    if (a[1] is 33 or 34 && a.Length != 3) throw new InvalidDataException("Descriptor decoration length");
                    if (!decorations.TryAdd((a[0], a[1]), a.Length == 3 ? a[2] : 1))
                        throw new InvalidDataException("Duplicate descriptor decoration");
                }
            }
            else if (op == 59)
            {
                if (a.Length < 3) throw new InvalidDataException("SPIR-V variable");
                if (a[2] == 9) throw new NotSupportedException("Direct shader push constants are not implemented");
                vars.Add((a[0], a[1], a[2]));
            }
            else if (op == 17)
            {
                if (a.Length != 1) throw new InvalidDataException("SPIR-V capability");
                capabilities.Add(a[0]);
            }
            else if (op == 15)
            {
                if (a.Length < 3) throw new InvalidDataException("SPIR-V entry point");
                byte[] name = new byte[(a.Length - 2) * 4];
                for (int k = 2; k < a.Length; k++) System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(name.AsSpan((k - 2) * 4, 4), a[k]);
                int zero = Array.IndexOf(name, (byte)0);
                if (zero < 0 || Encoding.UTF8.GetString(name, 0, zero) != "main") throw new NotSupportedException("Direct shader entry must be main");
                stage = a[0] switch { 0 => 1u, 1 => 2u, 2 => 4u, 3 => 8u, 4 => 16u, 5 => 32u, _ => throw new NotSupportedException("SPIR-V execution model") };
                entries++;
            }
            i += count;
        }
        if (entries != 1) throw new NotSupportedException("Exactly one shader entry point is required");
        var bindings = new List<NvnSpirvBinding>();
        var slots = new HashSet<(uint, uint)>();
        foreach (var v in vars)
        {
            if (v.Storage is not (0 or 2 or 12)) continue;
            if (!decorations.TryGetValue((v.Id, 34), out uint set) || !decorations.TryGetValue((v.Id, 33), out uint binding))
                throw new InvalidDataException("Descriptor set/binding missing");
            if (set != 0 || !slots.Add((set, binding))) throw new NotSupportedException("Direct set0 binding collision");
            if (!types.TryGetValue(v.Type, out var pointer) || pointer.Op != 32 || pointer.A.Length != 2 || pointer.A[0] != v.Storage)
                throw new InvalidDataException("Descriptor pointer type");
            uint typeId = pointer.A[1], count = 1;
            var type = types[typeId]; int levels = 0;
            while (type.Op == 28)
            {
                if (++levels > 8 || type.A.Length != 2 || !constants.TryGetValue(type.A[1], out uint n) || n == 0 || n > 4096 || count > 4096 / n)
                    throw new NotSupportedException("Descriptor array size");
                count *= n; typeId = type.A[0]; type = types[typeId];
            }
            if (type.Op == 29) throw new NotSupportedException("Runtime descriptor arrays require another binding ABI");
            uint kind;
            if (v.Storage is 2 or 12)
            {
                if (type.Op != 30) throw new InvalidDataException("Descriptor buffer is not a struct");
                kind = v.Storage == 12 || decorations.ContainsKey((typeId, 3)) ? 7u : 6u;
                if (kind == 6 && !decorations.ContainsKey((typeId, 2))) throw new InvalidDataException("Uniform buffer lacks Block");
            }
            else if (type.Op == 26) kind = 0;
            else if (type.Op == 27)
            {
                if (type.A.Length != 1 || !types.TryGetValue(type.A[0], out var image) || image.Op != 25 || image.A.Length < 7 || image.A[1] == 6)
                    throw new NotSupportedException("Unsupported sampled image type");
                kind = image.A[1] == 5 ? 4u : 1u;
            }
            else if (type.Op == 25 && type.A.Length >= 7)
            {
                if (type.A[1] == 6) throw new NotSupportedException("Input attachments require a different binding ABI");
                bool buffer = type.A[1] == 5;
                kind = type.A[5] switch { 1 => buffer ? 4u : 2u, 2 => buffer ? 5u : 3u, _ => throw new NotSupportedException("Ambiguous image sampled kind") };
            }
            else throw new NotSupportedException("Descriptor type unsupported");
            bindings.Add(new(set, binding, kind, count));
        }
        return new() { Version = w[1], Stage = stage, Capabilities = capabilities.ToArray(), Bindings = bindings.OrderBy(b => b.Binding).ToArray() };
    }

    public JsonArray BindingJson()
    {
        var result = new JsonArray();
        foreach (var b in Bindings) result.Add(new JsonObject { ["set"] = b.Set, ["binding"] = b.Binding, ["descriptor_type"] = b.Type, ["count"] = b.Count });
        return result;
    }
}
