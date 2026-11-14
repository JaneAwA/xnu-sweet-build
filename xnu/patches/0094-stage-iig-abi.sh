#!/bin/bash
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
#
# Xcode 16 replaced iig. The new iig writes an IORPC.kernelContent field into
# the .iig.cpp files it generates, but the open source IORPC.h (both copies)
# has no such member, so DriverKit fails to compile with:
#
#     no member named 'kernelContent' in 'IORPC'
#
# The field exists only in Apple's closed header. Add it -- once, at the end of
# the struct, which is ABI-additive -- but only when the toolchain is Xcode 16
# or newer. On Xcode 15 the header must stay untouched, because that iig never
# emits the field and DriverKit sizes the struct itself.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0

xcode_major=$(xcodebuild -version 2>/dev/null | awk '/^Xcode /{print $2}' | cut -d. -f1)
if [[ -z ${xcode_major:-} || ${xcode_major} -lt 16 ]]; then
	echo "iig ABI: Xcode ${xcode_major:-unknown}, header left alone"
	exit 0
fi

patched=0
for f in iokit/DriverKit/IORPC.h iokit/IOKit/IORPC.h; do
	[[ -f $f ]] || continue
	if grep -q 'kernelContent' "$f"; then
		echo "iig ABI: $f already carries kernelContent"
		continue
	fi
	python3 - "$f" <<'PY'
import re
import sys

path = sys.argv[1]
src = open(path, encoding='utf-8').read()

m = re.search(r'struct\s+IORPC\s*\{(?P<body>[^}]*)\};', src)
if not m:
    sys.exit('%s: struct IORPC not found' % path)

body = m.group('body')
if 'kernelContent' in body:
    sys.exit(0)

# Match the indentation style the file already uses.
indent = '\t'
line = re.search(r'\n([\t ]+)\S', body)
if line:
    indent = line.group(1)

addition = '%sIORPCMessage     * kernelContent;\n' % indent
new_body = body.rstrip('\n') + '\n' + addition
out = src[:m.start('body')] + new_body + src[m.end('body'):]
open(path, 'w', encoding='utf-8').write(out)
print('iig ABI: added kernelContent to %s' % path)
PY
	patched=$((patched + 1))
done

if [[ $patched -eq 0 ]]; then
	echo "iig ABI: nothing to do"
fi

grep -n 'kernelContent' iokit/DriverKit/IORPC.h iokit/IOKit/IORPC.h || true
