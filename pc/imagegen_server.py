#!/usr/bin/env python3
"""PocketStrike image server: the office PC's NVIDIA card draws for the phone.

A small, token-guarded front for a ComfyUI running on this PC. The phone never
talks to ComfyUI itself (ComfyUI has no login and can install code); it talks
to this server, which offers four calls and builds the ComfyUI graph here:

    GET  /health        {"ok", "gpu", "vram_gb", "queue"}
    GET  /models        [{"id", "name", "kind", "size", ...defaults}]
    POST /generate      {"prompt", "negative_prompt"?, "model"?, "width"?, "height"?,
                         "steps"?, "cfg"?, "seed"?}  ->  {"id"}
    GET  /result/{id}   200 image/png  |  202 {"status": "queued"|"running", "position"?}
                        |  500 {"error"}

Generation is asynchronous (generate, then poll result) so no request waits
longer than Cloudflare's 100 s limit. Every call needs
"Authorization: Bearer <POCKETSTRIKE_PC_TOKEN>".

Env:  POCKETSTRIKE_PC_TOKEN (required, 32+ chars), COMFY_URL (default
http://127.0.0.1:8188), HOST (127.0.0.1), PORT (8190), MODELS_FILE
(models.json next to this file).
"""
from __future__ import annotations

import hmac
import json
import logging
import os
import random
import re
import sys
import uuid
from pathlib import Path

from aiohttp import ClientSession, ClientTimeout, web

log = logging.getLogger("pocketstrike-imagegen")

HERE = Path(__file__).resolve().parent
TOKEN = os.getenv("POCKETSTRIKE_PC_TOKEN", "")
COMFY = os.getenv("COMFY_URL", "http://127.0.0.1:8188").rstrip("/")
HOST = os.getenv("HOST", "127.0.0.1")
PORT = int(os.getenv("PORT", "8190"))
MODELS_FILE = Path(os.getenv("MODELS_FILE", HERE / "models.json"))

MAX_PROMPT = 2000
MIN_SIDE, MAX_SIDE = 512, 1536
MAX_STEPS = 60
ID_RE = re.compile(r"^[0-9a-f-]{36}$")
CLIENT_ID = str(uuid.uuid4())


def load_models() -> list[dict]:
    """models.json: the checkpoints this server offers, with their defaults."""
    return json.loads(MODELS_FILE.read_text())


# ── auth ─────────────────────────────────────────────────────────────

@web.middleware
async def bearer(request: web.Request, handler):
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(token.strip().encode(), TOKEN.encode()):
        return web.json_response({"error": "unauthorized"}, status=401)
    return await handler(request)


# ── ComfyUI ──────────────────────────────────────────────────────────

async def comfy_get(app: web.Application, path: str):
    async with app["http"].get(COMFY + path) as r:
        r.raise_for_status()
        return await r.json()


async def installed_checkpoints(app: web.Application) -> set[str]:
    info = await comfy_get(app, "/object_info/CheckpointLoaderSimple")
    return set(info["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0])


async def offered_models(app: web.Application) -> list[dict]:
    """models.json entries whose checkpoint ComfyUI actually has."""
    have = await installed_checkpoints(app)
    return [m for m in load_models() if m["checkpoint"] in have]


def snap(v, default: int) -> int:
    try:
        v = int(v)
    except (TypeError, ValueError):
        v = default
    v = max(MIN_SIDE, min(MAX_SIDE, v))
    return v - v % 64


def graph(m: dict, prompt: str, negative: str, width: int, height: int,
          steps: int, cfg: float, seed: int) -> dict:
    """Text to image with one all-in-one checkpoint (SDXL, or Flux schnell fp8 with cfg 1)."""
    return {
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": m["checkpoint"]}},
        "5": {"class_type": "EmptyLatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["4", 1]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["4", 1]}},
        "3": {"class_type": "KSampler", "inputs": {
            "seed": seed, "steps": steps, "cfg": cfg,
            "sampler_name": m.get("sampler", "euler"), "scheduler": m.get("scheduler", "normal"),
            "denoise": 1.0, "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0],
            "latent_image": ["5", 0]}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
        "9": {"class_type": "SaveImage", "inputs": {"filename_prefix": "pocketstrike/img", "images": ["8", 0]}},
    }


# ── handlers ─────────────────────────────────────────────────────────

async def health(request: web.Request):
    app = request.app
    stats = await comfy_get(app, "/system_stats")
    dev = (stats.get("devices") or [{}])[0]
    queue = await comfy_get(app, "/queue")
    return web.json_response({
        "ok": True,
        "gpu": dev.get("name", "?"),
        "vram_gb": round((dev.get("vram_total") or 0) / 2**30, 1),
        "queue": len(queue.get("queue_running", [])) + len(queue.get("queue_pending", [])),
    })


async def models(request: web.Request):
    out = []
    for m in await offered_models(request.app):
        out.append({k: m[k] for k in m if k != "checkpoint"})
    return web.json_response(out)


async def generate(request: web.Request):
    app = request.app
    try:
        body = await request.json()
    except json.JSONDecodeError:
        return web.json_response({"error": "Send JSON."}, status=400)
    prompt = str(body.get("prompt", "")).strip()[:MAX_PROMPT]
    if not prompt:
        return web.json_response({"error": "Empty prompt."}, status=400)

    offered = await offered_models(app)
    if not offered:
        return web.json_response({"error": "No image model is installed on the PC."}, status=503)
    m = next((x for x in offered if x["id"] == body.get("model")), offered[0])

    negative = str(body.get("negative_prompt") or m.get("negative", "")).strip()[:MAX_PROMPT]
    size = int(m.get("size", 1024))
    width, height = snap(body.get("width"), size), snap(body.get("height"), size)
    try:
        steps = max(1, min(MAX_STEPS, int(body.get("steps") or m.get("steps", 25))))
        cfg = max(1.0, min(15.0, float(body.get("cfg") or m.get("cfg", 6.0))))
        seed = int(body["seed"]) if body.get("seed") is not None else random.randrange(2**32)
    except (TypeError, ValueError):
        return web.json_response({"error": "Bad steps, cfg or seed."}, status=400)

    if m.get("prefix"):
        prompt = f"{m['prefix']}, {prompt}"
    payload = {"prompt": graph(m, prompt, negative, width, height, steps, cfg, seed), "client_id": CLIENT_ID}
    async with app["http"].post(COMFY + "/prompt", json=payload) as r:
        reply = await r.json(content_type=None)
        if r.status != 200 or "prompt_id" not in reply:
            log.warning("comfy refused: %s", reply)
            return web.json_response({"error": "The PC's image engine refused the job."}, status=502)
    log.info("job %s model=%s %dx%d steps=%d", reply["prompt_id"], m["id"], width, height, steps)
    return web.json_response({"id": reply["prompt_id"], "model": m["id"], "width": width, "height": height})


async def result(request: web.Request):
    app = request.app
    pid = request.match_info["id"]
    if not ID_RE.match(pid):
        return web.json_response({"error": "Unknown job."}, status=404)

    hist = (await comfy_get(app, f"/history/{pid}")).get(pid)
    if not hist:
        queue = await comfy_get(app, "/queue")
        if any(item[1] == pid for item in queue.get("queue_running", [])):
            return web.json_response({"status": "running"}, status=202)
        pending = sorted(queue.get("queue_pending", []), key=lambda item: item[0])
        for pos, item in enumerate(pending, 1):
            if item[1] == pid:
                return web.json_response({"status": "queued", "position": pos}, status=202)
        return web.json_response({"error": "Unknown job."}, status=404)

    status = hist.get("status", {})
    if status.get("status_str") == "error":
        msg = next((m[1].get("exception_message") for m in status.get("messages", [])
                    if m[0] == "execution_error"), None)
        return web.json_response({"error": f"The PC couldn't make the image: {msg or 'engine error'}"}, status=500)
    for out in hist.get("outputs", {}).values():
        for img in out.get("images", []):
            params = {"filename": img["filename"], "subfolder": img.get("subfolder", ""),
                      "type": img.get("type", "output")}
            async with app["http"].get(COMFY + "/view", params=params) as r:
                r.raise_for_status()
                data = await r.read()
            return web.Response(body=data, content_type="image/png")
    return web.json_response({"status": "running"}, status=202)


@web.middleware
async def errors(request: web.Request, handler):
    try:
        return await handler(request)
    except web.HTTPException:
        raise
    except Exception as e:  # noqa: BLE001 — ComfyUI down, bad models.json, …
        log.exception("request failed")
        return web.json_response({"error": f"The PC's image engine isn't answering ({type(e).__name__})."},
                                 status=503)


async def on_start(app: web.Application):
    app["http"] = ClientSession(timeout=ClientTimeout(total=60))


async def on_stop(app: web.Application):
    await app["http"].close()


def build_app() -> web.Application:
    app = web.Application(middlewares=[errors, bearer], client_max_size=64 * 1024)
    app.add_routes([
        web.get("/health", health),
        web.get("/models", models),
        web.post("/generate", generate),
        web.get("/result/{id}", result),
    ])
    app.on_startup.append(on_start)
    app.on_cleanup.append(on_stop)
    return app


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if len(TOKEN) < 32:
        sys.exit("Set POCKETSTRIKE_PC_TOKEN (32+ characters) before starting.")
    load_models()  # fail fast on a broken models.json
    web.run_app(build_app(), host=HOST, port=PORT)
