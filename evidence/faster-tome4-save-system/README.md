# Save-system technical analysis evidence

The [technical report](../../docs/tome4-save-system.md) distinguishes implemented
0.2.10 behavior, read-only measurements and unimplemented candidate designs.

- `zip_inventory.py` / `grok-zip-check.json`: independent ZIP-header count on the original character
  directory used by the separate Grok 4.6 review. 15 of 21 region archives contain
  20 Player entries; the main archive contains one more. Counts alone do not prove
  which graph can safely be removed. No serialized Lua was executed.
- `inventory_ids.py` / `inventory-ids.json`: strict parse of only `in_inven`
  values on the same original dataset. IDs include table, number and string;
  all observed table IDs contain a numeric inner ID, which is not by itself
  proof that canonicalizing every instance is safe. Object reference occurrences
  are not unique-object counts. The script uses `map-fields.py` next to it.
- `map-fields.py` / `map-fields.json`: field sizes on the preserved 0.2.8
  dataset, 60 Map entries. Explicit false and numeric visibility cells are
  counted. Deleting visibility assignments in memory is a deliberately
  destructive cost probe, not a valid optimization or a bit-packing result.
- `block_proxy.py` / `block-proxy.json`: seven rounds of preassembled block
  compression after reversible short naming, at the original level 4. Includes
  setup, original payload compression checks, raw timings and file hashes.
  It excludes assembly, index creation, serialization, ZIP packaging, I/O,
  reader reconstruction and full-save scheduling. Blocks do not split objects;
  the 64/256 KiB targets are not memory limits for oversized objects.
- `source-manifest.json`: artifact checksums and the pinned engine revision.

Map and block experiments use the 21.908 MB preserved Faster 0.2.8 character
directory. The Grok review and inventory checks use the 22.209 MB original
directory. Their history archives overlap, but the main save, screenshot and
log differ; do not merge the totals as if they were one run. All source file
hashes match before and after the corresponding audit. Player archives, decoded
object graphs and runtime assets remain local. These analyses do not add any
new optimization to the production addon beyond already completed short names.

The map and inventory scripts accept a source directory and output JSON path.
The block proxy accepts `--source` and `--output`; its `ROOT` and the expected
source manifest identify the recorded local workspace. Adjust the workspace
path if reproducing elsewhere, retaining the source checksum gate.
