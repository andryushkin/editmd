// editmd-pi-status-extension
//
// Pi lifecycle extension. Uses the installed EditMD status wrapper so it is a
// no-op outside EditMD (wrapper exits 0 when the socket is missing).

import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const wrapper = join(homedir(), ".config", "editmd", "agent-status", "editmd-agent-status.sh");

  async function report(args: string[]): Promise<void> {
    try {
      await pi.exec(wrapper, args, { timeout: 1_000 });
    } catch {
      // Advisory only — never interrupt Pi's agent loop.
    }
  }

  pi.on("agent_start", async () => {
    await report(["active", "--harness", "pi"]);
  });

  pi.on("agent_settled", async () => {
    await report(["completed", "--harness", "pi"]);
  });
}
