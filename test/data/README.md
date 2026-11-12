# Test data

Three inputs for the compressor tests. Each stands for data Loomwork
compresses. They are committed as bytes; none is rebuilt by the tests.

## bc7.bin (589,824 bytes): texture blocks

BC7 blocks, 16 bytes per 4x4 block, 192 x 192 blocks.

- Encoder: zig-bcn, commit 7db37c76fe14a625c3aab1b7e949c5713d23e86f
  (v0.3.0), `bcn.bc7.encodeImage`.
- Image: zig-bcn has only small procedural test images (61 x 47), so this is
  a 768 x 768 RGBA image made for this file. It is layered value noise
  through a rock and soil colour ramp, with domain warping, dark ridged
  cracks, a little per-pixel grain and a small per-cell tint. Alpha is 255.
  It is fully deterministic: integer hashes and a fixed seed, no clock or
  random source.
- Settings: `bcn.bc7.Params.init(.basic, true)`: level basic, perceptual
  error.
- Made by a small program outside this repository that builds the image,
  calls `encodeImage` once and writes the blocks.

## mesh.bin (278,982 bytes): mesh streams

Encoded vertex and index streams of the pirate demo mesh, back to back.

- Encoders: zig-meshoptimizer, commit c1c8714b2c6112573d4061410f034af514f72ebc
  (v0.1.1), which tracks meshoptimizer 1.3.
- Mesh: `demo/pirate.obj` of meshoptimizer 1.3 (commit
  f0a684f11ead064e176775c9b796f82a55910e92), by Clint Bellanger, CC-BY-SA 3.0.
  15,030 triangle corners, 5,010 triangles, 3,152 unique vertices of 8 floats
  (position, normal, texture coordinate).
- Steps: read the OBJ as a triangle soup; `generateVertexRemap` and the indexing it gives; then for each of 6 levels of
  detail (level 0 is the full mesh; each next level is `simplify` to half
  the previous index count, target error 0.5): `optimizeVertexCache`, then
  `optimizeVertexFetch`. Per level, three streams are appended in this
  order: the float vertices (32 bytes each) through `encodeVertexBuffer`,
  the same vertices quantized to 16 bytes each (16-bit unorm positions,
  8-bit snorm normals, 16-bit unorm texture coordinates) through
  `encodeVertexBuffer`, and the index buffer through `encodeIndexBuffer`
  (u32 indices, version 1).
- The mesh is small, so the levels and the two vertex layouts are there to
  reach the size the tests need. They are different encodings of the same
  mesh, so some structure repeats between streams.
- Deterministic: rerunning the steps gives the same bytes.

## snapshot.bin (418,747 bytes): database pages

A snapshot pack of a running Loomwork world. Loomwork's snapshots do not
write B+ tree nodes: the tables' rows are written column by column in
chunks, little endian, and a pack is those chunks one after another. This
is such a pack, byte for byte as the engine wrote it (checksums, manifest
and log are not included).

- Engine: loomwork, commit be19a364f5ebd6e2f95af17dca41f6a8b11bf6c8 (the
  checkout at the time). The server binary was the example game's
  `mmo-server`, built on 10 November from the working tree.
- Table content: the example MMO game's world: terrain height chunks,
  authored rows from its 37 content row files (1,270 rows), and 300 bot
  characters on the server, with the engine's own tables.
- How: `mmo-server --project-files examples/mmo --bots 300 --snapshot-every 10
  --seconds 6 --port 0 --threads 2 --net-threads 1 --log <dir>/world.log`
  run from a scratch folder. It stopped cleanly at tick 180 and wrote a final
  snapshot; this file is `world.log.snap.1-180-18.pack`.
- Not reproducible byte for byte: a rerun gives packs of the same size with
  some different bytes (ids and keys come from the system at run time).
