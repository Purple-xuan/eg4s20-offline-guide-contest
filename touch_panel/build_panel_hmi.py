"""Build the exact-model TJC project using its factory project as device seed.

Usage: python build_panel_hmi.py --seed path/to/TJC4827T143_factory.HMI
Requires Pillow. HMI container/page layout and CRC were cross-checked with
https://github.com/nixiewright/nxwright (Apache-2.0); no vendor compiler is
replaced here. The resulting HMI still needs USART HMI compilation.
"""
import argparse
import copy
import csv
import hashlib
import json
import struct
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent


def advance(value):
    for _ in range(32):
        value = ((value << 1) ^ (0x04C11DB7 if value & 0x80000000 else 0)) & 0xffffffff
    return value


TABLES = [[advance(b << (8 * n)) for b in range(256)] for n in range(4)]


def crc(words):
    value = 0xffffffff
    for word in words:
        q = value ^ word
        value = TABLES[0][q & 255] ^ TABLES[1][q >> 8 & 255] ^ TABLES[2][q >> 16 & 255] ^ TABLES[3][q >> 24 & 255]
    return value


def stamped(block, tail):
    return struct.pack('<I', crc(list(block[4:]) + [block[i] for i in tail])) + block[4:]


def read_container(path):
    data = path.read_bytes()
    blocks = {}
    for i in range(struct.unpack_from('<I', data)[0]):
        name, offset, length, flags = struct.unpack_from('<16sIII', data, 4 + i * 28)
        if not flags & 1:
            blocks[name.split(b'\0')[0].decode('ascii')] = data[offset:offset + length]
    return blocks


def write_container(blocks):
    directory = bytearray(struct.pack('<I', len(blocks)))
    offset = 0x700000
    for name, block in blocks.items():
        directory += struct.pack('<16sIII', name.encode(), offset, len(block), 0x200 if name == 'Program.s' else 0)
        offset += len(block)
    checksum = advance(crc(struct.unpack('<%dI' % (len(directory) // 4), directory))) ^ 0xf5d03d45
    directory += struct.pack('<I', checksum)
    data = bytearray(0x700000)
    data[:len(directory)] = directory
    data[0x80000:0x80000 + len(directory)] = directory
    data[0x380000:0x380004] = b'\xff' * 4
    data[0x6ffff8:0x700000] = b'ver21234'
    return bytes(data) + b''.join(blocks.values())


def parse_objects(page):
    result = []
    for n in range(struct.unpack_from('<I', page, 12)[0]):
        offset, length, _ = struct.unpack_from('<III', page, 56 + n * 12)
        body = page[56 + offset:56 + offset + length]
        records, p = [], 0
        while struct.unpack_from('<I', body, p)[0]:
            size = struct.unpack_from('<I', body, p)[0]
            records.append(body[p + 4:p + 4 + size])
            p += 4 + size
        result.append(records)
    return result


def attributes(records):
    return {r[:16].rstrip(b'\0').decode('ascii'): r[16:] for r in records if len(r) >= 16}


def object_bytes(attrs, events):
    records = [('att-%d' % len(attrs)).encode()]
    records += [name.encode().ljust(16, b'\0') + value for name, value in attrs.items()]
    for event, lines in events.items():
        records += [('codes%s-%d' % (event, len(lines))).encode(), *[s.encode('ascii') for s in lines]]
    return b''.join(struct.pack('<I', len(r)) + r for r in records) + bytes(4)


def put(attrs, name, value, width=None):
    if isinstance(value, str):
        attrs[name] = value.encode('ascii')
    else:
        attrs[name] = value.to_bytes(width or len(attrs[name]), 'little')


def make_page(seed_page, page_id, rows):
    base = attributes(parse_objects(seed_page)[0])
    put(base, 'objname', 'page%d' % page_id)
    put(base, 'id', 0)
    put(base, 'sta', 2)
    put(base, 'pic', page_id)
    events = dict(load=['printh 88 ff ff ff'] if page_id == 0 else [], loadend=[], down=[], up=[], unload=[])
    objects = [object_bytes(base, events)]
    # The common geometry attributes come from a real TJC page, retaining widths.
    common = {k: v for k, v in base.items() if k not in ('up', 'down', 'left', 'right', 'sta', 'bco', 'pic')}
    for row in rows:
        component = int(row['component_id'])
        a = copy.deepcopy(common)
        put(a, 'type', 109)
        put(a, 'id', component)
        put(a, 'objname', 'm%d' % component)
        # Explicit protocol frames avoid dependence on checkbox bit definitions.
        put(a, 'sendkey', 0)
        x0, y0, x1, y1 = (int(row[k]) for k in ('x0', 'y0', 'x1', 'y1'))
        for k, val in dict(x=x0, y=y0, w=x1-x0+1, h=y1-y0+1, endx=x1, endy=y1).items():
            put(a, k, val)
        objects.append(object_bytes(a, {
            'down': ['printh 65 %02x %02x 01 ff ff ff' % (page_id, component)],
            'up': ['printh 65 %02x %02x 00 ff ff ff' % (page_id, component)]}))
    size = 56 + len(objects) * 12 + sum(map(len, objects))
    header = bytearray(seed_page[:56])
    struct.pack_into('<IIII', header, 0, 0, size, 56, len(objects))
    header[24:40] = ('page%d' % page_id).encode().ljust(16, b'\0')
    table, offset = bytearray(), len(objects) * 12
    for body in objects:
        table += struct.pack('<III', offset, len(body), 0)
        offset += len(body)
    return stamped(bytes(header) + table + b''.join(objects), (4,5,6,7,12,13,14,15,20,21))


def picture_blocks(path):
    image = Image.open(path).convert('RGB')
    assert image.size == (480, 272)
    pixels = [((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3) for r,g,b in image.getdata()]
    body = bytes(20) + struct.pack('<%dH' % len(pixels), *pixels)
    # TJC picture marker is 0x60; Nextion's 0x64 must not be used.
    screen = struct.pack('<4sIIHHII', b'\x0a\x60\x01\x03', 0, 24, 480, 272, len(body), 0) + body
    png = path.read_bytes()
    source = struct.pack('<4sIIHHII', b'\x0a\x60\x01\x01', 0, 27, 480, 272, len(png), 0) + b'png' + png
    return source, screen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'museum_touch_480x272.HMI')
    args = parser.parse_args()
    seed = read_container(args.seed)
    manifest = seed['main.HMI']
    # The exact factory model ID, obtained from its official project.
    if manifest[16:20] != bytes.fromhex('ca7c7f18'):
        raise ValueError('Seed is not the verified TJC4827T143 factory model')
    with (ROOT / 'component_map.csv').open(encoding='utf-8-sig', newline='') as stream:
        rows = list(csv.DictReader(stream))
    by_page = [[r for r in rows if int(r['page_id']) == p] for p in range(12)]
    blocks = {'Program.s': b'int sys0=0,sys1=0,sys2=0\r\nbaud=9600\r\ndim=85\r\nrecmod=0\r\nbkcmd=0\r\npage 0\r\n'}
    seed_page = next(v for k,v in seed.items() if k.endswith('.pa'))
    for p, page_rows in enumerate(by_page):
        assert [int(r['component_id']) for r in page_rows] == list(range(1, len(page_rows)+1))
        blocks['%d.pa' % p] = make_page(seed_page, p, page_rows)
    for p in range(12):
        source, screen = picture_blocks(ROOT / 'pages' / ('page_%02d.png' % p))
        blocks['%d.is' % p], blocks['%d.i' % p] = source, screen
    resources = [('i', '%d.i' % p) for p in range(12)] + [('pa', '%d.pa' % p) for p in range(12)]
    header = bytearray(manifest[:96])
    struct.pack_into('<I', header, 28, len(resources))
    rebuilt = bytes(header) + b''.join(struct.pack('<8s8s', k.encode(), v.encode()) for k,v in resources)
    tail = [rebuilt[i] for i in (4,5,6,7)] + [0]*6
    old_tail = [manifest[i] for i in (4,5,6,7)] + [0]*6
    stamp = crc(list(rebuilt[4:]) + tail) ^ crc(list(manifest[4:]) + old_tail) ^ int.from_bytes(manifest[:4], 'little')
    blocks['main.HMI'] = struct.pack('<I', stamp) + rebuilt[4:]
    output = write_container(blocks)
    args.output.write_bytes(output)
    assert read_container(args.output) == blocks
    report = {'model':'TJC4827T143_011R_P20', 'baud':9600, 'size':[480,272],
              'pages':12,'touch_regions':len(rows),'hmi_sha256':hashlib.sha256(output).hexdigest(),
              'validation':'container round-trip passed; vendor compilation required'}
    (ROOT / 'hmi_build_manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__ == '__main__':
    main()
