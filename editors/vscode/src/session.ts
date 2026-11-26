import { ChildProcess, spawn } from 'child_process';
import { answerLine, Out, parseLine, stopLine } from './protocol';

export interface SessionOptions {
  binary: string;
  cwd: string;
  action: string;
  id: string;
  host?: string;
  fresh?: boolean;
  /** what the person typed they want changed; the binary puts it in the agent's task */
  note?: string;
  onLine: (o: Out) => void;
  onStderr?: (s: string) => void;
}

/** One `sdkit ext run` process. The binary owns the agent, the worktree and the ask bridge; this only relays lines. */
export class Session {
  private child: ChildProcess;
  private buf = '';
  readonly done: Promise<number>;

  constructor(private o: SessionOptions) {
    const args = ['ext', 'run', o.action, o.id];
    if (o.fresh) args.push('--fresh');
    if (o.note) args.push('--note', o.note);
    if (o.host) args.push('--host', o.host);
    this.child = spawn(o.binary, args, { cwd: o.cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stdout!.on('data', d => this.feed(String(d)));
    this.child.stderr!.on('data', d => o.onStderr?.(String(d)));
    this.done = new Promise(res => {
      this.child.on('error', e => { o.onStderr?.(String(e)); res(-1); });
      this.child.on('close', c => { this.feed('\n'); res(c ?? -1); });
    });
  }

  private feed(chunk: string) {
    this.buf += chunk;
    let i: number;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i).trim();
      this.buf = this.buf.slice(i + 1);
      const o = line && parseLine(line);
      if (o) this.o.onLine(o);
    }
  }

  answer(id: number, answers: Record<string, string>) { this.child.stdin!.write(answerLine(id, answers)); }

  /** Ask the binary to stop (it kills the whole agent tree); closing stdin does the same if the extension dies. */
  stop() { this.child.stdin!.write(stopLine()); }
}
