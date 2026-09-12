import { existsSync } from "node:fs";
import { join } from "node:path";

// Mirrors scripts/fetch-freedoom.sh's default output location.
const DEFAULT_FREEDOOM_DIR =
  "/private/tmp/claude-501/-Users-bal7hazar-git-doom/052c133d-8e48-4871-8024-3d2fd1081b4c/scratchpad/freedoom";

export const REAL_WAD_PATH = join(process.env.FREEDOOM_DIR ?? DEFAULT_FREEDOOM_DIR, "freedoom1.wad");

export const hasRealWad = existsSync(REAL_WAD_PATH);
