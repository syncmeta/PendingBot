// Provider-agnostic sandbox interface. Current impl: Daytona (see ./daytona.ts).
// Future swaps (E2B, Modal, Riza, Fly Machines self-managed) only change the
// concrete factory; callers stay on this interface.

export interface SandboxFile {
  path: string;
  content: Uint8Array;
}

export interface RunCodeParams {
  language: 'python' | 'javascript' | 'typescript' | 'shell';
  code: string;
  files?: SandboxFile[];      // input files copied into sandbox FS
  timeoutMs?: number;         // default 30s
  imageRef?: string;          // override default image (e.g. data-science image)
}

export interface RunCodeResult {
  stdout: string;
  stderr: string;
  files: SandboxFile[];       // any files created in working dir, returned
  exitCode: number;
  durationMs: number;
}

export interface SandboxRunner {
  runCode(params: RunCodeParams): Promise<RunCodeResult>;
}
