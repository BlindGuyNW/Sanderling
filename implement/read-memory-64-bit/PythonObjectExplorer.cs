using System;
using System.Collections.Generic;
using System.Text;

namespace read_memory_64_bit;

/*
 * A breadth-first walk over the CPython 2.7 object graph, for answering "where does this text
 * live?" without guessing.
 *
 * `EveOnline64.ReadUITreeFromAddress` deliberately reads a narrow slice: only UI nodes, only the
 * allowlisted dict keys, and it never opens a value that is itself a container. That is the right
 * shape for a reading that runs many times a second, but it means a string held one hop off that
 * path -- in a list, in a dict, on a controller object that is not a UI node -- is invisible, and
 * indistinguishable from a string that is not there at all.
 *
 * This walker expands everything it can identify: str/unicode are read, list/tuple/dict/Bunch are
 * enumerated, and any other instance is opened through its type's tp_dictoffset. Paths are
 * reported so a hit can be turned into an allowlist entry or a reader.
 */
public class PythonObjectExplorer
{
    /*
     * PyTypeObject field offsets, 64-bit CPython 2.7.
     * https://github.com/python/cpython/blob/2.7/Include/object.h
     */
    const int tp_name_offset = 0x18;
    const int tp_dictoffset_offset = 0x120;

    readonly IMemoryReader memoryReader;

    readonly Dictionary<ulong, string> typeNameCache = [];

    public PythonObjectExplorer(IMemoryReader memoryReader)
    {
        this.memoryReader = memoryReader;
    }

    public record Finding(string path, string typeName, string value);

    ulong? ReadWord(ulong address)
    {
        var memory = memoryReader.ReadBytes(address, 8);

        if (memory?.Length is not 8)
            return null;

        return BitConverter.ToUInt64(memory.Value.Span);
    }

    string ReadNullTerminatedAscii(ulong address, int maxLength)
    {
        var bytes = memoryReader.ReadBytes(address, maxLength);

        if (bytes is null)
            return null;

        var span = bytes.Value.Span;

        for (var i = 0; i < span.Length; ++i)
        {
            if (span[i] is 0)
                return Encoding.ASCII.GetString(span[..i]);
        }

        return null;
    }

    public string GetTypeName(ulong objectAddress)
    {
        if (ReadWord(objectAddress + 8) is not { } typeObjectAddress)
            return null;

        if (typeNameCache.TryGetValue(typeObjectAddress, out var cached))
            return cached;

        var typeName =
            ReadWord(typeObjectAddress + tp_name_offset) is { } tp_name
            ? ReadNullTerminatedAscii(tp_name, 100)
            : null;

        typeNameCache[typeObjectAddress] = typeName;

        return typeName;
    }

    /// Where instances of this object's type keep their __dict__, per the type's tp_dictoffset.
    long? GetDictOffsetForObject(ulong objectAddress)
    {
        if (ReadWord(objectAddress + 8) is not { } typeObjectAddress)
            return null;

        if (ReadWord(typeObjectAddress + tp_dictoffset_offset) is not { } dictOffset)
            return null;

        //  A negative tp_dictoffset counts from the end of a variable-length object; not used here.
        if (dictOffset is 0 || 0x1000 < dictOffset)
            return null;

        return (long)dictOffset;
    }

    public string ReadStr(ulong address)
    {
        //  PyStringObject: ob_size at 0x10, characters inline from 0x20.
        if (ReadWord(address + 0x10) is not { } ob_size)
            return null;

        if (0x10000 < ob_size)
            return null;

        if (ob_size is 0)
            return "";

        var bytes = memoryReader.ReadBytes(address + 0x20, (int)ob_size);

        if (bytes?.Length != (int)ob_size)
            return null;

        return Encoding.ASCII.GetString(bytes.Value.Span);
    }

    public string ReadUnicode(ulong address)
    {
        //  PyUnicodeObject: length at 0x10, pointer to Py_UNICODE buffer at 0x18.
        if (ReadWord(address + 0x10) is not { } length)
            return null;

        if (0x10000 < length)
            return null;

        if (length is 0)
            return "";

        if (ReadWord(address + 0x18) is not { } bufferAddress)
            return null;

        var bytes = memoryReader.ReadBytes(bufferAddress, (int)length * 2);

        if (bytes?.Length != (int)length * 2)
            return null;

        return Encoding.Unicode.GetString(bytes.Value.Span);
    }

    /// Enumerate (key, value) address pairs of a PyDictObject at this address.
    List<(ulong key, ulong value)> ReadDictEntries(ulong dictAddress)
    {
        var dictMemory = memoryReader.ReadBytes(dictAddress, 0x30);

        if (dictMemory?.Length is not 0x30)
            return null;

        var words = TransformMemoryContent.AsULongMemory(dictMemory.Value);

        var ma_mask = words.Span[4];
        var ma_table = words.Span[5];

        var numberOfSlots = (long)ma_mask + 1;

        if (numberOfSlots < 1 || 100_000 < numberOfSlots)
            return null;

        var slotsMemorySize = (int)numberOfSlots * 8 * 3;

        var slotsMemory = memoryReader.ReadBytes(ma_table, slotsMemorySize);

        if (slotsMemory?.Length != slotsMemorySize)
            return null;

        var slots = TransformMemoryContent.AsULongMemory(slotsMemory.Value);

        var entries = new List<(ulong, ulong)>();

        for (var i = 0; i < numberOfSlots; ++i)
        {
            var key = slots.Span[i * 3 + 1];
            var value = slots.Span[i * 3 + 2];

            if (key is 0 || value is 0)
                continue;

            entries.Add((key, value));
        }

        return entries;
    }

    List<ulong> ReadSequenceItems(ulong address, bool isTuple)
    {
        if (ReadWord(address + 0x10) is not { } ob_size)
            return null;

        if (0x10000 < ob_size)
            return null;

        if (ob_size is 0)
            return [];

        var itemsAddress = address + 0x18;

        if (!isTuple)
        {
            //  PyListObject keeps its items in a separate ob_item allocation.
            if (ReadWord(address + 0x18) is not { } ob_item)
                return null;

            itemsAddress = ob_item;
        }

        var itemsMemory = memoryReader.ReadBytes(itemsAddress, (int)ob_size * 8);

        if (itemsMemory?.Length != (int)ob_size * 8)
            return null;

        var words = TransformMemoryContent.AsULongMemory(itemsMemory.Value);

        var items = new List<ulong>();

        for (var i = 0; i < words.Length; ++i)
            items.Add(words.Span[i]);

        return items;
    }

    static readonly HashSet<string> uninterestingTypeNames =
    [
        "NoneType", "int", "long", "bool", "float", "complex",
        "type", "classobj", "function", "instancemethod", "builtin_function_or_method",
        "weakref", "weakproxy", "module", "code", "frame", "traceback", "generator",
        "method-wrapper", "wrapper_descriptor", "getset_descriptor", "member_descriptor",
    ];

    /// Walk outward from `rootAddress`, reporting every string reachable within the limits.
    /// When `searchTerm` is given, only strings containing it are reported.
    public List<Finding> Explore(
        ulong rootAddress,
        string searchTerm,
        int maxObjects,
        int maxDepth)
    {
        var findings = new List<Finding>();

        var visited = new HashSet<ulong>();

        var queue = new Queue<(ulong address, string path, int depth)>();

        queue.Enqueue((rootAddress, "<root>", 0));

        visited.Add(rootAddress);

        var objectsExamined = 0;

        while (0 < queue.Count && objectsExamined < maxObjects)
        {
            var (address, path, depth) = queue.Dequeue();

            ++objectsExamined;

            var typeName = GetTypeName(address);

            if (typeName is null)
                continue;

            if (typeName is "str" or "unicode")
            {
                var value = typeName is "str" ? ReadStr(address) : ReadUnicode(address);

                if (value is not null &&
                    (searchTerm is null || value.Contains(searchTerm, StringComparison.OrdinalIgnoreCase)))
                {
                    findings.Add(new Finding(path, typeName, value));
                }

                continue;
            }

            if (uninterestingTypeNames.Contains(typeName))
                continue;

            if (maxDepth <= depth)
                continue;

            void EnqueueChild(ulong childAddress, string childPath)
            {
                if (childAddress is 0)
                    return;

                if (!visited.Add(childAddress))
                    return;

                queue.Enqueue((childAddress, childPath, depth + 1));
            }

            if (typeName is "list" or "tuple")
            {
                var items = ReadSequenceItems(address, isTuple: typeName is "tuple");

                if (items is not null)
                {
                    for (var i = 0; i < items.Count; ++i)
                        EnqueueChild(items[i], $"{path}[{i}]");
                }

                continue;
            }

            /*
             * A dict is walked directly. `Bunch` and the other dict subclasses EVE uses keep their
             * entries in the object itself, which is why `ReadingFromPythonType_Bunch` reads the
             * Bunch address as a dictionary rather than following a __dict__ pointer.
             */
            var dictAddress = address;

            if (typeName is not ("dict" or "Bunch" or "KeyVal" or "defaultdict"))
            {
                if (typeName is "instance")
                {
                    //  Old-style class instance: in_dict at 0x18.
                    if (ReadWord(address + 0x18) is not { } instanceDict)
                        continue;

                    dictAddress = instanceDict;
                }
                else
                {
                    if (GetDictOffsetForObject(address) is not { } dictOffset)
                        continue;

                    if (ReadWord(address + (ulong)dictOffset) is not { } objectDict)
                        continue;

                    dictAddress = objectDict;
                }

                if (dictAddress is 0)
                    continue;
            }

            var entries = ReadDictEntries(dictAddress);

            if (entries is null)
                continue;

            foreach (var (keyAddress, valueAddress) in entries)
            {
                var keyTypeName = GetTypeName(keyAddress);

                var keyString =
                    keyTypeName is "str" ? ReadStr(keyAddress)
                    : keyTypeName is "unicode" ? ReadUnicode(keyAddress)
                    : null;

                EnqueueChild(valueAddress, $"{path}.{keyString ?? $"<{keyTypeName}@0x{keyAddress:X}>"}");
            }
        }

        return findings;
    }
}
