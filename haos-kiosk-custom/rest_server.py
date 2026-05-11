import os
import asyncio
import logging
import re
import sys
from aiohttp import web

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: [%(filename)s] %(message)s",
    datefmt="%H:%M:%S",
)

REST_PORT = int(os.getenv("REST_PORT", "8080"))
REST_BEARER_TOKEN = os.getenv("REST_BEARER_TOKEN", "")
REST_IP = "127.0.0.1"  # local-only

MAX_PROCS = 5
_SUBPROC_SEM = asyncio.Semaphore(MAX_PROCS)
_current_procs: set[asyncio.subprocess.Process] = set()


def check_auth(request: web.Request) -> bool:
    if not REST_BEARER_TOKEN:
        return True
    auth = request.headers.get("Authorization", "")
    return auth == f"Bearer {REST_BEARER_TOKEN}"


async def run_command(command: str, log_prefix: str, cmd_timeout: int = 10) -> dict:
    async with _SUBPROC_SEM:
        full_command = f"export DISPLAY=:0 && {command}"
        proc = await asyncio.create_subprocess_shell(
            full_command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _current_procs.add(proc)
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=cmd_timeout)
            result = {
                "success": proc.returncode == 0,
                "stdout": stdout.decode(errors="replace").strip(),
                "stderr": stderr.decode(errors="replace").strip(),
            }
            logging.info(f"[{log_prefix}] returncode={proc.returncode}")
            return result
        except asyncio.TimeoutError:
            proc.kill()
            return {"success": False, "error": "Command timed out"}
        except Exception as e:
            return {"success": False, "error": str(e)}
        finally:
            _current_procs.discard(proc)


def unauthorized() -> web.Response:
    return web.json_response({"error": "Unauthorized"}, status=401)


async def handle_display_on(request: web.Request) -> web.Response:
    if not check_auth(request):
        return unauthorized()
    logging.info("[display_on] Turning display on")
    return web.json_response(await run_command("xset dpms force on", "display_on"))


async def handle_display_off(request: web.Request) -> web.Response:
    if not check_auth(request):
        return unauthorized()
    logging.info("[display_off] Turning display off")
    return web.json_response(await run_command("xset dpms force off", "display_off"))


async def handle_toggle_keyboard(request: web.Request) -> web.Response:
    if not check_auth(request):
        return unauthorized()
    logging.info("[keyboard_toggle] Toggling matchbox-keyboard")
    # Kill if running, start if not.
    cmd = "pgrep matchbox-keyboard >/dev/null && pkill matchbox-keyboard || matchbox-keyboard &"
    return web.json_response(await run_command(cmd, "keyboard_toggle"))


async def handle_refresh(request: web.Request) -> web.Response:
    if not check_auth(request):
        return unauthorized()
    logging.info("[refresh] Refreshing browser")
    cmd = (
        "WINDOW=$(xdotool search --class chromium | head -1) && "
        '[ -n "$WINDOW" ] && xdotool key --window "$WINDOW" ctrl+r'
    )
    return web.json_response(await run_command(cmd, "refresh"))


async def handle_navigate(request: web.Request) -> web.Response:
    if not check_auth(request):
        return unauthorized()
    try:
        data = await request.json()
    except Exception:
        return web.json_response({"error": "Invalid JSON body"}, status=400)

    url = str(data.get("url", "")).strip()
    url_regex = re.compile(
        r"^(https?://)?(?:localhost|\d{1,3}(?:\.\d{1,3}){3}|[a-z0-9.-]+)"
        r"(?::\d+)?(?:/.*)?$",
        re.IGNORECASE,
    )
    if not url or not url_regex.match(url):
        return web.json_response({"error": "Invalid URL"}, status=400)

    logging.info(f"[navigate] Navigating to: {url}")
    cmd = (
        "WINDOW=$(xdotool search --class chromium | head -1) && "
        '[ -n "$WINDOW" ] && '
        'xdotool key --window "$WINDOW" ctrl+l && '
        "sleep 0.2 && "
        f"xdotool type --clearmodifiers '{url}' && "
        'xdotool key --window "$WINDOW" Return'
    )
    return web.json_response(await run_command(cmd, "navigate"))


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({"status": "ok"})


async def main() -> None:
    app = web.Application()
    app.router.add_get("/health", handle_health)
    app.router.add_post("/display_on", handle_display_on)
    app.router.add_post("/display_off", handle_display_off)
    app.router.add_post("/keyboard/toggle", handle_toggle_keyboard)
    app.router.add_post("/browser/refresh", handle_refresh)
    app.router.add_post("/browser/navigate", handle_navigate)

    logging.info(f"[main] Starting REST server on http://{REST_IP}:{REST_PORT}")
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, REST_IP, REST_PORT)
    await site.start()
    logging.info("[main] Server started — ready to accept requests")
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())

