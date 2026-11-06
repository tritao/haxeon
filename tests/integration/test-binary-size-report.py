#!/usr/bin/env python3
"""Exercise the report's byte accounting and mismatch rejection."""
import json
import pathlib
import struct
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
report = root / 'scripts/report-binary-size.py'
with tempfile.TemporaryDirectory() as directory:
    directory = pathlib.Path(directory)
    module = directory / 'small.wasm'
    log = directory / 'census.log'
    # One void function plus a custom name section; body is two bytes.
    module.write_bytes(bytes.fromhex('0061736d01000000 010401600000 03020100 0a040102000b 0007046e616d650000'))
    row = {'target': 'wasm32', 'name': 'f', 'bytes': 2, 'instructions': 0, 'opaqueBytes': 0}
    log.write_text('EMITTED_CENSUS ' + json.dumps(row) + '\n')
    result = subprocess.run([report, module, log], check=True, text=True, capture_output=True)
    result = json.loads(result.stdout)
    assert result['categories'] == {'header': 8, 'types': 6, 'function signatures': 4,
                                     'code': 6, 'custom: name': 9}
    assert result['functionCount'] == 1 and result['bytes'] == len(module.read_bytes())
    row['bytes'] = 3
    log.write_text('EMITTED_CENSUS ' + json.dumps(row) + '\n')
    result = subprocess.run([report, module, log], text=True, capture_output=True)
    assert result.returncode != 0 and 'do not match' in result.stderr
    # A root record for the defined function is charged to that record, with framing separate.
    row['bytes'] = 2
    log.write_text('EMITTED_CENSUS ' + json.dumps(row) + '\n')
    name = b'haxeon.gc.roots'
    payload = (b'HGR\1' + struct.pack('<I', 1) + struct.pack('<I', 1) + b'f'
               + struct.pack('<IIIIII', 1, 3, 4, 2, 5, 6))
    custom = bytes([len(name)]) + name + payload
    module.write_bytes(module.read_bytes() + bytes([0, len(custom)]) + custom)
    module.write_bytes(module.read_bytes() + bytes.fromhex('0b0d02 0041000b026162 010378797a'))
    data_row = {'target': 'wasm32', 'segments': [{'category': 'strings', 'bytes': 7},
                                                 {'category': 'reflection', 'bytes': 5}]}
    with log.open('a') as stream:
        stream.write('SIZE_DATA_CENSUS ' + json.dumps(data_row) + '\n')
    result = subprocess.run([report, module, log], check=True, text=True, capture_output=True)
    result = json.loads(result.stdout)
    assert result['dataContributors'] == {'strings': 7, 'reflection': 5, 'section framing': 3}
    metadata = result['metadataContributors']['haxeon.gc.roots']
    assert metadata['headerBytes'] == 8 and metadata['count'] == 1
    assert metadata['groups']['other (defined)'] == {'count': 1, 'bytes': 29}
    data_row['segments'][0]['bytes'] = 6
    log.write_text('EMITTED_CENSUS ' + json.dumps(row) + '\nSIZE_DATA_CENSUS ' + json.dumps(data_row) + '\n')
    result = subprocess.run([report, module, log], text=True, capture_output=True)
    assert result.returncode != 0 and 'data segments do not match' in result.stderr
    # HashLink accounting comes from the serializer; reject an incomplete breakdown.
    module.write_bytes(b'HLB' + bytes(7))
    row = {'target': 'hl', 'header': 4, 'functions': 5, 'debugSections': 1,
           'sections': [], 'topTypes': [], 'topStrings': [], 'topStringUses': [], 'topFunctionDebug': []}
    log.write_text('SIZE_CENSUS ' + json.dumps(row) + '\n')
    result = subprocess.run([report, module, log], check=True, text=True, capture_output=True)
    assert sum(json.loads(result.stdout)['categories'].values()) == 10
    row['functions'] = 4
    log.write_text('SIZE_CENSUS ' + json.dumps(row) + '\n')
    result = subprocess.run([report, module, log], text=True, capture_output=True)
    assert result.returncode != 0 and 'accounts for 9 of 10 bytes' in result.stderr
    # A precise span associates a source hash with its embedded snapshot.
    source_hash = struct.pack('<I', 0x1234)
    spans = (bytes([1, 3]) + b'x.h' + bytes([1, 1, 1, 0, 0, 1, 2, 1, 1, 1, 2])
             + source_hash + bytes([0]))
    snapshots = bytes([1]) + source_hash + bytes([3]) + b'abc'
    tail = bytes([2, 2, 2, 0, len(spans)]) + spans + bytes([3, 1, 0, len(snapshots)]) + snapshots
    module.write_bytes(b'HLB' + tail)
    row.update({'header': 3, 'functions': 0, 'debugSections': len(tail),
                'sections': [{'kind': 2, 'version': 2, 'payload': len(spans)},
                             {'kind': 3, 'version': 1, 'payload': len(snapshots)}]})
    log.write_text('SIZE_CENSUS ' + json.dumps(row) + '\n')
    result = subprocess.run([report, module, log], check=True, text=True, capture_output=True)
    debug = json.loads(result.stdout)['contributors']['debug']
    assert debug['snapshots'] == [{'hash': '00001234', 'bytes': 3, 'paths': ['x.h']}]
    assert debug['spanFiles'][0]['path'] == 'x.h'
print('PASS: binary size accounting and mismatch rejection')
