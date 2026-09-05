#!/usr/bin/env python3
"""
Convert Octave/Matlab tutorial .m files to RST include fragments.

Convention in .m files:
  %% text    →  RST prose (the leading '%%' and one optional space are stripped;
                trailing %-decoration such as '%%%...' is also stripped)
  All other lines  →  collected into a  .. code-block:: matlab  directive

Everything before the first %% line (boilerplate header, close all, clear,
clc, etc.) is skipped and does not appear in the documentation.
"""

import os
import glob

DOC_DIR = os.path.dirname(os.path.abspath(__file__))


def convert_m_file(in_fn, out_fn):
    with open(in_fn, 'r') as f:
        lines = f.readlines()

    output        = []
    in_header     = True   # skip everything before the first %% line
    in_code       = False
    pending_blanks = 0     # blank lines buffered inside a code block

    for raw in lines:
        line = raw.rstrip('\n')

        # ── skip initial boilerplate ──────────────────────────────────────
        if in_header:
            if line.lstrip().startswith('%%'):
                in_header = False
            else:
                continue

        # ── blank line ───────────────────────────────────────────────────
        if not line.strip():
            if in_code:
                pending_blanks += 1
            # blank lines in RST prose mode are intentionally ignored;
            # paragraph breaks come from the code-block boundary itself
            continue

        # ── RST prose line  (%% ...) ─────────────────────────────────────
        if line.lstrip().startswith('%%'):
            if in_code:
                output.append('')
                in_code = False
                pending_blanks = 0

            # strip leading %% and trailing %-decoration (e.g. %%%%%%%...)
            text = line.lstrip()[2:]        # remove %%
            text = text.rstrip('%').strip() # remove trailing decoration
            output.append(text)

        # ── code line ────────────────────────────────────────────────────
        else:
            if not in_code:
                output.append('')
                output.append('.. code-block:: matlab')
                output.append('')
                in_code = True

            # flush buffered blank lines inside the code block
            for _ in range(pending_blanks):
                output.append('')
            pending_blanks = 0

            output.append('    ' + line)

    if output and output[-1] != '':
        output.append('')

    with open(out_fn, 'w') as f:
        f.write('\n'.join(output))


def main():
    in_path  = os.path.join(DOC_DIR, '..', 'Tutorials')
    out_path = os.path.join(DOC_DIR, 'Tutorials')
    os.makedirs(out_path, exist_ok=True)

    fns = glob.glob(os.path.join(in_path, '*.m'))
    if not fns:
        print('No .m files found in', in_path)
        print('This script must be run from openEMS/matlab/doc/ with the '
              'matlab/Tutorials directory present.')
        return

    count = 0
    for fn in sorted(fns):
        name   = os.path.splitext(os.path.basename(fn))[0]
        out_fn = os.path.join(out_path, '__' + name + '.txt')

        if os.path.isfile(out_fn) and os.path.getmtime(out_fn) > os.path.getmtime(fn):
            print(f'Skipping {name}...')
            count += 1
            continue

        print(f'Converting {name}...')
        convert_m_file(fn, out_fn)
        count += 1

    if count == 0:
        print('No tutorials converted — check that the openEMS submodule is '
              'checked out.')


if __name__ == '__main__':
    main()
