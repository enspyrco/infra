#!/usr/bin/env node
// Proves the stdio fix in server.js does what it claims.
//
// The bug: spawn() without a stdio option gives the child THIS process's stdin.
// Under docker that is an open pipe nobody writes to, so the claude CLI waits
// for input, warns, and exits 1 — turning a warning into a hard failure for
// 22% of /chat calls.
//
// Both arms are built here, because an arm that cannot produce the failure
// cannot clear it:
//   RED   — inherited stdin: the child blocks on a read that never completes
//   GREEN — stdio[0]='ignore': fd 0 is /dev/null, the read returns immediately
//
// Run: node claude-shim/src/stdin-spawn.test.mjs

import { spawn } from 'node:child_process';

// Stand-in for the claude CLI: block until stdin reaches EOF, then report.
// With an inherited never-written pipe that EOF never arrives.
const CHILD = 'process.stdin.resume();' +
  'let n=0;' +
  'process.stdin.on("data",d=>{n+=d.length});' +
  'process.stdin.on("end",()=>{console.log("EOF:"+n);process.exit(0)});';

const GRACE_MS = 2500;

function runArm(stdio) {
  return new Promise((resolve) => {
    const proc = spawn(process.execPath, ['-e', CHILD], stdio ? { stdio } : {});
    let out = '';
    if (proc.stdout) proc.stdout.on('data', (d) => { out += d; });
    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      resolve({ outcome: 'BLOCKED', out: out.trim() });
    }, GRACE_MS);
    proc.on('close', () => {
      clearTimeout(timer);
      resolve({ outcome: 'COMPLETED', out: out.trim() });
    });
  });
}

const results = [];

// RED arm. Deliberately reproduces the production defect: default stdio gives
// the child a pipe on fd 0 that this test never writes to and never ends.
const red = await runArm(null);
results.push({
  arm: 'RED  inherited/piped stdin, never written',
  want: 'BLOCKED', got: red.outcome,
});

// GREEN arm. The fix as applied in server.js.
const green = await runArm(['ignore', 'pipe', 'pipe']);
results.push({
  arm: "GREEN stdio[0]='ignore'",
  want: 'COMPLETED', got: green.outcome,
});

let failed = 0;
for (const r of results) {
  const ok = r.want === r.got;
  if (!ok) failed++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${r.arm.padEnd(42)} want=${r.want} got=${r.got}`);
}

if (red.outcome !== 'BLOCKED') {
  console.log('\nThe RED arm did not block, so this test cannot detect the bug it exists to catch.');
  failed++;
}

console.log(failed === 0
  ? '\nOK — inherited stdin hangs the child; ignore does not.'
  : `\n${failed} arm(s) wrong`);
process.exit(failed === 0 ? 0 : 1);
