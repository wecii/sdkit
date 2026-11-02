// Runs the kit's guard hooks (secrets, protected paths, frozen tests, prod kubectl, release-flow git) before OpenCode tool calls.
// The hooks are the same bash scripts Claude Code uses; this plugin only translates the call into their input and a
// deny/ask answer into a thrown error. Hooks that exit 0 without a decision allow the call.
// UNVERIFIED against a live OpenCode: tool names (read/edit/write/patch/shell|bash) and whether hooks also fire inside
// subagents. Git hooks (.githooks) remain the backstop either way.
import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import path from "node:path"

const KIT_DIR = "__KIT_DIR__"

const BY_TOOL = {
  read: { tool: "Read", scripts: ["guard-secrets.sh"] },
  write: { tool: "Write", scripts: ["guard-phase.sh", "guard-secrets.sh", "guard-protected.sh", "frozen-tests.sh"] },
  edit: { tool: "Edit", scripts: ["guard-phase.sh", "guard-secrets.sh", "guard-protected.sh", "frozen-tests.sh"] },
  patch: { tool: "Edit", scripts: ["guard-phase.sh", "guard-secrets.sh", "guard-protected.sh", "frozen-tests.sh"] },
  shell: { tool: "Bash", scripts: ["guard-prod.sh", "guard-git.sh", "guard-pr.sh", "guard-noisy.sh"] },
  bash: { tool: "Bash", scripts: ["guard-prod.sh", "guard-git.sh", "guard-pr.sh", "guard-noisy.sh"] },
}

export const SpecDrivenKitGuard = async ({ directory }) => {
  const KIT_DIR = [".sdkit", ".agentkit", ".claude", ".codex"].find((d) => existsSync(path.join(directory, d, "sdkit.env")) || existsSync(path.join(directory, d, "sdkit.env"))) ?? ".sdkit"
  return {
    "tool.execute.before": async (input, output) => {
      const spec = BY_TOOL[input.tool]
      if (!spec) return
      const args = output.args || {}
      const payload = JSON.stringify({
        tool_name: spec.tool,
        tool_input: { file_path: args.filePath || args.file_path || args.path || "", command: args.command || "" },
      })
      for (const script of spec.scripts) {
        const res = spawnSync("bash", [path.join(directory, KIT_DIR, "hooks", script)], {
          input: payload,
          env: { ...process.env, CLAUDE_PROJECT_DIR: directory, SDKIT_HOST: "opencode" },
          encoding: "utf8",
        })
        let decision
        try { decision = JSON.parse(res.stdout || "{}").hookSpecificOutput } catch { decision = undefined }
        if (decision && (decision.permissionDecision === "deny" || decision.permissionDecision === "ask")) {
          const prefix = decision.permissionDecision === "ask" ? "needs explicit approval: " : ""
          throw new Error(prefix + (decision.permissionDecisionReason || "blocked by spec-driven-kit"))
        }
      }
    },
  }
}
