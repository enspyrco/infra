#!/usr/bin/env python3
"""Tiny Telegram notify proxy.

Accepts authed POSTs and forwards to the Telegram Bot API. Built so remote
scheduled agents (claude.ai routines, GitHub Actions, etc.) can send Nick a
Telegram message via a single curl call without holding the bot token themselves.

Endpoints:
  GET  /health                  -> 200 {"ok": true}  (unauthed liveness)
  GET  /heartbeat               -> 200 {"last_delivery_ok": <epoch>, "age_seconds": N}
       Header: Authorization: Bearer <NOTIFY_API_KEY>
       The dead-man's-switch feed: `last_delivery_ok` is the epoch of the most
       recent send that Telegram actually accepted (a real delivery). An outside
       witness (the Melbourne canary) polls this; a stale age means Sydney's
       alert chain can no longer deliver even though the box may be alive.
  POST /send                    -> forwards to Telegram sendMessage
       Header: Authorization: Bearer <NOTIFY_API_KEY>
       Body:   {"message": "...", "parse_mode": "HTML"|"MarkdownV2"|null,
                "chat_id": "<override>", "bot": "dreams"|"infra"} (all optional)

`bot` selects the sending identity (default "dreams"); "infra" sends as the
Enspyr Infra bot so infra alerts don't wear the dreams identity. Unknown
selectors are rejected 400.

All secrets come from env vars:
  TELEGRAM_BOT_TOKEN  - dreams bot token from @BotFather
  TELEGRAM_CHAT_ID    - default chat to send to
  INFRA_BOT_TOKEN     - infra bot token (optional; falls back to dreams)
  INFRA_CHAT_ID       - infra default chat (optional; falls back to dreams)
  NOTIFY_API_KEY      - shared secret clients must present in Bearer auth
  PORT                - listen port (default 8090)
"""
import json
import os
import secrets
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
CHAT_ID = os.environ["TELEGRAM_CHAT_ID"]
API_KEY = os.environ["NOTIFY_API_KEY"]
PORT = int(os.environ.get("PORT", "8090"))

# Optional second identity for infra alerts, so they arrive as "Enspyr Infra"
# rather than co-mingling with dreams traffic. Falls back to the dreams bot if
# the infra creds aren't deployed, so a `bot: "infra"` request is always safe.
INFRA_BOT_TOKEN = os.environ.get("INFRA_BOT_TOKEN") or BOT_TOKEN
INFRA_CHAT_ID = os.environ.get("INFRA_CHAT_ID") or CHAT_ID

# Named-bot registry: selector -> (token, default chat_id). "dreams" is the
# default so existing callers (watchers, remote agents, GitHub Actions) that
# send no `bot` field are completely unchanged.
BOTS = {
    "dreams": (BOT_TOKEN, CHAT_ID),
    "infra": (INFRA_BOT_TOKEN, INFRA_CHAT_ID),
}

# Dead-man's-switch state: epoch of the last send Telegram actually accepted.
# Initialised to process start (optimistic — assume the chain works at boot; a
# broken chain shows up when the next pulse fails to refresh this within the
# witness's staleness threshold). Updated on every successful /send.
last_delivery_ok = time.time()


class NotifyHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", file=sys.stderr, flush=True)

    def _reply(self, status, body):
        body_b = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_b)))
        self.end_headers()
        self.wfile.write(body_b)

    def _authed(self):
        auth = self.headers.get("Authorization", "")
        return auth.startswith("Bearer ") and secrets.compare_digest(
            auth.removeprefix("Bearer "), API_KEY)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"ok": True})
        elif self.path == "/heartbeat":
            # Authed: exposes the alert cadence, so keep it off the public web.
            if not self._authed():
                self._reply(401, {"error": "unauthorized"})
                return
            self._reply(200, {
                "last_delivery_ok": int(last_delivery_ok),
                "age_seconds": int(time.time() - last_delivery_ok),
            })
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self):
        if not self._authed():
            self._reply(401, {"error": "unauthorized"})
            return
        if self.path != "/send":
            self._reply(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length > 16384:
            self._reply(413, {"error": "payload too large"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode() or "{}")
        except json.JSONDecodeError:
            self._reply(400, {"error": "invalid json"})
            return
        message = payload.get("message")
        if not message:
            self._reply(400, {"error": "missing 'message' field"})
            return
        bot = payload.get("bot", "dreams")
        if bot not in BOTS:
            self._reply(400, {"error": f"unknown bot '{bot}' (known: {', '.join(BOTS)})"})
            return
        bot_token, bot_chat = BOTS[bot]
        tg_payload = {
            "chat_id": payload.get("chat_id", bot_chat),
            "text": message,
        }
        parse_mode = payload.get("parse_mode", "HTML")
        if parse_mode:
            tg_payload["parse_mode"] = parse_mode
        if payload.get("disable_notification"):
            tg_payload["disable_notification"] = True

        req = urllib.request.Request(
            f"https://api.telegram.org/bot{bot_token}/sendMessage",
            data=json.dumps(tg_payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                tg_body = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            tg_body = {"ok": False, "error": f"telegram http {e.code}: {e.read().decode()[:200]}"}
        except Exception as e:
            self._reply(502, {"error": f"telegram api error: {e}"})
            return
        if tg_body.get("ok"):
            # A real delivery — refresh the dead-man's-switch timestamp.
            global last_delivery_ok
            last_delivery_ok = time.time()
        self._reply(200 if tg_body.get("ok") else 502, tg_body)


if __name__ == "__main__":
    print(f"notify listening on 0.0.0.0:{PORT}", file=sys.stderr, flush=True)
    HTTPServer(("0.0.0.0", PORT), NotifyHandler).serve_forever()
