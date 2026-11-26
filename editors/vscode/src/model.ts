// The documents `sdkit ext health|specs` print (internal/ext/read.go, internal/ui). Pure helpers, so they are testable without VS Code.

export interface HealthItem { check?: string; level: 'problem' | 'todo' | 'note' | 'ok' | string; title: string; help?: string; fix?: string; raw?: string; soft?: boolean; main?: boolean }
export interface HealthDoc { ready: boolean; items: HealthItem[] }
export interface FlowStep { key: string; label: string; status: 'done' | 'current' | 'todo' }
export interface SpecItem { folder?: string; id: string; state: string; label: string; waiting: boolean; continue: boolean; update: boolean; merge: boolean; tasks: boolean; flow: FlowStep[] }

/** What the checklist shows first: the items the person must act on (the kit marks them `main`), problems before todos. */
export function mainItems(d: HealthDoc): HealthItem[] {
  const rank = (i: HealthItem) => (i.level === 'problem' ? 0 : i.level === 'todo' ? 1 : 2);
  return d.items.filter(i => i.main).sort((a, b) => rank(a) - rank(b));
}

/** The run action a spec's state offers, in the order a person would take them; none when only someone else can act. */
export function actionsOf(s: SpecItem): string[] {
  const a: string[] = [];
  if (s.continue) a.push('generate-specs');
  if (s.update) a.push('update-specs');
  if (s.merge) a.push('merge-specs');
  return a;
}

/** "step 3 of 6: Review", for the tooltip of a spec. */
export function whereIs(s: SpecItem): string {
  const i = s.flow.findIndex(f => f.status === 'current');
  return i < 0 ? s.label : `${i + 1}/${s.flow.length}: ${s.flow[i].label}`;
}

export interface Group<T> { label: string; items: T[]; collapsed?: boolean }

/**
 * The readiness checklist in the order a person acts on it. A `soft` problem is the Tech Lead's to fix and does not stop the work,
 * so it is shown apart and never as an error; everything the kit marks as not `main` is detail.
 */
export function groupHealth(d: HealthDoc): Group<HealthItem>[] {
  const main = mainItems(d);
  const mine = main.filter(i => (i.level === 'problem' || i.level === 'todo') && !i.soft);
  const techLead = main.filter(i => i.soft);
  const good = main.filter(i => !mine.includes(i) && !techLead.includes(i));
  const rest = d.items.filter(i => !i.main);
  const out: Group<HealthItem>[] = [];
  if (mine.length) out.push({ label: 'Sizi bekleyenler', items: mine });
  if (techLead.length) out.push({ label: 'Tech Lead\'e ait', items: techLead });
  if (good.length) out.push({ label: 'Hazır', items: good });
  if (rest.length) out.push({ label: 'Teknik ayrıntılar', items: rest, collapsed: true });
  return out;
}

/** The one line above the groups. */
export function healthSummary(d: HealthDoc): string {
  const n = groupHealth(d).find(g => g.label === 'Sizi bekleyenler')?.items.length ?? 0;
  return n ? `Başlamadan önce yapılacak ${n} şey var` : d.ready ? 'Çalışmaya hazır' : 'Hazır değil: ayrıntılara bakın';
}

/** Specs grouped by who has to act next; the kit already sorts open work first, and that order is kept inside a group. */
export function groupSpecs(specs: SpecItem[]): Group<SpecItem>[] {
  const g = [
    { label: 'Sizi bekleyenler', items: specs.filter(s => s.continue) },
    { label: 'Tech Lead\'de', items: specs.filter(s => s.waiting && !s.continue) },
    { label: 'Onaylı', items: specs.filter(s => !s.continue && !s.waiting) },
  ];
  return g.filter(x => x.items.length);
}

/** Every check the welcome screen shows, in its order. The names are `Item.Check` of the kit (internal/ui/health.go). */
export const CHECKS = ['setup', 'agent', 'agent-login', 'openspec', 'jira', 'bitbucket', 'project'] as const;
export type Check = (typeof CHECKS)[number];

/**
 * The checks that fail: an item with the check's name that is a problem or a todo. Without the agent there is nothing to log in
 * to, so a missing install fails the login too (the kit reports only the install then).
 */
export function failingChecks(d: HealthDoc): Set<string> {
  const f = new Set(d.items.filter(i => i.check && (i.level === 'problem' || i.level === 'todo')).map(i => i.check as string));
  if (f.has('agent')) f.add('agent-login');
  return f;
}

/** Something the person (not only the Tech Lead) has to do: worth showing the welcome screen for. */
export function needsAttention(d: HealthDoc): boolean {
  return d.items.some(i => (i.level === 'problem' || i.level === 'todo') && !i.soft);
}

export interface ActionItem { key: string; label: string; hint?: string; primary?: boolean }
export interface FileItem { path: string; group: string; editable: boolean; why?: string }
/** `sdkit ext spec <id>`: the panel's spec page. `root` is the folder the files are in (a worktree, for a spec worked on in one). */
export interface SpecDetail { id: string; state: string; label: string; actions: ActionItem[]; branch: string; wantBranch?: string; files: FileItem[]; root: string }

export type MenuKind = 'run' | 'startChange' | 'editChange' | 'files';
export interface MenuItem { kind: MenuKind; label: string; detail?: string; action?: string }

/** The agent runs a run action can start. `generate-tasks` needs a Jira parent and a version the extension does not ask for yet. */
const RUN_ACTIONS = ['generate-specs', 'update-specs', 'update-manual', 'merge-specs', 'refine-specs', 'generate-design'];

/**
 * What the person can do with a spec, from the kit's own list for its stage (the same one the panel shows), nothing else. Files come
 * last: reading and editing is always possible where the kit allows it.
 */
export function menu(d: SpecDetail): MenuItem[] {
  const out: MenuItem[] = [];
  for (const a of [...d.actions].sort((x, y) => Number(!!y.primary) - Number(!!x.primary))) {
    if (RUN_ACTIONS.includes(a.key)) out.push({ kind: 'run', label: a.label, detail: a.hint, action: a.key });
    else if (a.key === 'start-change') out.push({ kind: 'startChange', label: a.label, detail: a.hint });
    else if (a.key === 'edit-change') out.push({ kind: 'editChange', label: a.label, detail: a.hint });
  }
  if (d.files.length) out.push({ kind: 'files', label: 'Dosyaları aç', detail: 'Spec dosyalarını okuyun ya da düzenleyin' });
  return out;
}

/** Why a file cannot be edited is the kit's wording; an approved spec is the case where the right next step is to start a change. */
export type Blocked = { reason: string; needsBranch: boolean; suggestChange: boolean };
export function blocked(d: SpecDetail, f: FileItem): Blocked | undefined {
  if (f.editable) return undefined;
  const hasChange = d.actions.some(a => a.key === 'start-change' || a.key === 'edit-change');
  return {
    reason: f.why ?? 'Bu dosya düzenlenemez.',
    needsBranch: !!d.wantBranch && /dalına geçin/.test(f.why ?? ''),
    suggestChange: d.state === 'approved' && hasChange && /salt okunur/.test(f.why ?? ''),
  };
}

/** What sending the person's own edits means at this stage: the kit reviews the diff and publishes (`update-manual`), or carries on a draft. */
export function sendActions(d: SpecDetail): ActionItem[] {
  const send = d.actions.find(a => a.key === 'update-manual') ?? d.actions.find(a => a.key === 'generate-specs');
  // the agent can also work the Tech Lead's comments in with the edits: offered next to sending, never instead of it
  const also = d.actions.find(a => a.key === 'update-specs');
  return [send, also].filter((a): a is ActionItem => !!a);
}

/** The files by group, for one pick list; a file that cannot be edited says so in the list, not after the click. */
export function fileItems(d: SpecDetail): { label: string; description: string; detail?: string; file?: FileItem; separator?: boolean }[] {
  const out: { label: string; description: string; detail?: string; file?: FileItem; separator?: boolean }[] = [];
  let group = '';
  for (const f of d.files) {
    if (f.group !== group) {
      group = f.group;
      out.push({ label: group, description: '', separator: true });
    }
    out.push({ label: f.path.split('/').pop() ?? f.path, description: f.editable ? 'düzenlenebilir' : 'salt okunur', detail: f.path, file: f });
  }
  return out;
}

/** The pre-spec name becomes a file, a branch and a Jira link, so the kit allows letters, digits, - and _ only. Mirrors ui.ValidID. */
export const validSpecId = (id: string) => /^[A-Za-z0-9][A-Za-z0-9_-]{0,59}$/.test(id);

export const PRESPEC_TEMPLATE = `# Ön-spec

## Ne istiyoruz?
(Bir iki cümleyle isteği anlatın.)

## Neden?
(Kimin hangi sorunu çözülüyor?)

## Kapsam
- (Neler dahil?)

## Kapsam dışı
- (Neler bu işe dahil değil?)

## Notlar
(Bildiğiniz kurallar, ekran görüntüleri, benzer ekranlar.)
`;

/** The checks without which a run cannot work: the agent would not find the skills or the tools (it then offers to write by hand, and the kit's gates do not run). */
export const BLOCKING: readonly Check[] = ['setup', 'agent', 'agent-login', 'openspec'];

export function blockers(d: HealthDoc): { check: string; title: string }[] {
  const failing = failingChecks(d);
  return BLOCKING.filter(c => failing.has(c)).map(c => ({
    check: c,
    title: d.items.find(i => i.check === c && (i.level === 'problem' || i.level === 'todo'))?.title
      ?? { 'agent-login': "Ajana giriş yapılmamış", agent: 'Ajan kurulu değil' }[c as string] ?? c,
  }));
}

export interface SyncResult { state: 'current' | 'updated' | 'offline' | 'dirty' | 'other-branch' | 'diverged' | 'no-remote'; base: string; branch: string; behind: number; message: string }

/**
 * What the person is told after the copy was brought up to date. Good news is a passing line, a problem the person can act on is a
 * warning, and what changes nothing for them (offline, another branch, a folder without a server) is not said at all.
 */
export function syncNotice(r: SyncResult): { text: string; level: 'info' | 'warn' } | undefined {
  switch (r.state) {
    case 'updated': return { text: r.message, level: 'info' };
    case 'dirty':
    case 'diverged': return { text: r.message, level: 'warn' };
    default: return undefined;
  }
}

/** A run on a copy that could not be brought up to date works on old state: the person decides, with the reason in front of them. */
export const staleBeforeRun = (r: SyncResult | undefined) => !!r && (r.state === 'dirty' || r.state === 'diverged');

/**
 * What a failed call of the binary means for the person. An older sdkit (it has no `ext`) and a missing one both end at the same
 * place, the binary setting, so that is the fix offered; any other error is shown as the binary said it.
 */
export function describeCliError(message: string): { title: string; fix?: string } {
  const launch = /^LAUNCH:([a-z-]+):(.*)$/s.exec(message);
  if (launch) {
    const [, kind, what] = launch;
    switch (kind) {
      case 'cwd': return { title: 'Açık klasör bulunamadı', fix: undefined };
      case 'missing': return { title: `Bu yolda sdkit yok: ${what}`, fix: 'binary-setting' };
      case 'directory': return { title: `Bu yol bir klasör, dosya değil: ${what}`, fix: 'binary-setting' };
      case 'not-executable': return { title: `sdkit dosyasının çalıştırma izni yok: ${what}`, fix: undefined };
    }
  }
  if (/unknown command ['"`]?ext/i.test(message)) {
    return { title: 'Kurulu sdkit bu eklentiyle uyumlu değil (ext komutu yok): eklentiyle gelen sdkit sürümünü kullanın', fix: 'binary-setting' };
  }
  if (/\bspawn .+ ENOENT/.test(message)) return { title: 'sdkit başlatılamadı (dosya ya da klasör yok)', fix: 'binary-setting' };
  return { title: `sdkit çalıştırılamadı: ${message}` };
}
