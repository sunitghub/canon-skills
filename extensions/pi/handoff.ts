/**
 * Pi extension — Handoff session context protocol.
 *
 * On session_start: injects HANDOFF.md into the conversation if it exists
 * in the project root (once per session, not on every turn).
 *
 * HANDOFF.md itself is refreshed by sprint's own protocol (sprint start's
 * context-read step, wrapup's explicit refresh) — this extension only reads
 * it, it does not write it.
 *
 * Install:
 *   Global:  copy to ~/.pi/agent/extensions/handoff.ts
 *   Project: copy to .pi/extensions/handoff.ts
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { existsSync, readFileSync } from "fs";
import { join } from "path";

const MAX_LINES = 80;

export default function (pi: ExtensionAPI) {
  let injectedThisSession = false;

  // On session start: reset injection flag, warn if HANDOFF.md is oversized
  pi.on("session_start", async (_, ctx) => {
    injectedThisSession = false;
    const handoffPath = join(ctx.cwd, "HANDOFF.md");
    if (!existsSync(handoffPath)) return;

    const content = readFileSync(handoffPath, "utf-8");
    const lineCount = content.split("\n").length;

    if (lineCount > MAX_LINES) {
      ctx.ui.notify(
        `[handoff] HANDOFF.md is ${lineCount} lines (limit: ${MAX_LINES}). Consider pruning stale entries.`,
        "warning"
      );
    }
  });

  // Prepend HANDOFF.md to the first user input of each session
  pi.on("input", async (event, ctx) => {
    if (injectedThisSession) return event;
    const handoffPath = join(ctx.cwd, "HANDOFF.md");
    if (!existsSync(handoffPath)) return event;

    injectedThisSession = true;
    const content = readFileSync(handoffPath, "utf-8");
    const prefix = `[handoff] Resuming — context from last session:\n---\n${content}\n---\n[handoff] Read the above before doing anything else.\n\n`;

    return { ...event, text: prefix + (event.text ?? "") };
  });
}
