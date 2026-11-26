// The lines `sdkit ext run` writes and reads (internal/ext/run.go). Keep in step with that file.

export interface RunEvent {
  seq: number;
  kind: 'step' | 'text' | 'tool' | 'output' | 'thought' | 'result' | 'status';
  text?: string;
  skill?: string;
  step?: number;
  total?: number;
  name?: string;
  state?: 'started' | 'done';
  failed?: boolean;
}

export interface Option { label: string; description?: string }
export interface QuestionItem {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options?: Option[];
  finding?: Finding;
  plan?: unknown;
}
export interface Finding { id?: string; severity?: string; where?: string; problem?: string; class?: string; diff?: string }

export type Out =
  | { type: 'event'; event: RunEvent }
  | { type: 'question'; id: number; spec?: string; questions: { questions: QuestionItem[] } }
  | { type: 'end'; failed?: boolean; error?: string };

/** One line from the binary; anything that is not a known line is dropped, the extension must not break on a new field. */
export function parseLine(line: string): Out | undefined {
  let m: any;
  try { m = JSON.parse(line); } catch { return undefined; }
  if (!m || typeof m.type !== 'string') return undefined;
  if (m.type === 'event' && m.event) return m as Out;
  if (m.type === 'question' && typeof m.id === 'number' && Array.isArray(m.questions?.questions)) return m as Out;
  if (m.type === 'end') return m as Out;
  return undefined;
}

export const answerLine = (id: number, answers: Record<string, string>) => JSON.stringify({ type: 'answer', id, answers }) + '\n';
export const stopLine = () => JSON.stringify({ type: 'stop' }) + '\n';
