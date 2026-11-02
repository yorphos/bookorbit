// Compare a retained compiled baseline with the candidate, without user data.
// node roulette-performance.cjs OLD_MODULE NEW_MODULE FIXTURE OUTPUT
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {performance} = require('node:perf_hooks');
const [oldPath, newPath, fixturePath, output] = process.argv.slice(2);
const old = require(oldPath).rankRoulette, current = require(newPath).rankRoulette;
const fixture = JSON.parse(fs.readFileSync(fixturePath));
let equivalenceCases = 0;
for (const mode of ['genre', 'content', 'hybrid']) {
  for (const count of [0, 2, 6, 12]) {
    const signals = fixture.slice(0, count).map((book, i) => ({book, weight: i % 2 ? -2 : 2}));
    const candidates = fixture.slice(count);
    assert.deepEqual(current(candidates, signals, mode), old(candidates, signals, mode));
    assert.deepEqual(current(candidates, signals, mode, 5), old(candidates, signals, mode).slice(0, 5));
    equivalenceCases++;
  }
}
const candidates = Array.from({length:150}, (_,i) => ({...fixture[i % fixture.length], title:fixture[i % fixture.length].title + ' ' + i}));
const signals = Array.from({length:500}, (_,i) => ({book:fixture[i % fixture.length], weight:i % 3 ? 2 : -2}));
const runs = {baseline30:[], optimized30:[], visibleWindow5:[]};
const versions = {baseline30:() => old(candidates,signals), optimized30:() => current(candidates,signals), visibleWindow5:() => current(candidates,signals,'hybrid',5)};
for (const run of Object.values(versions)) run();
for (let i=0;i<7;i++) {
  for (const name of (i % 2 ? Object.keys(versions).reverse() : Object.keys(versions))) {
    const start=performance.now(); versions[name](); runs[name].push(performance.now()-start);
  }
}
const metrics=Object.fromEntries(Object.entries(runs).map(([name,ms]) => [name,{medianMs:[...ms].sort((a,b)=>a-b)[3],samplesMs:ms}]));
const report={equivalenceCases,candidates:150,feedbackRecords:500,scope:'Synthetic same-process comparison with warmup and alternating execution order; no claim of physical Kobo latency',metrics};
fs.writeFileSync(output,JSON.stringify(report,null,2));
console.log(JSON.stringify({equivalenceCases,medianMs:Object.fromEntries(Object.entries(metrics).map(([k,v])=>[k,v.medianMs]))}));
