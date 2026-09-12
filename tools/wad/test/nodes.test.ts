import { describe, expect, it } from "vitest";
import { extractMap } from "../src/mapExtract.js";
import { BBox, NODE_LEAF_FLAG, Node, Subsector, Vertex } from "../src/types.js";
import { Wad } from "../src/wad.js";
import { hasRealWad, readRealWad } from "./realWad.js";
import { buildWad, nodeLump, segLump, subsectorLump, vertexLump } from "./testWad.js";

function within(bbox: BBox, v: Vertex): boolean {
  return v.x >= bbox.left && v.x <= bbox.right && v.y >= bbox.bottom && v.y <= bbox.top;
}

/** Every vertex referenced (directly or transitively) by the subtree rooted at `child`. */
function subtreeVertices(
  nodes: Node[],
  subsectors: Subsector[],
  segVertexPairs: [number, number][],
  vertexes: Vertex[],
  child: number,
  out: Vertex[] = [],
): Vertex[] {
  if (child & NODE_LEAF_FLAG) {
    const ss = subsectors[child & 0x7fff]!;
    for (let i = 0; i < ss.numSegs; i++) {
      const [v1, v2] = segVertexPairs[ss.firstSeg + i]!;
      out.push(vertexes[v1]!, vertexes[v2]!);
    }
  } else {
    const node = nodes[child]!;
    subtreeVertices(nodes, subsectors, segVertexPairs, vertexes, node.rightChild, out);
    subtreeVertices(nodes, subsectors, segVertexPairs, vertexes, node.leftChild, out);
  }
  return out;
}

describe("NODES bounding boxes contain their children", () => {
  it("synthetic: a 2-node tree where each child's bbox must contain its subsector's vertices", () => {
    // 4 vertices forming two triangles, one seg each, one subsector each.
    const vertexes = vertexLump([[-10, -10], [10, -10], [0, 10], [50, 50]]);
    const segs = segLump([
      { v1: 0, v2: 1, angle: 0, linedef: 0, direction: 0, offset: 0 },
      { v1: 2, v2: 3, angle: 0, linedef: 0, direction: 0, offset: 0 },
    ]);
    const ssectors = subsectorLump([
      { numSegs: 1, firstSeg: 0 },
      { numSegs: 1, firstSeg: 1 },
    ]);
    const nodes = nodeLump([
      {
        x: 0,
        y: 0,
        dx: 1,
        dy: 0,
        rightBBox: [-10, -10, -10, 10], // must contain vertexes[0..1]
        leftBBox: [50, 10, 0, 50], // must contain vertexes[2..3]
        rightChild: NODE_LEAF_FLAG | 0,
        leftChild: NODE_LEAF_FLAG | 1,
      },
    ]);

    const wad = Wad.fromBuffer(
      buildWad([
        { name: "T1M1", data: Buffer.alloc(0) },
        { name: "THINGS", data: Buffer.alloc(0) },
        { name: "LINEDEFS", data: Buffer.alloc(0) },
        { name: "SIDEDEFS", data: Buffer.alloc(0) },
        { name: "VERTEXES", data: vertexes },
        { name: "SEGS", data: segs },
        { name: "SSECTORS", data: ssectors },
        { name: "NODES", data: nodes },
        { name: "SECTORS", data: Buffer.alloc(0) },
        { name: "REJECT", data: Buffer.alloc(0) },
        { name: "BLOCKMAP", data: Buffer.alloc(8) },
      ]),
    );
    const map = extractMap(wad, "T1M1");
    const node = map.nodes[0]!;
    const segPairs: [number, number][] = map.segs.map((s) => [s.startVertex, s.endVertex]);
    for (const [child, bbox] of [
      [node.rightChild, node.rightBBox],
      [node.leftChild, node.leftBBox],
    ] as const) {
      const verts = subtreeVertices(map.nodes, map.subsectors, segPairs, map.vertexes, child);
      expect(verts.length).toBeGreaterThan(0);
      for (const v of verts) expect(within(bbox, v)).toBe(true);
    }
  });

  it.skipIf(!hasRealWad)("real E1M1: every node's bbox contains every vertex of its subtree", () => {
    const wad = Wad.fromBytes(readRealWad());
    const map = extractMap(wad, "E1M1");
    const segPairs: [number, number][] = map.segs.map((s) => [s.startVertex, s.endVertex]);

    let checked = 0;
    for (const node of map.nodes) {
      for (const [child, bbox] of [
        [node.rightChild, node.rightBBox],
        [node.leftChild, node.leftBBox],
      ] as const) {
        const verts = subtreeVertices(map.nodes, map.subsectors, segPairs, map.vertexes, child);
        for (const v of verts) {
          expect(within(bbox, v), `vertex (${v.x},${v.y}) outside bbox ${JSON.stringify(bbox)}`).toBe(true);
        }
        checked += verts.length;
      }
    }
    expect(checked).toBeGreaterThan(0);
  });
});
