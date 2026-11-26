import { RunEvent } from './protocol';

export interface Step { n: number; name: string; state: 'pending' | 'started' | 'done' }

/** The stepper of a run, rebuilt from the step banners; steps never seen stay pending. */
export class Stepper {
  skill = '';
  total = 0;
  private steps = new Map<number, Step>();

  apply(e: RunEvent): boolean {
    if (e.kind !== 'step' || !e.step || !e.total) return false;
    this.skill = e.skill ?? this.skill;
    this.total = e.total;
    // the agent drops a "done" banner now and then; a step that was left started when the next one begins is over
    for (const [n, st] of this.steps) if (n < e.step && st.state === 'started') st.state = 'done';
    const cur = this.steps.get(e.step);
    this.steps.set(e.step, { n: e.step, name: e.name || cur?.name || `Step ${e.step}`, state: e.state === 'done' ? 'done' : 'started' });
    return true;
  }

  /** The run ended well: whatever the agent never closed, or never announced, is done. A failed run keeps the step it died in. */
  finish(ok: boolean): void {
    if (!ok || !this.total) return;
    for (let n = 1; n <= this.total; n++) {
      const cur = this.steps.get(n);
      this.steps.set(n, { n, name: cur?.name ?? `Step ${n}`, state: 'done' });
    }
  }

  list(): Step[] {
    const out: Step[] = [];
    for (let n = 1; n <= this.total; n++) out.push(this.steps.get(n) ?? { n, name: `Step ${n}`, state: 'pending' });
    return out;
  }
}
