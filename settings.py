import json
import os

ROOT_DIR = os.path.expanduser("~/.pl")
# ROOT_DIR = os.path.expanduser(".")
os.makedirs(ROOT_DIR, exist_ok=True)

# DEFAULT_CONFIG is written to ~/.pl/config.json on first boot if no
# config exists yet. Sensitive fields (Peplink router admin password,
# Wi-Fi password) are intentionally blank — the operator fills them
# in either via the on-device Settings screen or by editing
# ~/.pl/config.json before launching the agent.
DEFAULT_CONFIG = {
    "ip": "192.168.50.1",
    "username": "admin",
    "password": "",
    "interval": 30,
    "retention_days": 30,
}

CONFIG_FILE = os.path.join(ROOT_DIR, "config.json")
if not os.path.exists(CONFIG_FILE):
    print("No config found! Creating the default one...")
    with open(CONFIG_FILE, "w") as jp:
        json.dump(DEFAULT_CONFIG, jp, indent=2)

APP_VERSION = "1.8.0"

INIT_SCREEN = "overview"
API_TIMEOUT = 5
APP_DIR = os.path.dirname(os.path.realpath(__file__))
CRASH_FILE = os.path.join(ROOT_DIR, "crash.dump")
SCREEN_SAVER_TIME = 30

# ThingsBoard provisioning credentials. Source-tracked literal removed
# in 1.4.0 — the repo is public. Drop them into ~/.pl/local_settings.py
# (gitignored) or set them in the env before launching the agent. See
# local_settings.py.example next to this file for the format.
TB_PROVISION_KEY    = os.environ.get("TB_PROVISION_KEY")
TB_PROVISION_SECRET = os.environ.get("TB_PROVISION_SECRET")
TB_SERVER_URL       = os.environ.get("TB_SERVER_URL", "http://tracker.mobilelinq.com:8080")

# Per-deployment overrides win, same pattern as the openwrt agent.
try:
    from local_settings import *  # noqa: F401,F403
except ImportError:
    pass