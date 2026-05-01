import type { Env } from '../types';
import type { SandboxRunner, RunCodeParams, RunCodeResult } from './runner';

// Daytona impl of SandboxRunner.
//
// B0: stub — interface only, no real Daytona calls. The real impl lands in
// B7 alongside the agent feature. Keep this file's exports stable so call
// sites can write code today against it.

export function createDaytonaRunner(env: Env): SandboxRunner {
  return {
    async runCode(_params: RunCodeParams): Promise<RunCodeResult> {
      // TODO(B7): use @daytonaio/sdk to:
      //   1. create sandbox with imageRef (default 'pendingbot/agent-base:1.0')
      //   2. write input files
      //   3. exec code with language-appropriate runner (python3, node, bash)
      //   4. capture stdout/stderr/exit
      //   5. read changed files from working dir
      //   6. destroy sandbox
      void env;
      throw new Error(
        'sandbox.daytona.runCode not implemented — schedule for B7 (agent feature)',
      );
    },
  };
}
