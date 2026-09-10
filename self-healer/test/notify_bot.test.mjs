// Which BOT identity the self-healer speaks as.
//
// Until 2026-09-10 sendNotify posted {message, parse_mode} with no `bot` field.
// notify's own default is "dreams", so every self-healer verdict ("Self-healer:
// RED …") arrived in the Claude Dreams bot instead of Enspyr Infra. Nothing
// caught it because no test asserted the REQUEST BODY — the tests covered
// scrubbing and formatting, i.e. the message, never the envelope.
//
// These tests bind to the bytes actually sent. Delete the `bot` field from
// notify.mjs and the first one fails.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sendNotify } from '../src/notify.mjs';

/** Capture the single fetch call sendNotify makes, and return its parsed body. */
async function captureBody(fn) {
  const realFetch = globalThis.fetch;
  const realKey = process.env.NOTIFY_API_KEY;
  const realOff = process.env.HEALER_NO_PING;
  let captured = null;
  process.env.NOTIFY_API_KEY = 'test-key';
  delete process.env.HEALER_NO_PING;
  globalThis.fetch = async (_url, init) => {
    captured = JSON.parse(init.body);
    return { ok: true, status: 200, text: async () => '' };
  };
  try {
    await fn();
  } finally {
    globalThis.fetch = realFetch;
    if (realKey === undefined) delete process.env.NOTIFY_API_KEY;
    else process.env.NOTIFY_API_KEY = realKey;
    if (realOff !== undefined) process.env.HEALER_NO_PING = realOff;
  }
  return captured;
}

test('sendNotify addresses the INFRA bot by default, not notify\'s "dreams" fallback', async () => {
  const body = await captureBody(() => sendNotify('Self-healer: RED'));
  assert.equal(body.bot, 'infra',
    'omitting `bot` makes notify fall back to "dreams" — self-healer alerts must speak as Enspyr Infra');
});

test('sendNotify still carries the message and parse_mode alongside the bot', async () => {
  const body = await captureBody(() => sendNotify('Self-healer: RED'));
  assert.equal(body.message, 'Self-healer: RED');
  assert.equal(body.parse_mode, 'HTML');
});

test('the bot identity is overridable per call', async () => {
  const body = await captureBody(() => sendNotify('hello', { bot: 'dreams' }));
  assert.equal(body.bot, 'dreams');
});
