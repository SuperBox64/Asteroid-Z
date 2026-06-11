import os, sys
src, out = sys.argv[1], sys.argv[2]
lines = ["#include <stdint.h>"]
entries = []
for i, name in enumerate(sorted(os.listdir(src))):
    if not name.endswith(".wav"):
        continue
    data = open(os.path.join(src, name), "rb").read()
    lines.append(f"static const unsigned char a{i}[] = {{{','.join(str(b) for b in data)}}};")
    entries.append((name, f"a{i}", len(data)))
lines.append("static const struct { const char *n; const unsigned char *d; uint32_t l; } tbl[] = {")
for n_, s_, l_ in entries:
    lines.append(f'    {{"{n_}", {s_}, {l_}}},')
lines.append("};")
lines.append("""const unsigned char *kit_asset_data(const char *name, uint32_t *len) {
    for (unsigned i = 0; i < sizeof(tbl)/sizeof(tbl[0]); i++) {
        const char *a = tbl[i].n, *b = name;
        while (*a && *a == *b) { a++; b++; }
        if (*a == *b) { *len = tbl[i].l; return tbl[i].d; }
    }
    *len = 0; return 0;
}""")
open(out, "w").write("\n".join(lines))
