#!/usr/bin/env python3
"""Summarize HAXEON_IR_CENSUS=1 output and account for a serialized module.

Usage: report-binary-size.py MODULE CENSUS_LOG
The census must come from the same compiler invocation as MODULE. Wasm section
headers and vector/length prefixes are charged to their enclosing section.
"""
import collections
import hashlib
import json
import pathlib
import struct
import sys


def uleb(data, pos):
    value = 0
    for shift in range(0, 35, 7):
        if pos >= len(data):
            raise ValueError("truncated LEB128")
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
    raise ValueError("oversized LEB128")


def hl_index(data, pos):
    if pos >= len(data):
        raise ValueError('truncated HashLink index')
    byte = data[pos]
    pos += 1
    if byte < 0x80:
        return byte, pos
    width = 1 if byte < 0xc0 else 3
    if pos + width > len(data):
        raise ValueError('truncated HashLink index')
    value = byte & 0x1f
    for part in data[pos:pos + width]:
        value = (value << 8) | part
    return (-value if byte & 0x20 else value), pos + width


def hl_debug_contributors(module, size, expected):
    """Decode trailing debug sections and rank spans and embedded sources."""
    start = len(module) - size
    if start < 0:
        raise ValueError('debug sections exceed module size')
    data = module[start:]
    count, pos = hl_index(data, 0)
    sections = []
    for _ in range(count):
        kind, pos = hl_index(data, pos)
        version, pos = hl_index(data, pos)
        flags, pos = hl_index(data, pos)
        length, pos = hl_index(data, pos)
        if length < 0 or pos + length > len(data):
            raise ValueError('truncated HashLink debug section')
        sections.append((kind, version, data[pos:pos + length]))
        pos += length
    if pos != len(data) or [(k, v, len(b)) for k, v, b in sections] != [
            (s['kind'], s['version'], s['payload']) for s in expected]:
        raise ValueError('HashLink debug sections do not match census')
    hashes = collections.defaultdict(set)
    span_files = collections.Counter()
    snapshots = []
    for kind, version, payload in sections:
        pos = 0

        def index():
            nonlocal pos
            value, pos = hl_index(payload, pos)
            if value < 0:
                raise ValueError('negative debug index')
            return value

        def sized_string():
            nonlocal pos
            size = index()
            if size > len(payload) - pos:
                raise ValueError('truncated debug string')
            value = payload[pos:pos + size].decode('utf-8')
            pos += size
            return value

        if kind == 2 and version == 2:
            files = [sized_string() for _ in range(index())]
            for _ in range(index()):
                index()  # stable function id
                for _ in range(index()):
                    begin = pos
                    index()  # opcode
                    file = index()
                    if file >= len(files):
                        raise ValueError('invalid span source index')
                    for _ in range(6):
                        index()  # offsets, line and columns
                    if pos + 4 > len(payload):
                        raise ValueError('truncated span source hash')
                    source_hash, = struct.unpack_from('<I', payload, pos)
                    pos += 4
                    index()  # flags
                    hashes[source_hash].add(files[file])
                    span_files[files[file]] += pos - begin
            if pos != len(payload):
                raise ValueError('trailing opcode spans')
        elif kind == 3 and version == 1:
            for _ in range(index()):
                if pos + 4 > len(payload):
                    raise ValueError('truncated snapshot hash')
                source_hash, = struct.unpack_from('<I', payload, pos)
                pos += 4
                length = index()
                if length > len(payload) - pos:
                    raise ValueError('truncated source snapshot')
                snapshots.append({'hash': '%08x' % source_hash, 'bytes': length, 'sourceHash': source_hash})
                pos += length
            if pos != len(payload):
                raise ValueError('trailing source snapshots')
    for snapshot in snapshots:
        snapshot['paths'] = sorted(hashes.get(snapshot.pop('sourceHash'), []))
    return {'spanFiles': [{'path': path, 'bytes': size} for path, size in
                          sorted(span_files.items(), key=lambda x: (-x[1], x[0]))[:30]],
            'snapshots': sorted(snapshots, key=lambda x: (-x['bytes'], x['hash']))[:30]}


def wasm_sections(data):
    if data[:8] != b'\0asm\x01\0\0\0':
        raise ValueError("not a WebAssembly version 1 module")
    labels = {1: 'types', 2: 'imports', 3: 'function signatures', 4: 'function tables',
              5: 'memory', 6: 'globals', 7: 'exports', 8: 'start', 9: 'table elements',
              10: 'code', 11: 'data', 12: 'data count', 13: 'exception tags'}
    result = collections.Counter({'header': 8})
    bodies, data_segments, custom = [], [], {}
    pos = 8
    while pos < len(data):
        start = pos
        section = data[pos]
        length, pos = uleb(data, pos + 1)
        end = pos + length
        if end > len(data):
            raise ValueError("truncated section")
        name = labels.get(section, 'section ' + str(section))
        if section == 0:
            size, offset = uleb(data, pos)
            if offset + size > end:
                raise ValueError("truncated custom section name")
            name = 'custom: ' + data[offset:offset + size].decode('utf-8')
            if name[8:] in custom and name[8:] in ('haxeon.gc.roots', 'haxeon.patch', 'haxeon.patch.slots'):
                raise ValueError('duplicate Haxeon metadata section ' + name[8:])
            custom[name[8:]] = data[offset + size:end]
        if section == 10:
            count, cursor = uleb(data, pos)
            for _ in range(count):
                size, cursor = uleb(data, cursor)
                bodies.append(size)
                cursor += size
                if cursor > end:
                    raise ValueError("truncated function body")
            if cursor != end:
                raise ValueError("trailing code bytes")
        if section == 11:
            count, cursor = uleb(data, pos)
            for _ in range(count):
                begin = cursor
                mode, cursor = uleb(data, cursor)
                if mode == 0:
                    if cursor >= end or data[cursor] != 0x41:
                        raise ValueError('unsupported data offset expression')
                    _, cursor = uleb(data, cursor + 1)
                    if cursor >= end or data[cursor] != 0x0b:
                        raise ValueError('invalid data offset expression')
                    cursor += 1
                elif mode != 1:
                    raise ValueError('unsupported data segment mode')
                size, cursor = uleb(data, cursor)
                cursor += size
                if cursor > end:
                    raise ValueError('truncated data segment')
                data_segments.append(cursor - begin)
            if cursor != end:
                raise ValueError('trailing data section bytes')
        result[name] += end - start
        pos = end
    return dict(sorted(result.items())), bodies, data_segments, custom


def metadata_contributors(custom, functions):
    """Measure known metadata records; an unmatched name is not proof of dead code."""
    defined = {fn['name'] for fn in functions}
    result = {}
    for section, magic in [('haxeon.gc.roots', b'HGR'), ('haxeon.patch', b'HWP'),
                           ('haxeon.patch.slots', b'HWT')]:
        data = custom.get(section)
        if data is None:
            continue
        if len(data) < 8 or data[:4] != magic + b'\1':
            raise ValueError('unsupported metadata format in ' + section)
        pos = 4

        def integer():
            nonlocal pos
            if pos + 4 > len(data):
                raise ValueError('truncated metadata in ' + section)
            value, = struct.unpack_from('<I', data, pos)
            pos += 4
            return value

        def string():
            nonlocal pos
            length = integer()
            if length > len(data) - pos:
                raise ValueError('truncated metadata string in ' + section)
            value = data[pos:pos + length].decode('utf-8')
            pos += length
            return value

        count = integer()
        if count > (len(data) - pos) // 4:
            raise ValueError('invalid metadata record count in ' + section)
        groups, records = {}, []
        for _ in range(count):
            start = pos
            name = string()
            if magic == b'HGR':
                points = integer()
                if points > (len(data) - pos) // 12:
                    raise ValueError('invalid root point count')
                for _ in range(points):
                    integer()  # block
                    integer()  # instruction
                    references = integer()
                    if references > (len(data) - pos) // 4:
                        raise ValueError('truncated root references')
                    pos += references * 4
            elif magic == b'HWP':
                integer()  # stable id
                string()  # signature
            else:
                integer()  # stable id
                integer()  # table slot
            kind = ('closure adapter' if name.startswith('__haxeon_closure_adapter_') else
                    'closure cast dispatcher' if name.startswith('__haxeon_closure_cast_') else 'other')
            group = kind + (' (defined)' if name in defined else ' (not in defined census)')
            entry = groups.setdefault(group, {'count': 0, 'bytes': 0})
            entry['count'] += 1
            entry['bytes'] += pos - start
            records.append({'name': name, 'bytes': pos - start})
        if pos != len(data):
            raise ValueError('trailing metadata in ' + section)
        result[section] = {'headerBytes': 8, 'count': count, 'groups': groups,
                           'top': sorted(records, key=lambda x: (-x['bytes'], x['name']))[:30]}
    return result


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    module = pathlib.Path(sys.argv[1]).read_bytes()
    size_rows, data_rows, functions = [], [], []
    with open(sys.argv[2], encoding='utf-8') as stream:
        for line in stream:
            if line.startswith('SIZE_CENSUS '):
                size_rows.append(json.loads(line[len('SIZE_CENSUS '):]))
            elif line.startswith('SIZE_DATA_CENSUS '):
                data_rows.append(json.loads(line[len('SIZE_DATA_CENSUS '):]))
            elif line.startswith('EMITTED_CENSUS '):
                functions.append(json.loads(line[len('EMITTED_CENSUS '):]))
    if module.startswith(b'HLB'):
        if len(size_rows) != 1:
            raise ValueError('expected exactly one HashLink size census')
        row = size_rows[0]
        sizes = {k: v for k, v in row.items() if isinstance(v, int)}
        sections = row['sections']
        contributors = {'types': row['topTypes'], 'strings': row['topStrings'],
                        'stringLoads': row['topStringUses']}
        names = {fn['index']: fn['name'] for fn in functions}
        contributors['functionDebug'] = [dict(entry, name=names.get(entry['index'], '#' + str(entry['index'])))
                                         for entry in row['topFunctionDebug']]
        contributors['debug'] = hl_debug_contributors(module, row['debugSections'], sections)
        metadata = {}
        data_details = None
        target = 'hl'
    else:
        sizes, bodies, data_segments, custom = wasm_sections(module)
        sections = []
        contributors = {}
        if len(functions) != len(bodies) or any(f['bytes'] != b for f, b in zip(functions, bodies)):
            raise ValueError('census function bodies do not match module code section')
        target = functions[0]['target'] if functions else data_rows[0]['target'] if len(data_rows) == 1 else 'wasm'
        metadata = metadata_contributors(custom, functions)
        data_details = {} if 'data' not in sizes else None
        if data_rows:
            if len(data_rows) != 1 or data_rows[0]['target'] != target:
                raise ValueError('expected one matching Wasm data census')
            segments = data_rows[0]['segments']
            if [segment['bytes'] for segment in segments] != data_segments:
                raise ValueError('census data segments do not match module data section')
            data_details = {}
            for segment in segments:
                data_details[segment['category']] = data_details.get(segment['category'], 0) + segment['bytes']
            if data_segments:
                data_details['section framing'] = sizes['data'] - sum(data_segments)
    if sum(sizes.values()) != len(module):
        raise ValueError('census accounts for %d of %d bytes' % (sum(sizes.values()), len(module)))
    if any(f['target'] != target for f in functions):
        raise ValueError('census contains multiple targets')
    groups = {}
    if target != 'hl':
        for fn in functions:
            name = fn['name']
            group = ('linked opaque' if fn['opaqueBytes'] else
                     'closure adapters' if name.startswith('__haxeon_closure_adapter_') else
                     'closure cast dispatchers' if name.startswith('__haxeon_closure_cast_') else
                     'other __ prefixed' if name.startswith('__') else 'other')
            entry = groups.setdefault(group, {'count': 0, 'bytes': 0})
            entry['count'] += 1
            entry['bytes'] += fn['bytes']
    top = sorted(functions, key=lambda f: (-f['bytes'], f['name']))[:30]
    print(json.dumps({'target': target, 'bytes': len(module), 'sha256': hashlib.sha256(module).hexdigest(), 'categories': sizes,
                      'debugSections': sections, 'functionCount': len(functions),
                      'contributors': contributors, 'functionGroups': groups,
                      'metadataContributors': metadata, 'dataContributors': data_details,
                      'topFunctions': [{'name': f['name'], 'bytes': f['bytes']} for f in top]}, indent=2))


if __name__ == '__main__':
    main()
