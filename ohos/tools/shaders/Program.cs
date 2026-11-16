// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Derived from S2Arm translator/dmsh_xlate/Program.cs (MIT).
// Vulkan batch output with reflection. No game-specific shader patches.
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Security.Cryptography;
using System.Text;
using S2Arm.Backends.Vulkan.Nvn;

static class OhosShaderBatch
{
    // NVN's handle tables in c[2], byte offsets, 8 bytes per slot (one layout in every game, see dm/graphics/tools/dmsh_build.py): combined textures 0x20 + 8 r, images 0x120 + 8 r (8 slots),
    // separate textures 0x168 + 8 r (slot 128 + r), separate samplers 0x568 + 8 r
    const int TexBase = 0x20, ImgBase = 0x120, ImgSlots = 8, SepTexBase = 0x168, SepTexSlot0 = 128, SampBase = 0x568;

    sealed class Accessor : IGpuAccessor
    {
        readonly byte[] _code; readonly JsonObject _job; int _binding; readonly int _bindingEnd; public readonly List<string> Notes = new();
        readonly byte[] _c1;
        public Accessor(byte[] code, JsonObject job, Dictionary<int, SamplerType> imageTypes = null) { int first = NvnSpirvFacts.StageOrdinal((string)job["stage"]) * 256; _bindingEnd = first + 256; _binding = first + (job["geometry_topology"] != null ? 40 : 1); _code = code; _job = job; _c1 = job["c1"] is JsonNode h ? Convert.FromHexString((string)h) : Array.Empty<byte>(); _imageTypes = imageTypes; }
        // A texture query on an image handle (TXQ on c2 0x120 + 8 r: Unreal's GetDimensions on the RWTexture3D a compute shader writes) asks the type of that handle, which a table built
        // without the game's PC shaders does not answer, and the 2D default took a 3D image's depth from its width. The shader's own surface instructions give the image's type: the
        // first translation records that a query went unanswered (ImageQueryGuessed), and Main translates again with the types of the images it found, by c2 handle (ImageTypesOf)
        readonly Dictionary<int, SamplerType> _imageTypes; public bool ImageQueryGuessed;
        public static Dictionary<int, SamplerType> ImageTypesOf(ShaderProgram p)
        {
            var types = new Dictionary<int, SamplerType>();
            foreach (var im in p.Info.Images) if (im.CbufSlot == 2 || im.CbufSlot < 0) types[im.HandleIndex] = im.Type & (SamplerType.Mask | SamplerType.Array);
            return types;
        }
        // c1 constant segment (the 0x100 bytes before the control segment in the shader package): the jump table of indirect jump BRX lives here (LDC c[1]); without it the translator cannot resolve jump targets and control flow goes wrong (particle shaders loop forever)
        public uint ConstantBuffer1Read(int offset) { if (offset >= 0 && offset + 4 <= _c1.Length) return BitConverter.ToUInt32(_c1, offset); Notes.Add($"c1 read out of bounds +{offset:X} (c1 length {_c1.Length})"); return 0; }
        // Vulkan shares descriptor bindings across stages. Reserve disjoint ranges;
        // only the translator support buffer at binding 0 is shared deliberately.
        private SetBindingPair Allocate(int count)
        {
            if (count < 1 || count > _bindingEnd - _binding) throw new NotSupportedException("Stage descriptor range exhausted");
            int binding = _binding; _binding += count; return new(0, binding);
        }
        public SetBindingPair CreateConstantBufferBinding(int index) => Allocate(1);
        public SetBindingPair CreateImageBinding(int count, bool isBuffer) => Allocate(count);
        public SetBindingPair CreateStorageBufferBinding(int index) => Allocate(1);
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => Allocate(count);
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => MemoryMarshal.Cast<byte, ulong>(new ReadOnlySpan<byte>(_code)[(int)address..]);
        public int QuerySamplerArrayLengthFromPool() => 32;
        public int QueryTextureArrayLengthFromBuffer(int slot) => 32;
        public int QueryTextureArrayLengthFromPool() => 32;

        string Get(string table, int slot) => _job[table] is JsonObject t && t[slot.ToString()] is JsonNode n ? (n is JsonObject o ? (string)o["type"] : (string)n) : null;
        // A handle's texture or image slot, numbered as dmsh_build.py decode_tex numbers the reflection's (so an answer table row names the slot the reflection shows): the handle ORs two
        // c[2] words in no fixed order, so both are tried (only the first for a combined handle or a constant sampler); -1 when neither is in the table
        static int Slot(int handle, int cbufSlot, bool image)
        {
            if (cbufSlot >= 0 && (cbufSlot & 0xffff) != 2) return -1;
            (int w0, int w1, TextureHandleType ty) = TextureHandle.UnpackOffsets(handle);
            foreach (int w in ty == TextureHandleType.CombinedSampler || ty == TextureHandleType.SeparateConstantSamplerHandle ? new[] { w0 } : new[] { w0, w1 })
            {
                int b = w * 4;
                if (b % 8 != 0) continue;
                if (image && b >= ImgBase && b < ImgBase + 8 * ImgSlots) return (b - ImgBase) / 8;
                if (!image && b >= TexBase && b < SepTexBase) return (b - TexBase) / 8;
                if (!image && b >= SepTexBase && b < SampBase) return SepTexSlot0 + (b - SepTexBase) / 8;
            }
            return -1;
        }
        public SamplerType QuerySamplerType(int handle, int cbufSlot = -1)
        {
            int slot = Slot(handle, cbufSlot, false), islot = Slot(handle, cbufSlot, true);
            string t = (slot >= 0 ? Get("tex", slot) : null) ?? (islot >= 0 ? Get("img", islot) : null);
            if (t == null && islot >= 0 && cbufSlot < 0)
            {
                if (_imageTypes != null && _imageTypes.TryGetValue(handle, out SamplerType it)) { Notes.Add($"texture handle {handle:X} is image slot {islot}: type {it} from the shader's image instructions"); return it; }
                ImageQueryGuessed = true;
            }
            if (t == null) { Notes.Add($"texture handle {handle:X} (constant buffer {cbufSlot}, slot {slot}) has no type in the answer table, using 2D"); return SamplerType.Texture2D; }
            return t switch
            {
                "1d" => SamplerType.Texture1D, "1darray" => SamplerType.Texture1D | SamplerType.Array,
                "buffer" => SamplerType.TextureBuffer, "2d" => SamplerType.Texture2D, "2darray" => SamplerType.Texture2D | SamplerType.Array,
                "2dms" => SamplerType.Texture2D | SamplerType.Multisample, "2dmsarray" => SamplerType.Texture2D | SamplerType.Multisample | SamplerType.Array,
                "3d" => SamplerType.Texture3D, "cube" => SamplerType.TextureCube, "cubearray" => SamplerType.TextureCube | SamplerType.Array,
                _ => SamplerType.Texture2D,
            };
        }
        // Texture slots read by a 1D integer fetch that the translator made a wrapped 2D read (x & 0x3FFF, x >> 14) for want of a type answer: they may hold a 1D texture or a texture buffer,
        // which only the bound descriptor tells (res "fetch1d"; dmsh_build.py flags their bindings, and the host binds a texture buffer there as 16384-texel rows, nvn_mtl.m tbuf_as_2d)
        public readonly SortedSet<int> Fetch1D = new();
        public void RecordTexelFetch1D(int handle) { int slot = Slot(handle, -1, false); if (slot >= 0) Fetch1D.Add(slot); }
        public TextureFormat QueryTextureFormat(int handle, int cbufSlot = -1)
        {
            int slot = Slot(handle, cbufSlot, true);
            string f = _job["img"] is JsonObject t && slot >= 0 && t[slot.ToString()] is JsonObject o ? (string)o["fmt"] : null;
            if (f == null) { Notes.Add($"image handle {handle:X} slot {slot} has no format in the answer table, using R8G8B8A8Unorm"); return TextureFormat.R8G8B8A8Unorm; }
            return Enum.TryParse(f, true, out TextureFormat tf) ? tf : TextureFormat.R8G8B8A8Unorm;
        }
        int Local(int i) => _job["local"] is JsonArray a && a.Count > i ? (int)a[i] : 1;
        public int QueryComputeLocalSizeX() => Local(0);
        public int QueryComputeLocalSizeY() => Local(1);
        public int QueryComputeLocalSizeZ() => Local(2);
        public int QueryComputeSharedMemorySize() => _job["shared"] is JsonNode n ? (int)n : 0;   // the shared memory size in the compute shader's control section (shader_split.py)
        static AttributeType Attr(string s) => s switch { "sint" => AttributeType.Sint, "uint" => AttributeType.Uint, _ => AttributeType.Float };
        public bool QueryGeometryInputFixed() => _job["geometry_topology"] != null;
        public GpuGraphicsState QueryGraphicsState()
        {
            Array32<AttributeType> attr = default; Array8<AttributeType> fout = default;
            if (_job["attr"] is JsonObject a) foreach (var kv in a) attr[int.Parse(kv.Key)] = Attr((string)kv.Value);
            if (_job["fout"] is JsonObject f) foreach (var kv in f) fout[int.Parse(kv.Key)] = Attr((string)kv.Value);
            return new GpuGraphicsState(false, _job["geometry_topology"] is JsonNode gt ? (InputTopology)(int)gt : InputTopology.Triangles, false, TessPatchType.Triangles, TessSpacing.EqualSpacing,
                false, false, false, _job["depthMode"] is JsonNode depth && (bool)depth, false, 1f, AlphaTestOp.Always, 0f, attr, false, fout, false,
                false /* no Y flip */, !(_job["originUpperLeft"] is JsonNode origin) || (bool)origin, false);
        }
        public bool QueryHostSupportsTextureShadowLod() => _job["textureShadowLod"] is JsonNode sl && (bool)sl;
        public bool QueryHostSupportsDepthClipControl() => false; // Emit the requested depth convention without relying on a device extension.
        // Job reduced = true: relaxed precision - the translator marks NoContraction only on operations that must be exact (the default marks all: keeps the bit-exact results of Maxwell's separate rounding, at the cost of many optimization-disabled spvFMul etc. in the MSL)
        public bool QueryHostReducedPrecision() => _job["reduced"] is JsonNode n && (bool)n;
        // Preserve FP64 during translation, then reject if the target cannot execute it.
        public bool QueryHostSupportsShaderFloat64() => true;
    }

    // True when SPIR-V declares OpTypeFloat 64; admission uses actual target capabilities.
    static bool UsesFloat64(byte[] spirv)
    {
        for (int i = 20; i + 12 <= spirv.Length; )
        {
            uint word = BitConverter.ToUInt32(spirv, i);
            if ((word & 0xffff) == 22 && (word >> 16) == 3 && BitConverter.ToUInt32(spirv, i + 8) == 64) return true;
            i += Math.Max(1, (int)(word >> 16)) * 4;
        }
        return false;
    }

    static int Main(string[] args)
    {
        if (args.Length != 2) { Console.Error.WriteLine("Usage: S2A.Ohos.ShaderBatch <jobs.json> <output>"); return 2; }
        var jobs = JsonNode.Parse(File.ReadAllText(args[0])).AsArray(); string outDir = args[1]; Directory.CreateDirectory(outDir);
        int ok = 0, bad = 0;
        foreach (JsonObject job in jobs)
        {
            string key = (string)job["key"];
            if (string.IsNullOrEmpty(key) || key.Contains('/') || key.Contains('\\') || key.Contains("..")) throw new ArgumentException("Invalid shader key");
            try
            {
                byte[] code = File.ReadAllBytes((string)job["code"]);
                var acc = new Accessor(code, job);
                // Job debug = false: turn off DebugMode (DebugMode skips the AST optimizer and the output is full of temporaries; semantics unchanged)
                var flags = (job["debug"] is JsonNode dbg && !(bool)dbg ? 0 : TranslationFlags.DebugMode) | ((string)job["stage"] == "cs" ? TranslationFlags.Compute : 0);
                var ctx = Translator.CreateContext(0, acc, new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, flags));
                bool geometry = job["geometry_topology"] != null;
                ShaderProgram p = ctx.Translate(geometry);
                Dictionary<int, SamplerType> imageTypes = null;
                if (acc.ImageQueryGuessed && (imageTypes = Accessor.ImageTypesOf(p)).Count > 0)   // a query on an image handle went unanswered: again with the images' types (see Accessor)
                {
                    acc = new Accessor(code, job, imageTypes);
                    ctx = Translator.CreateContext(0, acc, new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, flags));
                    p = ctx.Translate(geometry);
                }
                if (UsesFloat64(p.BinaryCode) && !(job["shaderFloat64"] is JsonNode f64 && (bool)f64))
                    throw new NotSupportedException("This shader requires shaderFloat64; provide actual device capabilities. No precision downgrade is applied.");
                if (geometry)
                {
                    // A fresh context: translation mutates the decoded program.
                    var reader = Translator.CreateContext(0, new Accessor(code, job, imageTypes), new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, flags));
                    File.WriteAllBytes(Path.Combine(outDir, key + ".reader.spv"), reader.GenerateVertexPassthroughForCompute().BinaryCode);
                }
                NvnSpirvFacts facts = NvnSpirvFacts.Read(p.BinaryCode);
                JsonObject recipe = (JsonObject)job.DeepClone(); recipe.Remove("code"); recipe.Remove("key");
                string sourceSha = Convert.ToHexString(SHA256.HashData(code)).ToLowerInvariant();
                recipe["source_sha256"] = sourceSha;
                string variantSha = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(NvnSpirvFacts.Canonical(recipe)))).ToLowerInvariant();
                File.WriteAllBytes(Path.Combine(outDir, key + ".spv"), p.BinaryCode);
                var res = new JsonObject
                {
                    ["schema"] = "s2a.spirv-reflection.v2", ["bindingConvention"] = NvnSpirvFacts.Convention,
                    ["source_sha256"] = sourceSha, ["variant_sha256"] = variantSha,
                    ["spirv_sha256"] = Convert.ToHexString(SHA256.HashData(p.BinaryCode)).ToLowerInvariant(),
                    ["vk_stage"] = facts.Stage, ["spirv_version"] = facts.Version, ["spirv_bindings"] = facts.BindingJson(),
                    ["capabilities"] = new JsonArray(Array.ConvertAll(facts.Capabilities, x => (JsonNode)JsonValue.Create(x))),
                    ["runtime_facts"] = recipe,
                    ["requires_runtime_specialization"] = (job["runtimeSpecializationRequired"] is JsonNode pending && (bool)pending) || acc.Notes.Exists(n => n.Contains("has no type") || n.Contains("has no format")),
                    ["key"] = key, ["stage"] = (string)job["stage"], ["notes"] = new JsonArray(acc.Notes.ConvertAll(n => (JsonNode)n).ToArray()),
                    ["cbufs"] = new JsonArray(), ["sbufs"] = new JsonArray(), ["textures"] = new JsonArray(), ["images"] = new JsonArray(),
                    ["geometry_stride"] = geometry ? ctx.GetResourceReservations().OutputSizePerInvocation : 0,
                    ["uses_frag_coord"] = p.Info.UsesFragCoord, ["frag_out_map"] = p.Info.FragmentOutputMap,
                };
                foreach (var b in p.Info.CBuffers) res["cbufs"].AsArray().Add(new JsonObject { ["set"] = b.Set, ["binding"] = b.Binding, ["slot"] = b.Slot });
                foreach (var b in p.Info.SBuffers) res["sbufs"].AsArray().Add(new JsonObject { ["set"] = b.Set, ["binding"] = b.Binding, ["slot"] = b.Slot, ["cb_slot"] = b.SbCbSlot, ["cb_offset"] = b.SbCbOffset, ["flags"] = (int)b.Flags });
                foreach (var (list, name) in new[] { (p.Info.Textures, "textures"), (p.Info.Images, "images") })
                    foreach (var t in list) res[name].AsArray().Add(new JsonObject { ["set"] = t.Set, ["binding"] = t.Binding, ["type"] = (int)t.Type, ["format"] = t.Format.ToString(), ["cbuf_slot"] = t.CbufSlot, ["handle"] = t.HandleIndex, ["array"] = t.ArrayLength, ["separate"] = t.Separate, ["flags"] = (int)t.Flags });
                if (acc.Fetch1D.Count > 0) { var f1 = new JsonArray(); foreach (int h in acc.Fetch1D) f1.Add(h); res["fetch1d"] = f1; }
                File.WriteAllText(Path.Combine(outDir, key + ".res.json"), res.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                ok++;
            }
            catch (Exception e) { bad++; Console.Error.WriteLine($"[RED] {key}: {e.GetType().Name}: {e.Message.Split('\n')[0]}"); if (Environment.GetEnvironmentVariable("DMSH_STACK") != null) Console.Error.WriteLine(e.StackTrace); }
        }
        Console.WriteLine($"translated: {ok} ok, {bad} failed");
        return bad == 0 ? 0 : 1;
    }
}
