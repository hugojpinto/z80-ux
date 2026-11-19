# =====================================================================
# ZX-UX 48K Sinclair ZX Spectrum Unix.
# Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
# Non-commercial use only under the repository LICENSE.
# Commercial use prohibited without separate written permission.
# =====================================================================
"""The 48K Spectrum's keyboard, as the clean-room INKEY$ reads it
(libux/rbc/keyboard.asm; libux/build.py writes its table from this).

ROWS: the eight half-rows, by the port's high byte, their keys from bit 0.
LEGENDS: what each key gives - unshifted, with CAPS SHIFT, with SYMBOL
SHIFT, with both - as the keys and the manual show them: letters, digits,
the cursor and editing codes on CAPS + digit, the symbols and keywords on
SYMBOL SHIFT.
"""
from rbc.bas2tap import TOKENS

PORT = 0xFE                     # the ULA's port: the row is picked by the high byte
ROWS = [(0xFE, ['CAPS', 'Z', 'X', 'C', 'V']),
        (0xFD, ['A', 'S', 'D', 'F', 'G']),
        (0xFB, ['Q', 'W', 'E', 'R', 'T']),
        (0xF7, ['1', '2', '3', '4', '5']),
        (0xEF, ['0', '9', '8', '7', '6']),
        (0xDF, ['P', 'O', 'I', 'U', 'Y']),
        (0xBF, ['ENTER', 'L', 'K', 'J', 'H']),
        (0x7F, ['SPACE', 'SYMBOL', 'M', 'N', 'B'])]
SHIFTS = ('CAPS', 'SYMBOL')
CODE = {v: k for k, v in TOKENS.items()}

# SYMBOL SHIFT: a symbol, or a keyword's code
SYMBOL = {'A': 'STOP', 'S': 'NOT', 'D': 'STEP', 'F': 'TO', 'G': 'THEN', 'H': '^', 'J': '-',
          'K': '+', 'L': '=', 'Q': '<=', 'W': '<>', 'E': '>=', 'R': '<', 'T': '>', 'Y': 'AND',
          'U': 'OR', 'I': 'AT', 'O': ';', 'P': '"', 'Z': ':', 'X': '\x60', 'C': '?', 'V': '/',
          'B': '*', 'N': ',', 'M': '.', '1': '!', '2': '@', '3': '#', '4': '$', '5': '%',
          '6': '&', '7': "'", '8': '(', '9': ')', '0': '_', 'ENTER': '\r', 'SPACE': ' '}
# CAPS SHIFT on the digits: EDIT, CAPS LOCK, TRUE VIDEO, INV. VIDEO, the
# cursor keys, GRAPHICS, DELETE
# CAPS SHIFT with SYMBOL SHIFT (as the key): EXTEND MODE
EXTEND = 0x0E
CAPS_DIGIT = {'1': 0x07, '2': 0x06, '3': 0x04, '4': 0x05, '5': 0x08, '6': 0x0A, '7': 0x0B,
              '8': 0x09, '9': 0x0F, '0': 0x0C}


def code_of(x):
    if isinstance(x, int):
        return x
    return CODE[x] if x in CODE and len(x) > 1 else ord(x)


def legends(key):
    """(unshifted, CAPS, SYMBOL, both) codes of a key.  (With both shifts,
    a key is a third key held: none.)"""
    if key == 'ENTER':
        return (0x0D,) * 4
    if key == 'SPACE':
        return (0x20,) * 4
    if key.isdigit():
        plain, caps = ord(key), CAPS_DIGIT[key]
    else:
        plain, caps = ord(key.lower()), ord(key)
    sym = code_of(SYMBOL[key])
    return (plain, caps, sym, sym)


def table():
    """40 keys (row by row, bit by bit) x 4: the bytes of the table; the
    shift keys' own rows hold 0FFh."""
    out = []
    for _, keys in ROWS:
        for k in keys:
            if k == 'SYMBOL':           # the key itself, under CAPS: EXTEND MODE
                out += [0xFF, EXTEND, 0xFF, 0xFF]
            else:
                out += [0xFF] * 4 if k in SHIFTS else list(legends(k))
    return out


def index(key):
    i = 0
    for _, keys in ROWS:
        for k in keys:
            if k == key:
                return i
            i += 1
    raise KeyError(key)
