#!/usr/bin/env python3
"""t-f889: theme files for tests/theme-files-parity.sh.

  build <dir>             write the fixed corpus into <dir>/b0, b1, ... (at most 40 .json entries each, under the
                          50-file limit); print {batch: {file: expected reason ("" = accepted)}} as JSON
  many <dir>              51 valid files (the 51st is over the limit)
  fuzz <dir> <n> <seed>   n random hostile files (no expectations: the three validators must only agree)
  schema <schema> <json>  print "valid"/"invalid" for one parsed theme by theme.schema.json (an independent check)
"""
import json, os, random, re, sys

KEYS = ['bg', 'surface', 'border', 'text', 'body', 'muted', 'accent', 'ok', 'warn', 'bad', 'info', 'term']
GOOD = {'name': 'Fixture Dark', 'mode': 'dark', 'colors': {
    'bg': '#1f2430', 'surface': '#272d3a', 'border': '#3a4252', 'text': '#eef1f6', 'body': '#c4cad6',
    'muted': '#a3abba', 'accent': '#5aa9e6', 'ok': '#6cc070', 'warn': '#e6b450', 'bad': '#ef6b73',
    'info': '#79b8ff', 'term': '#171b24'}}

R_OBJ = 'must be an object with exactly name, mode and colors'
R_NAME = 'name must be 1-40 letters, digits, spaces or . _ ( ) + -'
R_MODE = 'mode must be light or dark'
R_KEYS = 'colors must have exactly the 12 keys'
R_FILE = 'file name must be lowercase letters, digits and dashes (at most 30)'
R_JSON = 'not valid JSON'

def theme(**kw):
    t = json.loads(json.dumps(GOOD))
    for k, v in kw.items():
        if k == 'colors_update':
            t['colors'].update(v)
        else:
            t[k] = v
    return t

def put(d, name, data):
    with open(os.path.join(d, name), 'wb') as f:
        f.write(data if isinstance(data, bytes) else json.dumps(data).encode())

def build(top):
    exp = {}
    state = {'n': 0, 'dir': None}
    def slot(name, reason):
        # a new batch every 40 entries; returns the folder this entry goes in
        if state['n'] % 40 == 0:
            state['dir'] = os.path.join(top, f'b{state["n"] // 40}')
            os.makedirs(state['dir'])
            exp[os.path.basename(state['dir'])] = {}
        state['n'] += 1
        exp[os.path.basename(state['dir'])][name] = reason
        return state['dir']
    def case(name, data, reason):
        put(slot(name, reason), name, data)
    # accepted
    case('valid-long.json', GOOD, '')
    case('valid-short.json', theme(colors_update={'bg': '#1Fa', 'term': '#000'}), '')
    case('light-one.json', theme(name='Fixture Light', mode='light'), '')
    case('name-40.json', theme(name='A' * 40), '')
    case('name-chars.json', theme(name='My Theme (v2.1) + extra_-'), '')
    case('a' * 30 + '.json', GOOD, '')
    case('ws.json', ('\n\t ' + json.dumps(GOOD, indent=4) + ' \r\n').encode(), '')
    case('escaped-keys.json', b'{"n\\u0061me":"Esc","mode":"dark","colors":' + json.dumps(GOOD['colors']).encode() + b'}', '')
    case('dup-last-valid.json', b'{"name":"<b>x</b>","name":"Dup","mode":"dark","colors":' + json.dumps(GOOD['colors']).encode() + b'}', '')
    pad = json.dumps(GOOD).encode()
    case('exact-16k.json', pad + b' ' * (16384 - len(pad)), '')
    # file level
    for n in ('Upper.json', '.hidden.json', 'a_b.json', 'with space.json', 'a' * 31 + '.json', '-dash.json', 'café.json'):
        case(n, GOOD, R_FILE)
    d = slot('link.json', 'symbolic links are not read')  # same batch as valid-long.json, its target
    os.symlink('valid-long.json', os.path.join(d, 'link.json'))
    d = slot('dangling.json', 'symbolic links are not read'); os.symlink('nowhere.json', os.path.join(d, 'dangling.json'))
    d = slot('dir.json', 'not a regular file'); os.mkdir(os.path.join(d, 'dir.json'))
    os.mkdir(os.path.join(d, 'sub')); put(os.path.join(d, 'sub'), 'inner.json', GOOD)  # never read: not listed
    put(d, 'notes.txt', b'ignored')  # not .json: not listed
    if hasattr(os, 'mkfifo'):
        d = slot('fifo.json', 'not a regular file'); os.mkfifo(os.path.join(d, 'fifo.json'))
    case('big.json', pad + b' ' * (16385 - len(pad)), 'larger than 16 KiB')
    case('bom.json', b'\xef\xbb\xbf' + pad, 'starts with a byte order mark')
    case('latin1.json', pad.replace(b'Fixture', b'Fixt\xfcre'), 'not valid UTF-8')
    case('surrogate-bytes.json', pad.replace(b'Fixture', b'Fix\xed\xa0\x80'), 'not valid UTF-8')
    case('deep-9.json', b'[' * 9 + b']' * 9, 'nested too deeply')
    case('deep-8.json', b'[' * 8 + b']' * 8, R_OBJ)
    case('deep-unclosed.json', b'{' * 40, 'nested too deeply')
    case('brackets-in-string.json', theme(name='[' * 20), R_NAME)
    case('escaped-quote.json', b'{"name":"a\\"' + b'[' * 20 + b'","mode":"dark","colors":{}}', R_NAME)
    case('empty.json', b'', R_JSON)
    case('nan.json', b'{"name":NaN,"mode":"dark","colors":{}}', R_JSON)
    case('inf.json', b'{"name":-Infinity,"mode":"dark","colors":{}}', R_JSON)
    case('trailing.json', pad + b' x', R_JSON)
    case('two-objects.json', pad + pad, R_JSON)
    case('ctrl-char.json', pad.replace(b'Fixture', b'Fix\x01ture'), R_JSON)
    case('single-quotes.json', b"{'name':'x'}", R_JSON)
    case('comment.json', b'/* c */' + pad, R_JSON)
    # object level
    case('bignum.json', b'{"name":1e999,"mode":"dark","colors":{}}', R_NAME)
    # break-it: Python's int() refuses over 4300 digits where Go reads on; the servers must still agree
    big = b'1' + b'0' * 5000
    case('bigint-colour.json', json.dumps(GOOD).encode().replace(b'"#1f2430"', big, 1), 'colors.bg must be #rgb or #rrggbb')
    case('bigint-top.json', big, R_OBJ)
    case('bigint-name.json', b'{"name":' + b'9' * 4400 + b',"mode":"dark","colors":{}}', R_NAME)
    case('lone-surrogate.json', b'{"name":"\\ud800","mode":"dark","colors":' + json.dumps(GOOD['colors']).encode() + b'}', R_NAME)
    for n, v in (('null', None), ('array', [GOOD]), ('string', 'x'), ('number', 3), ('true', True)):
        case(f'top-{n}.json', v, R_OBJ)
    case('missing-mode.json', {'name': 'x', 'colors': GOOD['colors']}, R_OBJ)
    case('extra-key.json', theme(extra=1), R_OBJ)
    case('proto-key.json', b'{"__proto__":{},"name":"x","mode":"dark","colors":' + json.dumps(GOOD['colors']).encode() + b'}', R_OBJ)
    case('schema-key.json', theme(**{'$schema': 'x'}), R_OBJ)
    for i, v in enumerate(['', 'A' * 41, '<img src=x onerror=alert(1)>', 'a"onmouseover="x', 'café', 'a\tb', 'a\nb', 3, None, ['x'], {'x': 1}, 'x;y', '</style>']):
        case(f'name-bad-{i}.json', theme(name=v), R_NAME)
    for i, v in enumerate(['Dark', 'system', 'LIGHT', 1, None, ['dark'], ' dark', 'dark\n']):
        case(f'mode-bad-{i}.json', theme(mode=v), R_MODE)
    for i, v in enumerate([None, [], 'x', {k: GOOD['colors'][k] for k in KEYS[:11]}, {**GOOD['colors'], 'extra': '#fff'},
                           {**{k: GOOD['colors'][k] for k in KEYS[:11]}, 'Term': '#fff'}]):
        case(f'colors-keys-{i}.json', theme(colors=v), R_KEYS)
    for i, v in enumerate(['url(x)', 'red', '#12345', '#1234567', '#ggg', '#fff;', 'var(--x)', '#fff /* */', '#fff\n', ' #fff',
                           'rgb(1,2,3)', '#fff}body{x:y', 3, None, '#١٢٣', '＃fff']):
        case(f'color-bad-{i}.json', theme(colors_update={'term': v}), 'colors.term must be #rgb or #rrggbb')
    case('color-first.json', theme(colors_update={'term': 'x', 'bg': 'y'}), 'colors.bg must be #rgb or #rrggbb')
    case('dup-last-bad.json', b'{"name":"Dup","name":"<b>","mode":"dark","colors":' + json.dumps(GOOD['colors']).encode() + b'}', R_NAME)
    return exp

def many(d):
    os.makedirs(d, exist_ok=True)
    for i in range(51):
        put(d, f't{i:02d}.json', theme(name=f'T {i}'))

def fuzz(d, n, seed):
    rnd = random.Random(seed)
    os.makedirs(d, exist_ok=True)
    atoms = ['', 'x', '#fff', '#FFFFFF', '#12', '<b>', '"', '\\', '[', '{', '}', ']', ',', ':', 'null', 'true', '1e999', 'NaN',
             'é', '\ud800', '\x00', '\n', '﻿', 'url(', ';', 'dark', 'light', 'name', 'mode', 'colors', 'bg', 'term']
    def val(depth=0):
        r = rnd.random()
        if depth > 3 or r < 0.35:
            return rnd.choice([rnd.choice(atoms), rnd.randint(-5, 5), None, True, 1.5, ''.join(rnd.choice(atoms) for _ in range(rnd.randint(0, 4)))])
        if r < 0.6:
            return [val(depth + 1) for _ in range(rnd.randint(0, 3))]
        return {rnd.choice(atoms + KEYS): val(depth + 1) for _ in range(rnd.randint(0, 4))}
    for i in range(n):
        kind = rnd.random()
        if kind < 0.45:  # a near-valid theme with one or two things broken
            t = theme()
            for _ in range(rnd.randint(1, 2)):
                where = rnd.choice(['name', 'mode', 'colors', 'color', 'drop', 'add'])
                if where == 'color':
                    t['colors'][rnd.choice(KEYS)] = val()
                elif where == 'drop':
                    t.pop(rnd.choice(list(t) or ['name']), None)
                elif where == 'add':
                    t[rnd.choice(atoms)] = val()
                else:
                    t[where] = val()
            data = json.dumps(t, ensure_ascii=rnd.random() < 0.5).encode('utf-8', 'surrogatepass')
        elif kind < 0.75:
            data = json.dumps(val(), ensure_ascii=rnd.random() < 0.5).encode('utf-8', 'surrogatepass')
        else:  # raw bytes: truncated, mutated, nested, binary
            base = bytearray(json.dumps(GOOD).encode())
            op = rnd.choice(['cut', 'flip', 'nest', 'bin', 'insert'])
            if op == 'cut':
                base = base[:rnd.randint(0, len(base))]
            elif op == 'flip':
                for _ in range(rnd.randint(1, 4)):
                    base[rnd.randrange(len(base))] = rnd.randrange(256)
            elif op == 'nest':
                k = rnd.randint(1, 30)
                base = bytearray(b'[' * k + bytes(base) + b']' * rnd.randint(0, k))
            elif op == 'bin':
                base = bytearray(rnd.randbytes(rnd.randint(0, 300)))
            else:
                p = rnd.randrange(len(base))
                base[p:p] = rnd.choice([b'\\', b'"', b'\\u12', b'\xff', b'\x00', b'\n', b'{', b']'])
            data = bytes(base)
        put(d, f'f{i:04d}.json', data)

# A small JSON Schema checker for exactly the constructs theme.schema.json uses (type object/string, required,
# additionalProperties false, properties, enum, pattern, $ref to #/$defs). It reads the schema, not the validators.
def schema_ok(s, v, root):
    if '$ref' in s:
        return schema_ok(root['$defs'][s['$ref'].split('/')[-1]], v, root)
    if 'enum' in s and v not in s['enum']:
        return False
    t = s.get('type')
    if t == 'object':
        if not isinstance(v, dict):
            return False
        if any(k not in v for k in s.get('required', [])):
            return False
        if s.get('additionalProperties') is False and any(k not in s.get('properties', {}) for k in v):
            return False
        return all(schema_ok(s['properties'][k], v[k], root) for k in v if k in s.get('properties', {}))
    if t == 'string':
        if not isinstance(v, str):
            return False
        # JSON Schema patterns are ECMA-262: `$` is the end of input. Python's `$` also matches before a final newline.
        if 'pattern' in s and not re.search(s['pattern'].replace('$', r'\Z'), v):
            return False
    return True

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'build':
        print(json.dumps(build(sys.argv[2])))
    elif cmd == 'many':
        many(sys.argv[2])
    elif cmd == 'fuzz':
        fuzz(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    elif cmd == 'schema':
        root = json.load(open(sys.argv[2]))
        print('valid' if schema_ok(root, json.loads(sys.argv[3]), root) else 'invalid')
