import re, sys
text = open(sys.argv[1]).read()
protos = re.findall(r"WABI\s+([^;]+);", text)
implemented = {
    "js_log","gfx_clear","gfx_save","gfx_restore","gfx_translate","gfx_rotate",
    "gfx_scale","gfx_set_alpha","gfx_set_blend","gfx_stroke_poly","gfx_fill_poly",
    "gfx_fill_circle","gfx_stroke_circle","gfx_fill_rect","gfx_stroke_rect",
    "evt_poll","snd_by_name","snd_play","snd_stop","snd_set_volume","snd_set_pan",
    "store_get","store_set","gp_connected",
}
lines = ['#include "KitABI.h"', "#include <stdlib.h>",
         "double _swift_stdlib_strtod_clocale(const char *s, char **e){ return strtod(s,e); }"]
for p in protos:
    p = " ".join(p.split())
    m = re.match(r"([A-Za-z0-9_*\s]+?)\s*\b([a-z_0-9]+)\s*\(", p)
    if not m or m.group(2) in implemented:
        continue
    lines.append(p + (" {}" if m.group(1).strip() == "void" else " { return 0; }"))
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
