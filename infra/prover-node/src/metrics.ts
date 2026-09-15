// SPDX-License-Identifier: Apache-2.0
/** Simple counters and per-stage durations, persisted as `<work>/metrics.json`. */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export interface StageTiming {
  count: number;
  totalMs: number;
  maxMs: number;
}

export interface Metrics {
  startedAt: string;
  polls: number;
  lastPollAt: string | null;
  commitmentsSeen: number;
  selected: number;
  skipped: number;
  registered: number;
  /** Runs recorded whose member submission paid no bounty (no `CommitmentProved`). */
  unsettled: number;
  refused: number;
  failed: number;
  lostRace: number;
  segmentsCut: number;
  segmentsProved: number;
  proofFailures: number;
  /** Sum of the bounties of the runs this node registered (FRI, decimal). */
  bountyClaimedFri: string;
  stages: Record<string, StageTiming>;
}

export function emptyMetrics(): Metrics {
  return {
    startedAt: new Date().toISOString(),
    polls: 0,
    lastPollAt: null,
    commitmentsSeen: 0,
    selected: 0,
    skipped: 0,
    registered: 0,
    unsettled: 0,
    refused: 0,
    failed: 0,
    lostRace: 0,
    segmentsCut: 0,
    segmentsProved: 0,
    proofFailures: 0,
    bountyClaimedFri: "0",
    stages: {},
  };
}

type Counter = {
  [K in keyof Metrics]: Metrics[K] extends number ? K : never;
}[keyof Metrics];

export class MetricsFile {
  readonly data: Metrics;

  constructor(private readonly path: string | null) {
    this.data = path && existsSync(path) ? { ...emptyMetrics(), ...(JSON.parse(readFileSync(path, "utf8")) as Metrics) } : emptyMetrics();
  }

  bump(name: Counter, by = 1): void {
    this.data[name] += by;
    this.save();
  }

  addBounty(fri: bigint): void {
    this.data.bountyClaimedFri = (BigInt(this.data.bountyClaimedFri) + fri).toString();
    this.save();
  }

  time(stage: string, ms: number): void {
    const t = (this.data.stages[stage] ??= { count: 0, totalMs: 0, maxMs: 0 });
    t.count++;
    t.totalMs += ms;
    t.maxMs = Math.max(t.maxMs, ms);
    this.save();
  }

  poll(): void {
    this.data.polls++;
    this.data.lastPollAt = new Date().toISOString();
    this.save();
  }

  save(): void {
    if (!this.path) return;
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(this.path, JSON.stringify(this.data, null, 1));
  }
}
