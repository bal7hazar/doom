import type { CairoClient } from "./cairoClient.js";
import type { CairoScheduler } from "./cairoScheduler.js";

/** A cached document keeps its exact VM/journal and the user's running/paused choice. */
export function bindCairoPageLifecycle(
  scheduler: Pick<CairoScheduler, "isRunning" | "start" | "stop" | "dispose">,
  client: Pick<CairoClient, "dispose">,
): void {
  let cached = false;
  let resumeOnReturn = false;
  const show = (event: PageTransitionEvent): void => {
    if (!event.persisted || !cached) return;
    cached = false;
    if (resumeOnReturn) scheduler.start();
  };
  const hide = (event: PageTransitionEvent): void => {
    if (event.persisted) {
      if (!cached) resumeOnReturn = scheduler.isRunning;
      cached = true;
      scheduler.stop();
    } else {
      window.removeEventListener("pagehide", hide);
      window.removeEventListener("pageshow", show);
      scheduler.dispose();
      client.dispose();
    }
  };
  window.addEventListener("pagehide", hide);
  window.addEventListener("pageshow", show);
}
