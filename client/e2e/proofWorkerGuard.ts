export async function guardWorkers(page: import("@playwright/test").Page): Promise<void> {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "hardwareConcurrency", { value: 3 });
    const Native = Worker;
    const workers: { url: string; dead: boolean }[] = [];
    (window as any).proofWorkerAudit = { workers, proves: 0 };
    window.Worker = class extends Native {
      private audit: { url: string; dead: boolean };
      constructor(url: string | URL, options?: WorkerOptions) {
        super(url, options); this.audit = { url: String(url), dead: false }; workers.push(this.audit);
      }
      override postMessage(message: any, transfer?: any): void {
        if (message.op === "prove") { (window as any).proofWorkerAudit.proves++; throw new Error("This test prohibits proof generation"); }
        super.postMessage(message, transfer);
      }
      override terminate(): void { this.audit.dead = true; super.terminate(); }
    };
  });
}
