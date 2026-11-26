import { QuestionItem, RunEvent } from './protocol';
import { Step } from './steps';

/**
 * The run page in the middle of the window: a webview (runpage.ts) that draws the model below and is redrawn as the run goes. The
 * model is pure, so what the person reads is tested without VS Code. The page is view-only; questions are answered in the QuickPick above it.
 */
export type Entry =
  | { kind: 'agent'; text: string }
  | { kind: 'question'; id: number; items: QuestionItem[]; answers?: Record<string, string>; dismissed?: boolean }
  | { kind: 'note'; text: string }
  | { kind: 'end'; failed: boolean; text?: string };

/** One thing the agent was seen doing: what a person can follow, never a raw command. */
export interface Activity { label: string; at: number }

/** One line of the full conversation. A tool call carries what it printed back, so the page can fold it away. */
export type LogItem =
  | { kind: 'agent' | 'thought' | 'note'; text: string }
  | { kind: 'tool'; name: string; text: string; output?: string }
  | { kind: 'question'; text: string; answer?: string }
  | { kind: 'end'; text: string; failed: boolean };

export const MAX_LOG = 1500;

/** Append to the full conversation; the oldest lines go first, a long run must not grow the extension without bound. */
export function pushLog(p: Page, item: LogItem): void {
  const l = (p.log ??= []);
  l.push(item);
  if (l.length > MAX_LOG) l.splice(0, l.length - MAX_LOG);
}

/** A tool's output belongs to the call before it. */
export function attachOutput(p: Page, text: string): void {
  const last = p.log?.[p.log.length - 1];
  if (last?.kind === 'tool' && last.output === undefined) last.output = text;
  else pushLog(p, { kind: 'note', text });
}

export interface Page {
  id: string;
  title: string; // what the run does, in plain words
  steps: Step[];
  entries: Entry[];
  running: boolean;
  /** the action this page runs, so "Devam et" can start it again */
  action?: string;
  /** the person pressed stop: the end is theirs, not a failure */
  stopped?: boolean;
  startedAt?: number;
  /** everything the agent said and did, in order, for the "Tam konuşma" tab; capped */
  log?: LogItem[];
  /** newest last; the agent can work for minutes between two messages, and this is what shows it is alive */
  activity?: Activity[];
}

/** A tool call in words for a person: what it is doing, and to what when that is a file or a subagent's task. Commands are not shown. */
export function activityLabel(name: string, text = ''): string {
  const file = text.split(/[\\/]/).pop() ?? '';
  switch (name) {
    case 'Read': return file ? `${file} okunuyor` : 'Dosya okunuyor';
    case 'Write': case 'Edit': case 'MultiEdit': return file ? `${file} yazılıyor` : 'Dosya yazılıyor';
    case 'Glob': case 'Grep': return 'Projede arama yapılıyor';
    case 'Task': return text ? `Alt ajan çalışıyor: ${text}` : 'Alt ajan çalışıyor';
    case 'Skill': return text ? `Yetenek yükleniyor: ${text}` : 'Yetenek yükleniyor';
    case 'Bash': return 'Komut çalıştırılıyor';
    default: return 'Çalışıyor';
  }
}

/** "4 dk 12 sn": how long, without a clock to compare to. */
export function duration(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  return s < 60 ? `${s} sn` : `${Math.floor(s / 60)} dk ${String(s % 60).padStart(2, '0')} sn`;
}

export const MAX_ACTIVITY = 6;

/** Record a move: the same thing again only refreshes its time (forty reads in a row are one line), and the list stays short. */
export function pushActivity(p: Page, label: string, at: number): void {
  const a = (p.activity ??= []);
  const last = a[a.length - 1];
  if (last?.label === label) last.at = at;
  else a.push({ label, at });
  if (a.length > MAX_ACTIVITY) a.splice(0, a.length - MAX_ACTIVITY);
}

const ACTION_TITLES: Record<string, string> = {
  'generate-specs': 'Spec üretimi',
  'update-specs': 'Spec güncelleme',
  'merge-specs': 'Değişiklikleri birleştirme',
};
export const actionTitle = (a: string) => ACTION_TITLES[a] ?? a;

export type Tone = 'run' | 'wait' | 'done' | 'fail' | 'idle';

/** The box at the top, so the one thing that matters is seen without scrolling: a question waiting, the end, or what the agent does now. */
export interface Status {
  tone: Tone;
  head: string;
  /** the agent's last message, first lines */
  detail?: string;
  /** "Süre: 4 dk 12 sn" */
  elapsed?: string;
  /** "Komut çalıştırılıyor · 3 sn önce" */
  now?: string;
  earlier?: string[];
}

export interface View {
  id: string;
  title: string;
  running: boolean;
  /** ended without finishing (stopped or failed): the run can be continued */
  resumable: boolean;
  steps: Step[];
  /** done steps over all steps, 0..100 */
  percent: number;
  status: Status;
  entries: Entry[];
  log: LogItem[];
}

export function view(p: Page, now = Date.now()): View {
  const done = p.steps.filter(s => s.state === 'done').length;
  return {
    id: p.id,
    title: p.title,
    running: p.running,
    resumable: !p.running && !!p.action && (!!p.stopped || p.entries.some(e => e.kind === 'end' && e.failed)),
    steps: p.steps,
    percent: p.steps.length ? Math.round((done / p.steps.length) * 100) : 0,
    status: status(p, now),
    entries: p.entries,
    log: p.log ?? [],
  };
}

function status(p: Page, now: number): Status {
  const waiting = [...p.entries].reverse().find(e => e.kind === 'question' && !e.answers) as Extract<Entry, { kind: 'question' }> | undefined;
  if (waiting) {
    const hint = waiting.dismissed ? 'Seçim kutusu kapandı: alttaki durum çubuğunda "SDKit: cevabınız bekleniyor" yazısına tıklayın.' : 'Pencerenin üstündeki seçim kutusundan cevaplayın.';
    return { tone: 'wait', head: 'Cevabınız bekleniyor', detail: hint };
  }
  if (p.stopped && !p.running) return { tone: 'idle', head: 'Durduruldu', detail: '"Devam et" ile kaldığı yerden sürdürebilirsiniz.' };
  const end = p.entries.find(e => e.kind === 'end') as Extract<Entry, { kind: 'end' }> | undefined;
  if (end) return end.failed ? { tone: 'fail', head: 'Çalışma tamamlanamadı', detail: end.text } : { tone: 'done', head: 'Çalışma bitti' };
  const last = [...p.entries].reverse().find(e => e.kind === 'agent') as Extract<Entry, { kind: 'agent' }> | undefined;
  const cur = p.steps.find(s => s.state === 'started');
  const s: Status = { tone: p.running ? 'run' : 'idle', head: p.running ? `Ajan çalışıyor${cur ? `: ${cur.name}` : ''}` : 'Durdu' };
  if (p.running) {
    if (p.startedAt !== undefined) s.elapsed = `Süre: ${duration(now - p.startedAt)}`;
    const a = p.activity ?? [];
    s.now = a.length ? `${a[a.length - 1].label} · ${duration(now - a[a.length - 1].at)} önce` : 'Ajan hazırlanıyor…';
    if (a.length > 1) s.earlier = a.slice(0, -1).reverse().map(x => x.label);
  }
  if (last) s.detail = firstLines(last.text, 4);
  return s;
}

function firstLines(t: string, n: number): string {
  const l = t.trim().split('\n');
  return l.length > n ? l.slice(0, n).join('\n') + '\n…' : t.trim();
}
