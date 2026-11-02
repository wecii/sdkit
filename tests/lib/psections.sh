#!/usr/bin/env bash
# Run the independent parts of one test file at the same time.
# A test file opts in with one line after `set -u`:
#   [ -n "${PSEC_ONLY:-}" ] || exec "$(dirname "$0")/lib/psections.sh" "$0" "$@"
# The file is cut at every top-level `echo "<section name>"` line. What comes before the first one is the preamble (helpers, stubs, counters): every
# part gets it. The closing `echo "<name>: $pass passed ..."` line is replaced by the totals printed here.
# A section that USES a variable or function which an earlier section (not the preamble, not itself first) defines is chained to that section: the
# chain runs in one process, in file order, and the chains run at the same time. The detection over-approximates (a name in a quoted string counts),
# which only costs parallelism, never correctness. `echo "name"   # with-previous` forces a chain by hand (state that is not a variable, e.g. a
# directory a later section expects). Output is printed in file order; exit 0 only if no part printed a FAIL and every process ended 0.
set -u
f="$1"; dir="$(cd "$(dirname "$f")" && pwd)"; base="$(basename "$f" .sh)"
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
python3 - "$f" "$dir" "$base" "$out" <<'PY' || exit 2
import os, re, sys
f, d, base, out = sys.argv[1:5]
lines = open(f).read().split('\n')
echo_hdr = r'echo "[^"$]*"'; cmt_hdr = r'# --- .* ---'
# one header style per file: `echo "name"` lines when the file has any, else `# --- name ---` comments
style = echo_hdr if any(re.match(r'^' + echo_hdr + r'\s*(#\s*with-previous\s*)?$', l) and 'passed' not in l for l in lines) else cmt_hdr
hdr = re.compile(r'^(?:' + style + r')\s*(#\s*with-previous\s*)?$')
summ = re.compile(r'^echo "[^"]*\$(?:pass|\{pass)[^"]*"')
pre, secs, forced, foot = [], [], [], []
for l in lines:
    if foot or summ.match(l): foot.append(l); continue   # the closing summary and whatever follows it (the exit-status line)
    if hdr.match(l) and 'passed' not in l:
        secs.append([re.sub(r'\s*#\s*with-previous\s*$', '', l)]); forced.append(bool(re.search(r'#\s*with-previous\s*$', l)))
    elif secs: secs[-1].append(l)
    else: pre.append(l)
if not secs: print("psections: no sections in " + f, file=sys.stderr); sys.exit(2)
asg = re.compile(r'^\s*(?:export\s+|local\s+|declare\s+(?:-\w+\s+)?)?([A-Za-z_]\w*)(?:\+)?=')
fn = re.compile(r'^\s*([A-Za-z_][\w-]*)\(\)\s*\{')
use = re.compile(r'\$\{?([A-Za-z_]\w*)')
forl = re.compile(r'\bfor\s+([A-Za-z_]\w*)\s+in\b|\bread\s+(?:-\w+\s+)*([A-Za-z_]\w*)')
hd = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")
def code_lines(chunk):
    """the lines that are shell code: what a heredoc writes (a settings file, a script) is data, not an assignment of this shell"""
    out, tag = [], None
    for l in chunk:
        if tag is not None:
            if l.strip() == tag: tag = None
            continue
        out.append(l)
        m = hd.search(l)
        if m: tag = m.group(1)
    return out
top = re.compile(r'^(?:export\s+)?([A-Za-z_]\w*)(?:\+)?=')
def defs(chunk, toplevel=False):
    s = set()
    for l in code_lines(chunk):
        if toplevel:   # the preamble: only what it sets at the top level reaches a section (a `local` in one of its functions does not)
            m = top.match(l)
            if m: s.add(m.group(1))
            m = fn.match(l)
            if m: s.add(m.group(1))
            continue
        m = asg.match(l)
        if m: s.add(m.group(1))
        m = fn.match(l)
        if m: s.add(m.group(1))
        for m in forl.finditer(l):
            s.update(x for x in m.groups() if x)
    return s
def uses(chunk, names):
    text = '\n'.join(chunk); u = set(m.group(1) for m in use.finditer(text))
    for n in names:   # a function name used as a word
        if re.search(r'(?<![\w$-])' + re.escape(n) + r'(?![\w-])', text): u.add(n)
    return u
P = defs(pre, True)
D = [defs(s) for s in secs]
allnames = set().union(*D) if D else set()
parent = list(range(len(secs)))
def find(x):
    while parent[x] != x: parent[x] = parent[parent[x]]; x = parent[x]
    return x
for i, s in enumerate(secs):
    if forced[i] and i > 0: parent[find(i)] = find(i - 1)
    for v in uses(s, allnames) - D[i] - P:
        for j in range(i - 1, -1, -1):
            if v in D[j]:
                if os.environ.get("PSEC_DEBUG"): print(f"psections: section {i+1} uses {v} from section {j+1}", file=sys.stderr)
                parent[find(i)] = find(j); break
groups = {}
for i in range(len(secs)): groups.setdefault(find(i), []).append(i)
order = sorted(groups.values(), key=lambda g: g[0])
for n, g in enumerate(order, 1):
    with open(f"{d}/_ps_{base}_{n}.sh", 'w') as o:
        o.write('\n'.join(pre) + '\n')
        for i in g: o.write('\n'.join(secs[i]) + '\n')
        o.write('\n'.join(foot) + '\n')
open(out + "/count", 'w').write(str(len(order)))
print(f"psections: {len(secs)} sections in {len(order)} independent chain(s)", file=sys.stderr)
PY
n="$(cat "$out/count")"
i=1
while [ "$i" -le "$n" ]; do
  ( PSEC_ONLY=$i bash "$dir/_ps_${base}_$i.sh" > "$out/$i.out" 2>&1; echo $? > "$out/$i.rc" ) &
  i=$((i + 1))
done
wait
pass=0; fail=0; i=1
while [ "$i" -le "$n" ]; do
  o="$out/$i.out"
  # a part ends with the footer of the original file ("<name>: P passed, F failed"); that line is how the file counts. Without one, count ok/FAIL lines.
  foot="$(grep -E '[0-9]+ passed, [0-9]+ failed' "$o" | tail -1)"
  if [ -n "$foot" ]; then
    p="$(printf '%s' "$foot" | sed -E 's/.*[^0-9]([0-9]+) passed, ([0-9]+) failed.*/\1/')"; q="$(printf '%s' "$foot" | sed -E 's/.*[^0-9]([0-9]+) passed, ([0-9]+) failed.*/\2/')"
    grep -vF -- "$foot" "$o"
  else
    cat "$o"; p="$(grep -c '^  ok ' "$o")"; q="$(grep -c '^  FAIL ' "$o")"
  fi
  pass=$((pass + p)); fail=$((fail + q))
  [ "$(cat "$out/$i.rc")" = 0 ] || [ "$q" -gt 0 ] || { echo "  FAIL part $i ended with status $(cat "$out/$i.rc") and no result"; fail=$((fail + 1)); }
  rm -f "$dir/_ps_${base}_$i.sh"; i=$((i + 1))
done
echo
echo "$base: $pass passed, $fail failed"
[ "$fail" = 0 ]
