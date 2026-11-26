import test from 'node:test';
import assert from 'node:assert/strict';
import { Stepper } from '../steps';
import { activityLabel, attachOutput, duration, MAX_LOG, Page, pushActivity, pushLog, view } from '../transcript';

const page = (o: Partial<Page>): Page => ({ id: 'LOGIN', title: 'Spec üretimi', steps: [], entries: [], running: true, ...o });

test('a waiting question is what the top box says, even after later messages', () => {
  const v = view(page({ entries: [
    { kind: 'question', id: 1, items: [{ question: 'Kim kontrol etsin?', options: [{ label: 'İstemci' }] }] },
    { kind: 'agent', text: 'Açık noktalar var.' },
  ] }));
  assert.equal(v.status.tone, 'wait');
  assert.match(v.status.head, /Cevabınız bekleniyor/);
});

test('an answered question no longer waits; the last message is the detail', () => {
  const v = view(page({ entries: [
    { kind: 'question', id: 1, items: [{ question: 'Q1' }], answers: { Q1: 'İstemci' } },
    { kind: 'agent', text: 'Tamam.' },
  ] }));
  assert.equal(v.status.tone, 'run');
  assert.equal(v.status.detail, 'Tamam.');
});

test('a dismissed question tells the person where to find it again', () => {
  assert.match(view(page({ entries: [{ kind: 'question', id: 1, items: [{ question: 'Q' }], dismissed: true }] })).status.detail!, /durum çubuğunda/);
});

test('the end replaces the running state', () => {
  const failed = view(page({ running: false, entries: [{ kind: 'end', failed: true, text: 'push reddedildi' }] })).status;
  assert.equal(failed.tone, 'fail');
  assert.equal(failed.detail, 'push reddedildi');
  assert.equal(view(page({ running: false, entries: [{ kind: 'end', failed: false }] })).status.tone, 'done');
});

test('progress counts finished steps, and the started one is named in the top box', () => {
  const v = view(page({ steps: [{ n: 1, name: 'Girdi', state: 'done' }, { n: 2, name: 'Taslak', state: 'started' }, { n: 3, name: 'Adım 3', state: 'pending' }, { n: 4, name: 'Adım 4', state: 'pending' }] }));
  assert.equal(v.percent, 25);
  assert.match(v.status.head, /Ajan çalışıyor: Taslak/);
  assert.equal(view(page({})).percent, 0);
});

test('a quiet agent still shows what it is doing and for how long', () => {
  const s = view(page({ startedAt: 0, activity: [{ label: 'design.md okunuyor', at: 50_000 }, { label: 'Alt ajan çalışıyor: Review round 1', at: 70_000 }] }), 130_000).status;
  assert.equal(s.elapsed, 'Süre: 2 dk 10 sn');
  assert.equal(s.now, 'Alt ajan çalışıyor: Review round 1 · 1 dk 00 sn önce');
  assert.deepEqual(s.earlier, ['design.md okunuyor']);
});

test('progress is shown only while the agent runs, and never a raw command', () => {
  const s = view(page({ running: false, startedAt: 0, activity: [{ label: 'x', at: 0 }], entries: [{ kind: 'end', failed: false }] }), 5000).status;
  assert.equal(s.elapsed, undefined);
  assert.equal(activityLabel('Bash', 'rm -rf /tmp/secret'), 'Komut çalıştırılıyor');
  assert.equal(activityLabel('Write', '/a/b/specs/x/design.md'), 'design.md yazılıyor');
  assert.equal(activityLabel('Task', 'Review the draft'), 'Alt ajan çalışıyor: Review the draft');
});

test('a tool output folds into the call before it; an orphan output stays visible as a note', () => {
  const p = page({});
  pushLog(p, { kind: 'tool', name: 'Bash', text: 'ls' });
  attachOutput(p, 'a\nb');
  attachOutput(p, 'stray');
  assert.deepEqual(p.log, [{ kind: 'tool', name: 'Bash', text: 'ls', output: 'a\nb' }, { kind: 'note', text: 'stray' }]);
});

test('the full conversation keeps only the newest lines', () => {
  const p = page({});
  for (let i = 0; i < MAX_LOG + 5; i++) pushLog(p, { kind: 'agent', text: String(i) });
  assert.equal(p.log!.length, MAX_LOG);
  assert.equal((p.log![0] as { text: string }).text, '5');
});

test('durations read plainly', () => {
  assert.equal(duration(4_000), '4 sn');
  assert.equal(duration(125_000), '2 dk 05 sn');
});

test('the same move again only refreshes its time, and only the latest few are kept', () => {
  const p = page({});
  pushActivity(p, 'a okunuyor', 1); pushActivity(p, 'a okunuyor', 5);
  assert.deepEqual(p.activity, [{ label: 'a okunuyor', at: 5 }]);
  for (let i = 0; i < 10; i++) pushActivity(p, `x${i}`, i);
  assert.equal(p.activity!.length, 6);
  assert.equal(p.activity![5].label, 'x9');
});

test('a step the agent never closed is done once the next starts or the run ends well', () => {
  const st = new Stepper();
  const ev = (step: number, state: 'started' | 'done') => ({ seq: 0, kind: 'step' as const, step, total: 3, name: `S${step}`, state });
  st.apply(ev(1, 'started')); st.apply(ev(2, 'started')); st.apply(ev(3, 'started'));
  assert.deepEqual(st.list().map(s => s.state), ['done', 'done', 'started']);
  const failed = new Stepper(); failed.apply(ev(1, 'started'));
  failed.finish(false);
  assert.equal(failed.list()[0].state, 'started');
  st.finish(true);
  assert.deepEqual(st.list().map(s => s.state), ['done', 'done', 'done']);
});

test('a stopped or failed run can be continued; a finished one only restarted', () => {
  const stopped = view(page({ action: 'generate-specs', running: false, stopped: true, entries: [{ kind: 'end', failed: true }] }));
  assert.equal(stopped.resumable, true);
  assert.equal(stopped.status.head, 'Durduruldu');
  assert.equal(view(page({ action: 'generate-specs', running: false, entries: [{ kind: 'end', failed: true }] })).resumable, true);
  assert.equal(view(page({ action: 'generate-specs', running: false, entries: [{ kind: 'end', failed: false }] })).resumable, false);
  assert.equal(view(page({ action: 'generate-specs', running: true })).resumable, false);
});
