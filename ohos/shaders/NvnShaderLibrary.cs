// SPDX-License-Identifier: MIT
// Offline SPIR-V and runtime-state identity are admitted before driver calls.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace S2Arm.Backends.Vulkan.Nvn;

public sealed record NvnShaderModule(byte[] Code, JsonElement Reflection, NvnSpirvFacts Facts);

public sealed class NvnShaderLibrary : IDisposable
{
    private readonly JsonDocument _index;
    private readonly FileStream _binary;
    private readonly Dictionary<string, JsonElement> _entries = new(StringComparer.Ordinal);
    private readonly object _gate = new();
    private bool _disposed;
    public int Count => _entries.Count;

    public NvnShaderLibrary(string directory)
    {
        string index = Path.Combine(directory, "shaders.index.json");
        if (new FileInfo(index).Length > 16 * 1024 * 1024) throw new InvalidDataException("Shader index too large");
        _index = JsonDocument.Parse(File.ReadAllBytes(index), new JsonDocumentOptions { MaxDepth = 32 });
        try
        {
            var root = _index.RootElement;
            if (root.GetProperty("schema").GetString() != "s2a.spirv-library.v2" || root.GetProperty("bindingConvention").GetString() != NvnSpirvFacts.Convention)
                throw new InvalidDataException("Legacy/mismatched SPIR-V package requires retranslation");
            string data = root.GetProperty("data").GetString();
            if (data is null || !System.Text.RegularExpressions.Regex.IsMatch(data, "^shaders-[0-9a-f]{64}\\.bin$"))
                throw new InvalidDataException("Shader data filename");
            _binary = new FileStream(Path.Combine(directory, data), FileMode.Open, FileAccess.Read, FileShare.Read);
            if (_binary.Length > 2L * 1024 * 1024 * 1024 || _binary.Length != root.GetProperty("bytes").GetInt64()) throw new InvalidDataException("Shader data length");
            var ranges = new List<(long Start, long End)>();
            foreach (var entry in root.GetProperty("entries").EnumerateArray())
            {
                string key = entry.GetProperty("key").GetString();
                long at = entry.GetProperty("offset").GetInt64(); int size = entry.GetProperty("bytes").GetInt32();
                if (string.IsNullOrEmpty(key) || key.Length > 256 || _entries.Count == 65536 || !_entries.TryAdd(key, entry) || at < 0 || at % 4 != 0 || size < 20 || size % 4 != 0 || size > 16 * 1024 * 1024 || at > _binary.Length - size)
                    throw new InvalidDataException("Shader range/key");
                ranges.Add((at, at + size));
            }
            long end = 0;
            foreach (var r in ranges.OrderBy(r => r.Start)) { if (r.Start != end) throw new InvalidDataException("Shader overlapping/gapped range"); end = r.End; }
            if (end != _binary.Length || _entries.Count == 0) throw new InvalidDataException("Shader package coverage");
        }
        catch { _binary?.Dispose(); _index.Dispose(); throw; }
    }

    // The caller supplies facts derived from the currently bound NVN state, not
    // a guessed material default or merely the short shader name.
    public NvnShaderModule Load(string key, string sourceSha256, string variantSha256, uint stage, uint maxSpirvVersion, IReadOnlySet<uint> enabledCapabilities)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (!_entries.TryGetValue(key, out var entry)) throw new KeyNotFoundException("SPIR-V cache miss");
            var reflection = entry.GetProperty("reflection");
            if (reflection.GetProperty("schema").GetString() != "s2a.spirv-reflection.v2" || reflection.GetProperty("bindingConvention").GetString() != NvnSpirvFacts.Convention)
                throw new InvalidDataException("Shader reflection ABI");
            if (reflection.GetProperty("requires_runtime_specialization").GetBoolean() || reflection.GetProperty("geometry_stride").GetInt32() != 0)
                throw new NotSupportedException("Shader requires actual runtime specialization/geometry conversion");
            if (!string.Equals(sourceSha256, reflection.GetProperty("source_sha256").GetString(), StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(variantSha256, reflection.GetProperty("variant_sha256").GetString(), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Shader source or runtime facts differ");
            var recipe = JsonNode.Parse(reflection.GetProperty("runtime_facts").GetRawText());
            if (!string.Equals((string)recipe["source_sha256"], sourceSha256, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(NvnSpirvFacts.Canonical(recipe)))), variantSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Shader runtime fact digest differs");
            int size = entry.GetProperty("bytes").GetInt32();
            byte[] code = new byte[size]; _binary.Position = entry.GetProperty("offset").GetInt64(); _binary.ReadExactly(code);
            if (!string.Equals(Convert.ToHexString(SHA256.HashData(code)), entry.GetProperty("sha256").GetString(), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Shader payload SHA differs");
            var facts = NvnSpirvFacts.Read(code);
            if (stage != facts.Stage || stage != reflection.GetProperty("vk_stage").GetUInt32() || facts.Version > maxSpirvVersion || facts.Capabilities.Any(c => !enabledCapabilities.Contains(c)))
                throw new NotSupportedException("Shader execution stage/version/capability unavailable");
            int ordinal = NvnSpirvFacts.StageOrdinal(reflection.GetProperty("stage").GetString());
            uint expectedStage = ordinal switch { 0 => 1u, 1 => 16u, 2 => 8u, 3 => 2u, 4 => 4u, 5 => 32u, _ => 0u };
            if (facts.Stage != expectedStage) throw new InvalidDataException("NVN and SPIR-V stages differ");
            uint first = (uint)ordinal * 256 + 1, end = first + 255;
            foreach (var b in facts.Bindings)
            {
                if (b.Binding == 0)
                {
                    if (b.Type != 6 || b.Count != 1) throw new InvalidDataException("Binding 0 is only the shared support UBO");
                }
                else if (b.Binding < first || b.Binding >= end || b.Count > end - b.Binding)
                    throw new InvalidDataException("Shader stage binding range differs");
            }
            var declared = reflection.GetProperty("spirv_bindings").EnumerateArray().Select(x => new NvnSpirvBinding(
                x.GetProperty("set").GetUInt32(), x.GetProperty("binding").GetUInt32(), x.GetProperty("descriptor_type").GetUInt32(), x.GetProperty("count").GetUInt32())).OrderBy(x => x.Binding).ToArray();
            if (!facts.Bindings.SequenceEqual(declared)) throw new InvalidDataException("Shader SPIR-V descriptor reflection differs");
            return new(code, reflection.Clone(), facts);
        }
    }

    public static (NvnSpirvBinding Binding, uint Stages)[] MergeBindings(params NvnShaderModule[] modules)
    {
        var result = new Dictionary<uint, (NvnSpirvBinding Binding, uint Stages)>();
        foreach (var module in modules)
            foreach (var binding in module.Facts.Bindings)
            {
                if (result.TryGetValue(binding.Binding, out var old))
                {
                    if (binding != old.Binding) throw new InvalidDataException("Shader stages alias different descriptor types");
                    // Only the shared support buffer may intentionally overlap.
                    if (binding.Binding != 0) throw new InvalidDataException("Shader stage descriptor ranges overlap");
                    result[binding.Binding] = (binding, old.Stages | module.Facts.Stage);
                }
                else result.Add(binding.Binding, (binding, module.Facts.Stage));
            }
        return result.Values.OrderBy(v => v.Binding.Binding).ToArray();
    }

    public void Dispose()
    {
        lock (_gate) { if (_disposed) return; _disposed = true; _binary.Dispose(); _index.Dispose(); }
    }
}
