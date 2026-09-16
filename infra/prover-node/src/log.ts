// SPDX-License-Identifier: Apache-2.0
/** The logbook: one timestamped line per event, to stderr and to `<work>/logbook.txt`. */
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type Level = "info" | "warn" | "error";

export class Logbook {
  constructor(
    private readonly file: string | null,
    private readonly sink: (line: string) => void = (l) => process.stderr.write(l + "\n"),
  ) {
    if (file) mkdirSync(dirname(file), { recursive: true });
  }

  private write(level: Level, message: string, id?: string): void {
    const line = `${new Date().toISOString()} ${level.padEnd(5)} ${id ? `[${id.slice(0, 12)}] ` : ""}${message}`;
    this.sink(line);
    if (this.file) appendFileSync(this.file, line + "\n");
  }

  info(message: string, id?: string): void {
    this.write("info", message, id);
  }

  warn(message: string, id?: string): void {
    this.write("warn", message, id);
  }

  error(message: string, id?: string): void {
    this.write("error", message, id);
  }

  /** A logger bound to one commitment, for the stages. */
  for(id: string): (message: string) => void {
    return (message) => this.info(message, id);
  }
}
