# 1. Revert to the pre-splice state.
mv /Users/ian/Documents/Projects/terra-range/modules/azure/ansible/roles/adaptix_payload/tasks/main.yml.bak \
   /Users/ian/Documents/Projects/terra-range/modules/azure/ansible/roles/adaptix_payload/tasks/main.yml

# 2. Re-run the same splice oneliner you ran before (it now reads the
#    updated snippet file with curl tasks).
python3 << 'PY'
import re, pathlib
target = pathlib.Path("/Users/ian/Documents/Projects/terra-range/modules/azure/ansible/roles/adaptix_payload/tasks/main.yml")
snippet_path = pathlib.Path("/Users/ian/Documents/Dev-Share/test-diagram-creator/adaptix-listener-reconcile.yml")
src = target.read_text()
if "Adaptix — log in (curl)" in src:
    print("snippet already present, no change"); raise SystemExit(0)
lines = snippet_path.read_text().splitlines()
first = next(i for i, ln in enumerate(lines) if ln.startswith("- name:"))
ins = "\n".join(lines[first:]) + "\n\n"
m = re.search(r"^- name: Build all matrix payloads.*$", src, re.MULTILINE)
if not m: raise SystemExit("anchor task not found")
target.with_suffix(target.suffix + ".bak").write_text(src)
target.write_text(src[:m.start()] + ins + src[m.start():])
print(f"inserted at offset {m.start()}; backup at {target}.bak")
PY

# 3. Re-run the role.
./range repair --tags adaptix_payload
