import { View } from './transcript';

/**
 * The page in the middle of the window: the specs list, one spec's page, and a run. It holds no data and decides nothing: the extension
 * posts what to draw (`list`, `spec` or `run`, the last being a `View` of transcript.ts) and the script below draws it; a click goes
 * back as a message. Navigation lives in the extension.
 * Everything that came from the agent goes in with `textContent`, never as markup, so a message cannot inject anything; the CSP
 * allows only this one script.
 */
export function runPageHtml(nonce: string, cspSource: string): string {
  return `<!doctype html><html lang="tr"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
  body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); padding: 16px 24px 48px; max-width: 980px; margin: 0 auto; }
  h1 { font-size: 1.3em; margin: 0 0 4px; } .sub { opacity: .7; margin-bottom: 14px; }
  .bar { height: 6px; border-radius: 3px; background: var(--vscode-editorWidget-border, #444); overflow: hidden; margin: 8px 0 18px; }
  .bar > i { display: block; height: 100%; background: var(--vscode-charts-green, #3fb950); transition: width .4s; }
  .steps { display: flex; margin: 0 0 20px; }
  .step { flex: 1; text-align: center; position: relative; min-width: 0; padding: 0 2px; }
  .step::before { content: ""; position: absolute; top: 13px; left: -50%; width: 100%; height: 2px; background: var(--vscode-editorWidget-border, #555); z-index: 0; }
  .step:first-child::before { display: none; }
  .step.done::before, .step.started::before { background: var(--vscode-charts-green, #3fb950); }
  .dot { position: relative; z-index: 1; width: 28px; height: 28px; line-height: 28px; border-radius: 50%; margin: 0 auto 6px; box-sizing: border-box;
    border: 2px solid var(--vscode-editorWidget-border, #555); background: var(--vscode-editor-background); font-size: 13px; }
  .done .dot { background: var(--vscode-charts-green, #3fb950); border-color: var(--vscode-charts-green, #3fb950); color: #fff; }
  .started .dot { border-color: var(--vscode-charts-blue, #3794ff); color: var(--vscode-charts-blue, #3794ff); animation: pulse 1.4s infinite; }
  .lbl { font-size: .82em; opacity: .65; overflow-wrap: anywhere; } .started .lbl, .done .lbl { opacity: 1; } .started .lbl { font-weight: 600; }
  @keyframes pulse { 0% { box-shadow: 0 0 0 0 rgba(55,148,255,.55); } 70% { box-shadow: 0 0 0 9px rgba(55,148,255,0); } 100% { box-shadow: 0 0 0 0 rgba(55,148,255,0); } }
  .card { border: 1px solid var(--vscode-editorWidget-border, #444); border-left-width: 4px; border-radius: 4px; padding: 10px 14px; margin-bottom: 18px; background: var(--vscode-editorWidget-background); }
  .card.run { border-left-color: var(--vscode-charts-blue, #3794ff); } .card.wait { border-left-color: var(--vscode-charts-yellow, #d7ba7d); }
  .card.done { border-left-color: var(--vscode-charts-green, #3fb950); } .card.fail { border-left-color: var(--vscode-charts-red, #f14c4c); }
  .card .head { font-weight: 600; } .card .meta { opacity: .75; margin-top: 4px; } .card .earlier { opacity: .6; font-size: .85em; margin: 6px 0 0 16px; padding: 0; }
  .card .detail { margin-top: 8px; padding-left: 10px; border-left: 2px solid var(--vscode-editorWidget-border, #555); white-space: pre-wrap; opacity: .9; }
  .tabs { display: flex; gap: 4px; border-bottom: 1px solid var(--vscode-editorWidget-border, #444); margin-bottom: 14px; }
  .tab { background: none; border: none; color: inherit; padding: 6px 14px; cursor: pointer; opacity: .65; border-bottom: 2px solid transparent; font: inherit; }
  .tab.on { opacity: 1; border-bottom-color: var(--vscode-focusBorder, #3794ff); }
  .msg { margin: 0 0 12px; } .who { font-size: .8em; opacity: .6; margin-bottom: 2px; }
  .txt { white-space: pre-wrap; overflow-wrap: anywhere; } .msg.agent .txt { padding: 6px 10px; border-radius: 4px; background: var(--vscode-editorWidget-background); }
  .thought .txt { opacity: .55; font-style: italic; } .note .txt { opacity: .6; } .end .txt { font-weight: 600; }
  .q { padding: 6px 10px; border-radius: 4px; border: 1px dashed var(--vscode-editorWidget-border, #555); } .q .a { margin-top: 2px; opacity: .85; }
  details.tool { margin: 0 0 6px; font-size: .88em; opacity: .85; } details.tool summary { cursor: pointer; overflow-wrap: anywhere; }
  details.tool pre { margin: 4px 0 0; padding: 6px 8px; max-height: 280px; overflow: auto; background: var(--vscode-textCodeBlock-background); white-space: pre-wrap; overflow-wrap: anywhere; }
  .nav { display: flex; gap: 8px; align-items: center; margin-bottom: 14px; } .nav .grow { flex: 1; }
  button.btn { font: inherit; cursor: pointer; padding: 5px 12px; border-radius: 3px; border: 1px solid var(--vscode-button-border, transparent);
    background: var(--vscode-button-secondaryBackground); color: var(--vscode-button-secondaryForeground); }
  button.btn.primary { background: var(--vscode-button-background); color: var(--vscode-button-foreground); }
  button.btn:hover { filter: brightness(1.15); }
  h2 { font-size: 1.05em; margin: 20px 0 8px; opacity: .85; }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 10px; }
  .spec-card { cursor: pointer; border: 1px solid var(--vscode-editorWidget-border, #444); border-radius: 4px; padding: 10px 12px; background: var(--vscode-editorWidget-background); }
  .spec-card:hover { border-color: var(--vscode-focusBorder, #3794ff); } .spec-card .id { font-weight: 600; } .spec-card .st { opacity: .75; margin: 2px 0 8px; font-size: .9em; }
  .mini { display: flex; gap: 3px; } .mini i { flex: 1; height: 5px; border-radius: 2px; background: var(--vscode-editorWidget-border, #555); }
  .mini i.done { background: var(--vscode-charts-green, #3fb950); } .mini i.current { background: var(--vscode-charts-blue, #3794ff); }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; margin: 4px 0 6px; } .hint { opacity: .65; font-size: .85em; margin-bottom: 8px; }
  .file { display: flex; gap: 10px; padding: 5px 8px; border-radius: 3px; cursor: pointer; align-items: baseline; }
  .file:hover { background: var(--vscode-list-hoverBackground); } .file .p { opacity: .55; font-size: .85em; flex: 1; overflow-wrap: anywhere; } .file .ro { opacity: .6; font-size: .8em; }
  .empty { opacity: .6; font-style: italic; }
</style></head><body>
<div id="list" hidden></div>
<div id="specp" hidden></div>
<div id="run" hidden>
<div class="nav"><button class="btn" id="back">← Specler</button><span class="grow"></span><span id="runbtns"></span></div>
<h1 id="title"></h1><div class="sub" id="sub"></div>
<div class="bar"><i id="pct"></i></div>
<div class="steps" id="steps"></div>
<div class="card" id="card"></div>
<div class="tabs"><button class="tab" data-t="sum">Özet</button><button class="tab" data-t="full">Tam konuşma</button></div>
<div id="body"></div>
</div>
<script nonce="${nonce}">
const vs = acquireVsCodeApi();
let tab = (vs.getState() || {}).tab || 'sum';
let last = null;
const send = (type, o) => vs.postMessage(Object.assign({ type }, o || {}));
const btn = (text, cls, fn) => { const b = el('button', 'btn ' + (cls || ''), text); b.onclick = fn; return b; };
const screens = ['list', 'specp', 'run'];
const show = n => screens.forEach(x => $(x).hidden = x !== n);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; };
const $ = id => document.getElementById(id);
$('back').onclick = () => send('back');
document.querySelectorAll('.tab').forEach(b => b.onclick = () => { tab = b.dataset.t; vs.setState({ tab }); if (last) drawRun(last); });

function msg(cls, who, text) { const m = el('div', 'msg ' + cls); if (who) m.append(el('div', 'who', who)); m.append(el('div', 'txt', text)); return m; }

function entry(e) {
  if (e.kind === 'agent') return msg('agent', '🤖 Ajan', e.text.trim());
  if (e.kind === 'note') return msg('note', '', e.text);
  if (e.kind === 'end') return msg('end', '', e.failed ? '❌ Tamamlanamadı. ' + (e.text || '') : '✅ Bitti.');
  const m = el('div', 'msg q');
  m.append(el('div', 'who', '❓ ' + (e.items.length > 1 ? e.items.length + ' soru' : 'Soru')));
  for (const q of e.items) {
    m.append(el('div', 'txt', q.question));
    if (q.finding) m.append(el('div', 'a', 'Bulgu ' + (q.finding.id || '') + ' · ' + (q.finding.severity || '') + ' · ' + (q.finding.where || '') + ' — ' + (q.finding.problem || '')));
    const a = e.answers && e.answers[q.question];
    m.append(el('div', 'a', e.answers ? '🙋 Siz: ' + (a || '(boş bıraktınız)') : 'cevap bekleniyor'));
  }
  return m;
}

function logItem(l) {
  switch (l.kind) {
    case 'agent': return msg('agent', '🤖 Ajan', l.text.trim());
    case 'thought': return msg('thought', '💭 Düşünce', l.text);
    case 'note': return msg('note', '', l.text);
    case 'end': return msg('end', '', l.failed ? '❌ Tamamlanamadı. ' + l.text : '✅ Bitti.');
    case 'question': return msg('q', '❓ Soru', l.text + (l.answer !== undefined ? '\\n🙋 Siz: ' + (l.answer || '(boş)') : '\\ncevap bekleniyor'));
    case 'tool': {
      const d = el('details', 'tool');
      d.append(el('summary', '', '⚙️ ' + l.name + (l.text ? ': ' + l.text : '')));
      if (l.output) d.append(el('pre', '', l.output));
      return d;
    }
  }
}

function drawRun(v) {
  show('run');
  last = v;
  const rb = $('runbtns'); rb.replaceChildren();
  if (v.running) rb.append(btn('⏹ Durdur', '', () => send('stop', { id: v.id })));
  else {
    if (v.resumable) rb.append(btn('▶ Devam et', 'primary', () => send('resume', { id: v.id })));
    rb.append(btn('↻ Baştan başlat', '', () => send('restart', { id: v.id })));
  }
  $('title').textContent = v.title;
  $('sub').textContent = v.id;
  $('pct').style.width = v.percent + '%';
  const steps = $('steps'); steps.replaceChildren();
  for (const s of v.steps) {
    const d = el('div', 'step ' + s.state);
    d.append(el('div', 'dot', s.state === 'done' ? '✓' : String(s.n)), el('div', 'lbl', s.name));
    steps.append(d);
  }
  steps.style.display = v.steps.length ? '' : 'none';
  const c = $('card'); c.className = 'card ' + v.status.tone; c.replaceChildren();
  c.append(el('div', 'head', v.status.head));
  if (v.status.elapsed) c.append(el('div', 'meta', '⏱ ' + v.status.elapsed));
  if (v.status.now) c.append(el('div', 'meta', '⚙️ Şimdi: ' + v.status.now));
  if (v.status.earlier && v.status.earlier.length) { const u = el('ul', 'earlier'); v.status.earlier.forEach(x => u.append(el('li', '', x))); c.append(u); }
  if (v.status.detail) c.append(el('div', 'detail', v.status.detail));
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('on', b.dataset.t === tab));
  const body = $('body');
  const items = tab === 'sum' ? v.entries.map(entry) : v.log.map(logItem);
  // keep the reader's place: follow the stream only when already at the bottom, and keep the folds the person opened
  const open = new Set([...body.querySelectorAll('details')].map((d, i) => d.open ? i : -1));
  const atEnd = window.innerHeight + window.scrollY >= document.body.scrollHeight - 40;
  body.replaceChildren(...items);
  body.querySelectorAll('details').forEach((d, i) => { if (open.has(i)) d.open = true; });
  if (!items.length) body.append(el('div', 'empty', 'Ajan başlıyor…'));
  if (atEnd && tab === 'full') window.scrollTo(0, document.body.scrollHeight);
}
function mini(flow) { const m = el('div', 'mini'); (flow || []).forEach(f => { const i = el('i', f.status); i.title = f.label; m.append(i); }); return m; }

function drawList(m) {
  show('list');
  const root = $('list'); root.replaceChildren();
  const nav = el('div', 'nav'); nav.append(el('h1', 'grow', 'Specler'), btn('Yenile', '', () => send('refresh')), btn('Yeni spec', 'primary', () => send('new')));
  root.append(nav);
  if (!m.groups.length) root.append(el('div', 'empty', 'Henüz spec yok. "Yeni spec" ile başlayın.'));
  for (const g of m.groups) {
    root.append(el('h2', '', g.label));
    const cards = el('div', 'cards');
    for (const s of g.items) {
      const c = el('div', 'spec-card'); c.onclick = () => send('open-spec', { id: s.id });
      c.append(el('div', 'id', s.id + (m.running === s.id ? '  🔄' : '')), el('div', 'st', s.label.trim()), mini(s.flow));
      cards.append(c);
    }
    root.append(cards);
  }
}

function drawSpec(m) {
  show('specp');
  const root = $('specp'); root.replaceChildren();
  const nav = el('div', 'nav'); nav.append(btn('← Specler', '', () => send('back')), el('span', 'grow'));
  if (m.hasRun) nav.append(btn(m.running ? '🔄 Çalışmayı gör' : 'Son çalışmayı gör', '', () => send('show-run', { id: m.id })));
  if (m.folder) nav.append(btn('Klasörü ayrı pencerede aç', '', () => send('folder', { id: m.id })));
  root.append(nav, el('h1', '', m.id), el('div', 'sub', m.label.trim() + (m.branch ? ' · dal: ' + m.branch : '')));
  if (m.flow && m.flow.length) {
    const steps = el('div', 'steps');
    m.flow.forEach((f, i) => { const d = el('div', 'step ' + (f.status === 'done' ? 'done' : f.status === 'current' ? 'started' : 'pending')); d.append(el('div', 'dot', f.status === 'done' ? '✓' : String(i + 1)), el('div', 'lbl', f.label)); steps.append(d); });
    root.append(steps);
  }
  root.append(el('h2', '', 'Yapılabilecekler'));
  if (m.busy) root.append(el('div', 'hint', 'Bu spec için bir çalışma sürüyor; bitmesini bekleyin ya da durdurun.'));
  const acts = el('div', 'actions');
  m.menu.forEach((it, i) => { if (it.kind !== 'files') { const b = btn(it.label, i === 0 ? 'primary' : '', () => send('menu', { id: m.id, index: i })); b.disabled = !!m.busy; if (it.detail) b.title = it.detail; acts.append(b); } });
  root.append(acts);
  if (!m.menu.some(it => it.kind !== 'files')) root.append(el('div', 'hint', 'Şu an yapılacak bir şey yok.'));
  m.menu.filter(it => it.detail && it.kind !== 'files').forEach(it => root.append(el('div', 'hint', it.label + ': ' + it.detail)));
  root.append(el('h2', '', 'Dosyalar'));
  if (!m.files.length) root.append(el('div', 'empty', 'Dosya yok.'));
  let group = '';
  for (const f of m.files) {
    if (f.group !== group) { group = f.group; root.append(el('div', 'who', group)); }
    const r = el('div', 'file'); r.onclick = () => send('file', { id: m.id, path: f.path });
    r.append(el('span', '', f.path.split('/').pop()), el('span', 'p', f.path), el('span', 'ro', f.editable ? 'düzenlenebilir' : 'salt okunur'));
    if (!f.editable && f.why) r.title = f.why;
    root.append(r);
  }
}

window.addEventListener('message', e => {
  const m = e.data;
  if (m.type === 'list') drawList(m); else if (m.type === 'spec') drawSpec(m); else if (m.type === 'run') drawRun(m.view);
});
vs.postMessage({ type: 'ready' });
</script></body></html>`;
}
