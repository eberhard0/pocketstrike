# PocketStrike image server (office PC)

Lets PocketStrike on the phone make pictures on this PC's NVIDIA card.

    phone ──https──> Cloudflare tunnel ──> imagegen_server.py (127.0.0.1:8190, token)
                                              └──> ComfyUI (127.0.0.1:8188, never exposed)

- `imagegen_server.py`: four calls (`/health`, `/models`, `/generate`, `/result/{id}`),
  Bearer token, builds the ComfyUI text-to-image graph itself. The phone never
  reaches ComfyUI (it has no login and can install code).
- `models.json` (copy of `models.example.json`, edited to the checkpoint files
  actually in `ComfyUI/models/checkpoints/`): what the phone can pick, with
  steps / cfg / sampler / negative prompt per model. Only entries whose file
  ComfyUI has are offered.
- `pocketstrike-imagegen.service`: systemd unit; token in
  `~/.config/pocketstrike-imagegen.env` as `POCKETSTRIKE_PC_TOKEN=…` (chmod 600,
  never committed).

Setup steps: see the handoff note `POCKETSTRIKE-PC-IMAGES-HANDOFF.md`.
