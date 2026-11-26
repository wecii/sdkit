import * as os from 'os';
import * as vscode from 'vscode';
import { Out, QuestionItem } from './protocol';
import { collect } from './questions';
import { Session } from './session';
import { Stepper } from './steps';
import { randomBytes } from 'crypto';
import { actionTitle, activityLabel, attachOutput, Entry, LogItem, Page, pushActivity, pushLog, view as pageView } from './transcript';
import { runPageHtml } from './runpage';
import { sdkitJson, sdkitJsonWithInput, sdkitJsonWithText } from './cli';
import { Agent, agentName, planFix } from './fixes';
import { Connection, ConnectionInput, ConnectResult, describeResult, fields } from './connect';
import { execFile } from 'child_process';
import { describeCliError, blocked, fileItems, menu, sendActions, SpecDetail, FileItem, staleBeforeRun, SyncResult, syncNotice, blockers, PRESPEC_TEMPLATE, validSpecId, CHECKS, failingChecks, needsAttention, groupHealth, groupSpecs, healthSummary, HealthDoc, HealthItem, SpecItem, whereIs } from './model';


class StepsView implements vscode.TreeDataProvider<string> {
  private emitter = new vscode.EventEmitter<void>();
  readonly onDidChangeTreeData = this.emitter.event;
  stepper = new Stepper();
  status = 'Çalışmıyor';
  refresh() { this.emitter.fire(); }
  getTreeItem(label: string) {
    const item = new vscode.TreeItem(label);
    const step = this.stepper.list().find(s => `${s.n}. ${s.name}` === label);
    if (step) item.iconPath = new vscode.ThemeIcon(step.state === 'done' ? 'check' : step.state === 'started' ? 'sync~spin' : 'circle-outline');
    return item;
  }
  getChildren() {
    const steps = this.stepper.list().map(s => `${s.n}. ${s.name}`);
    return steps.length ? steps : [this.status];
  }
}

type Node =
  | { kind: 'group'; label: string; collapsed?: boolean; children: Node[] }
  | { kind: 'row'; label: string; icon: string; description?: string; tip?: string; spec?: SpecItem; fix?: string; cmd?: vscode.Command; lazy?: () => Promise<Node[]> };

/** One tree view over a list of nodes; the views only differ in the nodes they hold. */
class NodeView implements vscode.TreeDataProvider<Node> {
  private emitter = new vscode.EventEmitter<void>();
  readonly onDidChangeTreeData = this.emitter.event;
  nodes: Node[] = [{ kind: 'row', label: 'Denetleniyor…', icon: 'sync~spin' }];
  set(n: Node[]) { this.nodes = n; this.emitter.fire(); }
  getTreeItem(n: Node) {
    if (n.kind === 'group') {
      return new vscode.TreeItem(`${n.label} (${n.children.length})`, n.collapsed ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.Expanded);
    }
    // a row with `lazy` children (a spec's files) is read only when it is opened, not for every spec at every refresh
    const item = new vscode.TreeItem(n.label, n.lazy ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None);
    item.iconPath = new vscode.ThemeIcon(n.icon);
    item.description = n.description;
    item.tooltip = n.tip;
    if (n.spec) {
      // a spec worked on in a folder of its own: that folder is what the person opens to see and change its files elsewhere
      item.contextValue = n.spec.folder ? 'specWorktree' : 'spec';
      item.command = { command: 'sdkit.specAction', title: 'Aç', arguments: [n.spec.id] };
    }
    if (n.cmd) item.command = n.cmd;
    if (n.fix) {
      item.description = 'Düzelt ▸';
      item.command = { command: 'sdkit.fix', title: 'Düzelt', arguments: [n.fix] };
    }
    return item;
  }
  getChildren(n?: Node): Node[] | Promise<Node[]> {
    if (!n) return this.nodes;
    return n.kind === 'group' ? n.children : n.lazy ? n.lazy() : [];
  }
}

const healthIcon = (i: HealthItem) =>
  i.soft ? 'info' : i.level === 'problem' ? 'error' : i.level === 'todo' ? 'warning' : i.level === 'ok' ? 'pass' : 'circle-small';

function healthNodes(d: HealthDoc): Node[] {
  const groups: Node[] = groupHealth(d).map(g => ({
    kind: 'group' as const, label: g.label, collapsed: g.collapsed,
    children: g.items.map(i => ({ kind: 'row' as const, label: i.title, icon: healthIcon(i), fix: i.fix, tip: [i.help, i.raw].filter(Boolean).join('\n\n') || undefined })),
  }));
  return [{ kind: 'row', label: healthSummary(d), icon: d.ready ? 'pass-filled' : 'warning' }, ...groups];
}

function specNodes(specs: SpecItem[], files: (id: string) => Promise<Node[]>): Node[] {
  if (!specs.length) return [{ kind: 'row', label: 'Henüz spec yok', icon: 'info', tip: 'Önce bir ön-spec ekleyin, sonra spec üretimini başlatın.' }];
  return groupSpecs(specs).map(g => ({
    kind: 'group' as const, label: g.label,
    children: g.items.map(s => ({ kind: 'row' as const, label: s.id, description: s.label.trim(), spec: s, lazy: () => files(s.id),
      tip: s.folder ? `${whereIs(s)}\nÇalışma klasörü: ${s.folder}` : whereIs(s),
      icon: s.continue ? 'play-circle' : s.waiting ? 'watch' : 'check' })),
  }));
}

export function activate(ctx: vscode.ExtensionContext) {
  const out = vscode.window.createOutputChannel('Spec-Driven Kit');
  const view = new StepsView();
  const health = new NodeView();
  const specsView = new NodeView();
  let lastHealth: HealthDoc | undefined;
  let specList: SpecItem[] = []; // what the Specs view shows, for the actions that start from a spec
  const bar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left);
  let session: Session | undefined;
  let waiting = 0;

  // the page in the middle of the window (runpage.ts): the specs list, one spec, or a run. One panel; where it is lives here, what it
  // draws is posted to it, and its clicks come back as messages (handled below, after the actions they call exist).
  const pages = new Map<string, Page>();
  let main: vscode.WebviewPanel | undefined;
  let nav: { screen: 'list' | 'spec' | 'run'; id?: string } = { screen: 'list' };
  let openDetail: SpecDetail | undefined; // the spec page's data, fetched when it is opened or after an action
  const post = (p: Page) => { if (nav.screen === 'run' && nav.id === p.id) void main?.webview.postMessage({ type: 'run', view: pageView(p) }); };
  /** Draw whatever screen is current. */
  async function draw() {
    if (!main) return;
    if (nav.screen === 'run' && nav.id && pages.has(nav.id)) return post(pages.get(nav.id)!);
    if (nav.screen === 'spec' && nav.id) {
      try { openDetail = await detailOf(nav.id); } catch (e) { fail(`${nav.id} açılamadı`, e); nav = { screen: 'list' }; return draw(); }
      const item = specList.find(x => x.id === nav.id);
      const busy = !!session && lastRun === nav.id;
      return void main.webview.postMessage({ type: 'spec', id: nav.id, label: openDetail.label, branch: openDetail.branch, flow: item?.flow ?? [], folder: item?.folder,
        menu: menu(openDetail), files: openDetail.files, hasRun: pages.has(nav.id), busy });
    }
    nav = { screen: 'list' };
    void main.webview.postMessage({ type: 'list', groups: groupSpecs(specList), running: session ? lastRun : undefined });
  }
  let redrawTimer: NodeJS.Timeout | undefined;
  /** Events come in bursts; one redraw per burst keeps the page from flickering. */
  function redraw(p: Page) {
    if (redrawTimer) return;
    redrawTimer = setTimeout(() => { redrawTimer = undefined; post(p); }, 150);
  }
  async function showMain(to: typeof nav = nav) {
    nav = to;
    if (main) { main.reveal(vscode.ViewColumn.Active); return draw(); }
    main = vscode.window.createWebviewPanel('sdkitMain', 'SDKit', vscode.ViewColumn.Active, { enableScripts: true, retainContextWhenHidden: true });
    main.webview.html = runPageHtml(randomBytes(16).toString('hex'), main.webview.cspSource);
    // the page asks for its first draw once its script runs; a draw sent earlier would be lost
    main.webview.onDidReceiveMessage(m => void onPage(m));
    main.onDidDispose(() => { main = undefined; });
  }
  const showPage = (id: string) => showMain({ screen: 'run', id });
  // questions still waiting, so the status bar can bring one back after the person closed the box
  const pending = new Map<number, () => void>();
  let lastRun: string | undefined;

  ctx.subscriptions.push(out, bar, vscode.window.registerTreeDataProvider('sdkit.steps', view),
    vscode.window.registerTreeDataProvider('sdkit.specs', specsView));

  const healthTree = vscode.window.createTreeView('sdkit.health', { treeDataProvider: health });
  ctx.subscriptions.push(healthTree);

  // the welcome screen (a Walkthrough, native): its steps show or hide by the context keys set here, one pair per check
  let attention = false;
  let shownThisSession = false;
  function setContexts(h: HealthDoc) {
    const failing = failingChecks(h);
    for (const c of CHECKS) {
      void vscode.commands.executeCommand('setContext', `sdkit.fail.${c}`, failing.has(c));
      void vscode.commands.executeCommand('setContext', `sdkit.ok.${c}`, !failing.has(c));
    }
    void vscode.commands.executeCommand('setContext', 'sdkit.checked', true);
    attention = needsAttention(h);
  }
  const openWelcome = () => vscode.commands.executeCommand('workbench.action.openWalkthrough', `${ctx.extension.id}#onboarding`, false);
  /** Once per window, and only when something is left to do: choosing the Spec-Driven Kit view must not nag a finished setup. */
  function maybeWelcome() {
    if (shownThisSession || !attention) return;
    shownThisSession = true;
    void openWelcome();
  }
  ctx.subscriptions.push(healthTree.onDidChangeVisibility(e => { if (e.visible) maybeWelcome(); }), vscode.commands.registerCommand('sdkit.welcome', openWelcome));

  const folder = () => vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  /** The configured binary; `~` is the home folder (a shell would expand it, a spawned process does not). */
  const binary = () => {
    const p = (vscode.workspace.getConfiguration('sdkit').get<string>('binaryPath') ?? '').trim();
    return !p ? 'sdkit' : p.startsWith('~/') ? os.homedir() + p.slice(1) : p;
  };
  const agent = (): Agent => (vscode.workspace.getConfiguration('sdkit').get<string>('agent') === 'codex' ? 'codex' : 'claude');
  /** The host the kit checks and drives: an explicit command (tests) wins over the chosen agent. */
  const hostArg = () => vscode.workspace.getConfiguration('sdkit').get<string>('hostCommand') || agent();
  async function chooseAgent(): Promise<boolean> {
    const pick = await vscode.window.showQuickPick(
      [{ label: 'Claude Code', description: 'Spec üretimi bu ajanla çalışır', id: 'claude' }, { label: 'Codex', description: 'Kurulum ve denetim hazır; spec üretimi henüz yok', id: 'codex' }],
      { title: 'Hangi yapay zekâ ajanıyla çalışacaksınız?', placeHolder: agentName(agent()) });
    if (!pick) return false;
    await vscode.workspace.getConfiguration('sdkit').update('agent', pick.id, vscode.ConfigurationTarget.Global);
    return true;
  }
  let syncWarned = ''; // one warning per kind of problem and window, not one per refresh
  /** Bring the copy up to date (fast-forward only, in the binary), and say only what the person needs to hear. */
  async function syncCopy(quiet = true): Promise<SyncResult | undefined> {
    const cwd = folder();
    if (!cwd) return undefined;
    try {
      const r = await sdkitJson<SyncResult>(binary(), cwd, ['sync']);
      const n = syncNotice(r);
      if (n?.level === 'info') vscode.window.setStatusBarMessage(`$(sync) ${n.text}`, 5000);
      if (n?.level === 'warn' && (!quiet || syncWarned !== r.state)) {
        syncWarned = r.state;
        void vscode.window.showWarningMessage(n.text);
      }
      return r;
    } catch { return undefined; } // an old binary or no server must not stop the page
  }

  async function refresh() {
    const cwd = folder();
    if (!cwd) return;
    try {
      const h = await sdkitJson<HealthDoc>(binary(), cwd, ['health'], ['--host', hostArg()]);
      lastHealth = h;
      setContexts(h);
      health.set(healthNodes(h));
      specList = await sdkitJson<SpecItem[]>(binary(), cwd, ['specs']);
      specsView.set(specNodes(specList, specFiles));
      if (nav.screen === 'list') void draw();
    } catch (e) {
      const err = describeCliError((e as Error).message);
      // which binary was tried is the first thing to know: an old one found on PATH and a wrong path look alike otherwise
      const used = binary() === 'sdkit' ? "PATH'teki sdkit (ayar boş)" : binary();
      health.set([{ kind: 'row', label: err.title, icon: 'error', fix: err.fix, description: used, tip: `Denenen: ${used}\n\n${String((e as Error).message)}` }]);
    }
  }

  const hasNpm = () => new Promise<boolean>(res => execFile(process.platform === 'win32' ? 'where' : 'which', ['npm'], err => res(!err)));

  async function connect() {
    const cwd = folder();
    if (!cwd) return void vscode.window.showErrorMessage('Önce proje klasörünü açın.');
    let saved: Connection;
    try { saved = await sdkitJson<Connection>(binary(), cwd, ['connection']); }
    catch (e) { return void vscode.window.showErrorMessage(`Bağlantı bilgileri okunamadı: ${(e as Error).message}`); }
    const input: Partial<ConnectionInput> = {};
    for (const f of fields(saved)) {
      const v = await vscode.window.showInputBox({
        title: `Bağlantı (${Object.keys(input).length + 1}/6)`, prompt: f.prompt, placeHolder: f.placeholder, value: f.value,
        password: f.secret, ignoreFocusOut: true,
        validateInput: t => (!f.optional && !t.trim() ? 'Bu alan boş bırakılamaz' : undefined),
      });
      if (v === undefined) return; // Esc: nothing is saved
      input[f.key] = v.trim();
    }
    try {
      const r = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'Bağlantı kaydediliyor ve denetleniyor…' },
        () => sdkitJsonWithInput<ConnectResult>(binary(), cwd, ['connection', 'save'], input));
      const d = describeResult(r);
      (d.ok ? vscode.window.showInformationMessage : vscode.window.showWarningMessage)(`Kaydedildi. ${d.text}`);
    } catch (e) {
      const c = await vscode.window.showErrorMessage(`Kaydedilemedi: ${(e as Error).message}`, 'Tekrar dene');
      if (c) return connect();
    }
    void refresh();
  }

  async function fix(key: string) {
    if (key === 'init-project' && !(await chooseAgent())) return; // the setup depends on the agent: ask first
    const plan = planFix(key, { hasNpm: await hasNpm(), agent: agent(), binary: binary(), win32: process.platform === 'win32' });
    if (!plan) return;
    if (plan.kind === 'connect') return connect();
    if (plan.kind === 'settings') {
      vscode.window.showInformationMessage(plan.why);
      return void vscode.commands.executeCommand('workbench.action.openSettings', plan.query);
    }
    if (plan.kind === 'link') {
      vscode.window.showInformationMessage(plan.why);
      return void vscode.env.openExternal(vscode.Uri.parse(plan.url));
    }
    // the command runs where the person can see it, and where a login can ask for input
    const t = vscode.window.createTerminal(plan.name);
    t.show();
    t.sendText(plan.line);
    const sub = vscode.window.onDidCloseTerminal(c => { if (c === t) { sub.dispose(); void refresh(); } });
    vscode.window.showInformationMessage('Terminalde işlem bitince listeyi yenileyin (ya da terminali kapatın).');
  }

  async function startRun(action: string, id: string, opts: { fresh?: boolean; note?: string } = {}) {
    const cwd = folder();
    if (!cwd) return void vscode.window.showErrorMessage('Önce proje klasörünü açın.');
    if (session) return void vscode.window.showWarningMessage('Bir çalışma sürüyor; önce onu durdurun.');
    if (agent() === 'codex' && !vscode.workspace.getConfiguration('sdkit').get<string>('hostCommand')) {
      const c = await vscode.window.showWarningMessage('Spec üretimi şu an yalnızca Claude Code ile çalışıyor. Codex için kurulum ve denetim hazır, çalıştırma henüz yok.', 'Claude Code\'a geç');
      if (c && await chooseAgent()) void refresh();
      return;
    }
    // the agent would not find the kit's skills and would offer to write the spec by hand, with none of the kit's checks
    const stop = lastHealth ? blockers(lastHealth) : [];
    if (stop.length) {
      const pick = await vscode.window.showWarningMessage(
        `Başlamadan önce tamamlanması gerekenler var:\n${stop.map(b => `• ${b.title}`).join('\n')}`,
        { modal: true }, 'Karşılama ekranını aç', 'Yine de başlat');
      if (pick === 'Karşılama ekranını aç') return void openWelcome();
      if (pick !== 'Yine de başlat') return;
    }
    const synced = await vscode.window.withProgress({ location: vscode.ProgressLocation.Window, title: 'Güncel hâle getiriliyor…' }, () => syncCopy(false));
    if (staleBeforeRun(synced)) {
      const c = await vscode.window.showWarningMessage(`${synced!.message}\nYine de başlatılsın mı?`, { modal: true }, 'Yine de başlat');
      if (!c) return;
    }
    const cfg = vscode.workspace.getConfiguration('sdkit');
    view.stepper = new Stepper();
    view.status = 'Başlıyor…';
    view.refresh();
    out.clear(); // the raw log stays available under Output, the page is what the person reads
    const page: Page = { id, title: actionTitle(action), steps: [], entries: [], running: true, action, startedAt: Date.now(), activity: [] };
    pages.set(id, page);
    lastRun = id;
    await showPage(id);
    post(page); // a page left open from an earlier run of this spec shows the new one
    bar.text = '$(sync~spin) SDKit çalışıyor';
    bar.command = 'sdkit.showRun';
    bar.show();
    const s = new Session({
      binary: binary(), cwd, action, id, fresh: opts.fresh, note: opts.note, host: cfg.get<string>('hostCommand') || undefined,
      onLine: o => void onLine(s, page, o), onStderr: t => out.append(t),
    });
    session = s;
    // the time and "n seconds ago" on the page move on their own, even when the agent says and does nothing new
    const beat = setInterval(() => { if (page.running) redraw(page); }, 5000);
    await s.done;
    clearInterval(beat);
    session = undefined;
    if (nav.screen !== 'run') void draw(); // the spec's buttons were off while the run went on
    for (const [path, owner] of watched) if (owner === id) told.delete(path); // a sent edit can be followed by another
    void refresh(); // a run changes what the specs list says
  }

  const detailOf = (id: string) => sdkitJson<SpecDetail>(binary(), folder()!, ['spec', id]);
  /** A failure of the kit comes with words for the person (it already says what to do); show them as they are. */
  const fail = (what: string, e: unknown) => void vscode.window.showErrorMessage(`${what}: ${(e as Error).message}`);

  /** A button of a spec's page: what the kit offers at this stage, by its position in `menu`. */
  async function doMenu(id: string, index: number) {
    const d = openDetail?.id === id ? openDetail : undefined;
    const it = d && menu(d)[index];
    if (!it) return;
    if (it.kind === 'run') {
      // an update is not only the Tech Lead's to ask for: the person may have edited the files, or may say here what to change
      if (it.action === 'update-specs' || it.action === 'refine-specs') {
        const note = await vscode.window.showInputBox({
          title: it.label, ignoreFocusOut: true,
          prompt: 'Ne değişsin? Dosyaları kendiniz düzelttiyseniz ya da PR\'daki yorumlar yeterliyse boş bırakıp Enter\'a basın. (Esc: vazgeç)',
          placeHolder: 'Örn. AC-3\'teki süre 30 sn değil 60 sn olsun; Q2\'yi kapat',
        });
        if (note === undefined) return;
        return startRun(it.action, id, { note: note.trim() || undefined });
      }
      return startRun(it.action!, id);
    }
    if (!(await openChange(id))) return;
    // "start a change" hands the run to the agent, which asks the person what changes; "edit by hand" opens the new, empty change's files
    if (it.kind === 'startChange') return startRun('update-specs', id);
    void draw(); // the change moved the spec to its branch: the page's files and buttons follow
  }

  /** The kit opens the change (and moves to its branch); git's own refusal (unsaved edits) comes back in plain words. */
  async function openChange(id: string): Promise<boolean> {
    try {
      await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'Değişiklik hazırlanıyor…' }, () => sdkitJson(binary(), folder()!, ['spec', 'change', id]));
      void refresh();
      return true;
    } catch (e) { fail('Değişiklik açılamadı', e); return false; }
  }

  // files the person has been offered to edit: saving one is the moment to say how it is sent
  const watched = new Map<string, string>(); // absolute path -> spec id
  const told = new Set<string>();

  /** The files of a spec as tree rows, grouped as the kit groups them; clicking one opens it where it really is. */
  async function specFiles(id: string): Promise<Node[]> {
    try {
      const d = await detailOf(id);
      const groups: Node[] = [];
      for (const l of fileItems(d)) {
        if (l.separator) groups.push({ kind: 'group', label: l.label, children: [] });
        else (groups[groups.length - 1] as Extract<Node, { kind: 'group' }>).children.push({
          kind: 'row', label: l.label, icon: l.file!.editable ? 'edit' : 'lock', description: l.description, tip: l.file!.editable ? l.detail : `${l.detail}\n${l.file!.why ?? ''}`,
          cmd: { command: 'sdkit.openSpecFile', title: 'Aç', arguments: [id, l.file!.path] },
        });
      }
      return groups.length ? groups : [{ kind: 'row', label: 'Dosya yok', icon: 'info' }];
    } catch (e) {
      return [{ kind: 'row', label: `Dosyalar okunamadı: ${(e as Error).message}`, icon: 'error' }];
    }
  }

  async function openFile(d: SpecDetail, file: FileItem) {
    if (session && lastRun === d.id) return void vscode.window.showWarningMessage('Bu spec için bir çalışma sürüyor; bitmesini bekleyin ya da durdurun, sonra dosyaları düzenleyin.');
    const b = blocked(d, file);
    if (b?.needsBranch) {
      // published files are edited on the spec's own branch: the kit moves there, the person does not need to know
      try { await sdkitJson(binary(), folder()!, ['spec', 'branch', d.id]); } catch (e) { return fail('Spec dalına geçilemedi', e); }
      d = await detailOf(d.id);
      file = d.files.find(f => f.path === file.path) ?? file;
      return openFile(d, file);
    }
    const uri = vscode.Uri.file(`${d.root}/${file.path}`);
    await vscode.window.showTextDocument(uri);
    if (b) {
      await vscode.commands.executeCommand('workbench.action.files.setActiveEditorReadonlyInSession');
      const c = await vscode.window.showInformationMessage(b.reason, ...(b.suggestChange ? ['Değişiklik başlat'] : []));
      if (c) await pickActionKind(d.id, 'startChange');
      return;
    }
    watched.set(uri.fsPath, d.id);
  }

  /** From a row of the tree: the file of a spec, by its id and path. */
  async function openSpecFile(id: string, path: string) {
    let d: SpecDetail;
    try { d = await detailOf(id); } catch (e) { return fail(`${id} açılamadı`, e); }
    const file = d.files.find(f => f.path === path);
    if (file) await openFile(d, file);
  }

  /** A spec's own folder in a window of its own: its files show in the Explorer there, and an agent session started there sees the spec. */
  async function openSpecFolder(arg: unknown) {
    const spec = (arg as { spec?: SpecItem })?.spec;
    if (!spec?.folder) return void vscode.window.showInformationMessage('Bu spec ana klasörde; ayrı bir çalışma klasörü yok.');
    await vscode.commands.executeCommand('vscode.openFolder', vscode.Uri.file(spec.folder), { forceNewWindow: true });
  }

  /** Straight to one kind of action (an offer made in a message), without the menu. */
  async function pickActionKind(id: string, kind: 'startChange') {
    if (kind === 'startChange' && (await openChange(id))) await startRun('update-specs', id);
  }

  /** A saved edit of a listed file: say what comes next, with the kit's own list of what is possible at this stage. */
  async function offerSend(doc: vscode.TextDocument) {
    const id = watched.get(doc.uri.fsPath);
    if (!id || told.has(doc.uri.fsPath)) return;
    told.add(doc.uri.fsPath);
    let d: SpecDetail;
    try { d = await detailOf(id); } catch { return; }
    const acts = sendActions(d);
    if (!acts.length) return;
    const c = await vscode.window.showInformationMessage(`Değişikliğiniz kaydedildi. Hazır olunca gönderebilirsiniz: ajan farkı gözden geçirip PR'a gönderir. Dosya sayısı fark etmez, hepsi birlikte gider.`, ...acts.map(a => a.label), 'Sonra');
    const chosen = acts.find(a => a.label === c);
    if (chosen) await startRun(chosen.key, id);
  }
  ctx.subscriptions.push(vscode.workspace.onDidSaveTextDocument(offerSend));


  // the pre-spec is written in a normal editor tab: an untitled Markdown document that only the save button below sends to the kit
  let draft: { doc: vscode.TextDocument; id: string } | undefined;
  const markDraft = () => void vscode.commands.executeCommand('setContext', 'sdkit.prespecDraft', !!draft && vscode.window.activeTextEditor?.document === draft.doc);
  ctx.subscriptions.push(vscode.window.onDidChangeActiveTextEditor(markDraft));

  async function newSpec() {
    if (!folder()) return void vscode.window.showErrorMessage('Önce proje klasörünü açın.');
    const id = await vscode.window.showInputBox({
      title: 'Yeni spec', prompt: 'Spec için kısa bir ad (harf, rakam, - ve _), örneğin odeme-akisi', ignoreFocusOut: true,
      validateInput: t => (validSpecId(t.trim()) ? undefined : 'Harf, rakam, tire ve alt çizgi; en fazla 60 karakter, boşluk yok'),
    });
    if (!id) return;
    const doc = await vscode.workspace.openTextDocument({ language: 'markdown', content: PRESPEC_TEMPLATE });
    draft = { doc, id: id.trim() };
    await vscode.window.showTextDocument(doc);
    markDraft();
    vscode.window.showInformationMessage(`"${draft.id}" ön-spec'ini yazın, bitince sağ üstteki "Ön-speci kaydet" düğmesine basın.`);
  }

  async function savePrespec() {
    const cwd = folder();
    if (!draft || !cwd) return;
    const { doc, id } = draft;
    const text = doc.getText();
    try {
      let r = await sdkitJsonWithText<{ saved: boolean; exists?: boolean }>(binary(), cwd, ['prespec', id], text);
      if (r.exists) {
        const c = await vscode.window.showWarningMessage(`"${id}" adında bir ön-spec zaten var. Üzerine yazılsın mı?`, { modal: true }, 'Üzerine yaz');
        if (!c) return;
        r = await sdkitJsonWithText(binary(), cwd, ['prespec', id, '--overwrite'], text);
      }
      if (!r.saved) return;
    } catch (e) {
      return void vscode.window.showErrorMessage(`Ön-spec kaydedilemedi: ${(e as Error).message}`);
    }
    draft = undefined;
    markDraft();
    await vscode.commands.executeCommand('workbench.action.closeActiveEditor');
    await refresh();
    const c = await vscode.window.showInformationMessage(`"${id}" ön-spec'i kaydedildi.`, 'Spec üretimini başlat');
    if (c) await startRun('generate-specs', id);
  }

  void syncCopy().then(() => refresh()).then(() => {
    // the very first time the extension runs, show the screen whatever the result, so the person knows where to look
    if (!ctx.globalState.get('sdkit.welcomed')) {
      void ctx.globalState.update('sdkit.welcomed', true);
      shownThisSession = true;
      void openWelcome();
    }
  });
  ctx.subscriptions.push(vscode.commands.registerCommand('sdkit.refresh', async () => { await syncCopy(false); await refresh(); }), vscode.commands.registerCommand('sdkit.connect', connect), vscode.commands.registerCommand('sdkit.chooseAgent', async () => { if (await chooseAgent()) void refresh(); }), vscode.commands.registerCommand('sdkit.fix', fix));

  const asker = {
    async pick(item: QuestionItem) {
      const qp = vscode.window.createQuickPick<vscode.QuickPickItem>();
      qp.title = item.header ? `${item.header}: ${item.question}` : item.question;
      qp.placeholder = item.multiSelect ? 'Bir veya birkaçını seçip Enter\'a basın' : 'Birini seçin';
      qp.canSelectMany = !!item.multiSelect;
      qp.ignoreFocusOut = true; // the agent is waiting: a click elsewhere must not lose the question
      qp.items = (item.options ?? []).map(o => ({ label: o.label, detail: o.description }));
      return new Promise<string[] | undefined>(res => {
        qp.onDidAccept(() => { res(qp.selectedItems.map(i => i.label)); qp.dispose(); });
        qp.onDidHide(() => res(undefined));
        qp.show();
      });
    },
    text: (item: QuestionItem) => Promise.resolve(vscode.window.showInputBox({ title: item.header, prompt: item.question, ignoreFocusOut: true })),
  };

  const qlog = new Map<number, Extract<LogItem, { kind: 'question' }>>();
  async function onLine(s: Session, page: Page, o: Out) {
    if (o.type === 'event') {
      const e = o.event;
      if (view.stepper.apply(e)) {
        view.refresh();
        page.steps = view.stepper.list();
      }
      if (e.kind === 'text' && e.text?.trim()) {
        page.entries.push({ kind: 'agent', text: e.text });
        pushLog(page, { kind: 'agent', text: e.text });
      }
      // the full conversation keeps what the summary leaves out: reasoning, every tool call and what it printed back
      if (e.kind === 'thought' && e.text) pushLog(page, { kind: 'thought', text: e.text });
      if (e.kind === 'tool') pushLog(page, { kind: 'tool', name: e.name ?? '', text: e.text ?? '' });
      if (e.kind === 'output' && e.text) attachOutput(page, e.text);
      // the agent can work minutes between two messages: what it is doing now is what keeps the page alive
      if (e.kind === 'tool') pushActivity(page, activityLabel(e.name ?? '', e.text), Date.now());
      if (e.kind === 'status' && e.name?.startsWith('ask-')) {
        page.entries.push({ kind: 'note', text: `Soru gösterilemedi: ${e.text ?? ''}` });
        pushLog(page, { kind: 'note', text: `Soru gösterilemedi: ${e.text ?? ''}` });
      }
      if (e.kind === 'text' || e.kind === 'status') out.appendLine(e.text ?? '');
      // what the agent runs (raw commands) is for developers: shown only when asked for, as the panel keeps it under "details"
      if (e.kind === 'tool' && vscode.workspace.getConfiguration('sdkit').get<boolean>('showToolActivity')) out.appendLine(`  · ${e.text ?? e.name ?? ''}`);
      if (e.kind === 'result' && e.failed) out.appendLine(`FAILED: ${e.text ?? ''}`);
      redraw(page);
    } else if (o.type === 'question') {
      let entry = page.entries.find(x => x.kind === 'question' && x.id === o.id) as Extract<Entry, { kind: 'question' }> | undefined;
      if (!entry) {
        entry = { kind: 'question', id: o.id, items: o.questions.questions };
        page.entries.push(entry);
        qlog.set(o.id, { kind: 'question', text: o.questions.questions.map(q => q.question).join('\n') });
        pushLog(page, qlog.get(o.id)!);
      }
      entry.dismissed = false;
      pending.delete(o.id);
      waiting++;
      bar.text = `$(question) SDKit: cevabınız bekleniyor`;
      bar.command = 'sdkit.answerPending';
      redraw(page);
      out.appendLine(`? ${o.questions.questions.map(q => q.question).join(' / ')}`);
      const answers = await collect(o.questions.questions, asker);
      waiting--;
      if (answers) {
        entry.answers = answers;
        const ql = qlog.get(o.id);
        if (ql) ql.answer = Object.values(answers).join(' · ');
        s.answer(o.id, answers);
      } else {
        entry.dismissed = true;
        pending.set(o.id, () => void onLine(s, page, o));
        vscode.window.showWarningMessage('SDKit cevabınızı bekliyor.', 'Cevapla').then(c => c && pending.get(o.id)?.());
      }
      if (!pending.size) {
        bar.text = '$(sync~spin) SDKit çalışıyor';
        bar.command = 'sdkit.showRun';
      }
      redraw(page);
    } else if (o.type === 'end') {
      bar.hide();
      pending.clear();
      page.running = false;
      view.stepper.finish(!o.failed);
      page.steps = view.stepper.list();
      page.entries.push({ kind: 'end', failed: !!o.failed, text: o.error });
      pushLog(page, { kind: 'end', failed: !!o.failed, text: o.error ?? '' });
      redraw(page);
      view.status = o.failed ? `Başarısız: ${o.error ?? ''}` : 'Bitti';
      view.refresh();
      if (o.failed && !page.stopped) vscode.window.showErrorMessage(`SDKit: ${o.error ?? 'çalışma başarısız oldu'}`);
    }
  }

  /** A click on the page. The page decides nothing: each message is one of the actions the trees and commands already had. */
  async function onPage(m: { type: string; id?: string; index?: number; path?: string }) {
    switch (m.type) {
      case 'ready': return draw();
      case 'back': return showMain({ screen: 'list' });
      case 'refresh': await refresh(); return draw();
      case 'stop': { const p = m.id ? pages.get(m.id) : undefined; if (p && session) { p.stopped = true; session.stop(); } return; }
      case 'resume': case 'restart': { // the same action again: the kit continues the earlier agent session unless it is told to start fresh
        const p = m.id ? pages.get(m.id) : undefined;
        return p?.action ? startRun(p.action, p.id, { fresh: m.type === 'restart' }) : undefined;
      }
      case 'new': return newSpec();
      case 'open-spec': return m.id ? showMain({ screen: 'spec', id: m.id }) : undefined;
      case 'show-run': return m.id && pages.has(m.id) ? showMain({ screen: 'run', id: m.id }) : undefined;
      case 'folder': return openSpecFolder({ spec: specList.find(x => x.id === m.id) });
      case 'menu': return m.id && m.index !== undefined ? doMenu(m.id, m.index) : undefined;
      case 'file': return m.id && m.path ? openSpecFile(m.id, m.path) : undefined;
    }
  }

  ctx.subscriptions.push(
    vscode.commands.registerCommand('sdkit.run', () => showMain({ screen: 'list' })),
    vscode.commands.registerCommand('sdkit.specAction', (id: string) => showMain({ screen: 'spec', id })),
    vscode.commands.registerCommand('sdkit.newSpec', newSpec),
    vscode.commands.registerCommand('sdkit.openSpecFile', openSpecFile),
    vscode.commands.registerCommand('sdkit.openSpecFolder', openSpecFolder),
    vscode.commands.registerCommand('sdkit.savePrespec', savePrespec),
    vscode.commands.registerCommand('sdkit.stop', () => session?.stop()),
    vscode.commands.registerCommand('sdkit.answerPending', () => {
      const first = pending.values().next().value;
      if (first) first();
      else if (lastRun) void showPage(lastRun);
    }),
    vscode.commands.registerCommand('sdkit.showRun', () => lastRun && showPage(lastRun)),
    vscode.commands.registerCommand('sdkit.showLog', () => out.show()),
  );
}

export function deactivate() {}
