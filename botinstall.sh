#!/bin/bash
set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
APP_DIR=/opt/tg-monitor
ENV_FILE=/etc/tg-monitor.env
UNIT=/etc/systemd/system/tg-monitor.service

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root (sudo bash install.sh)${NC}"
  exit 1
fi

echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}      Telegram Server Monitor Bot      ${NC}"
echo -e "${GREEN}=======================================${NC}"
echo "1) Install / Update Advanced Bot"
echo "2) Completely Uninstall"
echo "3) Exit"
read -p "Select an option [1-3]: " choice

case "$choice" in
  1) ;;
  2)
    systemctl disable --now tg-monitor.service 2>/dev/null || true
    rm -f "$UNIT" "$ENV_FILE"
    rm -rf "$APP_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}Bot uninstalled successfully.${NC}"
    exit 0 ;;
  *) exit 0 ;;
esac

echo ""
read -p "Bot Token (from @BotFather): " BOT_TOKEN
read -p "Admin Telegram ID(s) [Comma separated]: " ADMIN_IDS
read -p "Systemd Services to watch (e.g., nginx,docker,xray) [Leave blank for none]: " WATCH_SERVICES

echo -e "\n${YELLOW}Installing dependencies...${NC}"
apt-get update -q
apt-get install -y -q python3-venv python3-pip net-tools
mkdir -p "$APP_DIR"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q pyTelegramBotAPI psutil

echo -e "${YELLOW}Generating bot.py...${NC}"
cat > "$APP_DIR/bot.py" << 'PYEOF'
import os
import html
import socket
import logging
import functools
import threading
import subprocess
import time

import psutil
import telebot
from telebot import types
from telebot.apihelper import ApiTelegramException

BOT_TOKEN = os.environ["BOT_TOKEN"]
ADMIN_IDS = {int(x) for x in os.environ["ADMIN_IDS"].replace(" ", "").split(",") if x}
WATCH_SERVICES = [s.strip() for s in os.environ.get("WATCH_SERVICES", "").split(",") if s.strip()]
ALERTS = {
    "cpu": float(os.environ.get("ALERT_CPU", 90)),
    "ram": float(os.environ.get("ALERT_RAM", 90)),
    "disk": float(os.environ.get("ALERT_DISK", 90)),
}
LIVE_SECONDS = 60
ALERT_COOLDOWN = 600

# Ignore virtual interfaces to prevent duplicate traffic calculation
SKIP_IFACES = ("lo", "docker", "br-", "veth", "virbr", "cni", "flannel", "tun", "tap", "wg")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("tg-monitor")

bot = telebot.TeleBot(BOT_TOKEN, parse_mode="HTML")
HOSTNAME = socket.gethostname()

def is_admin(uid):
    return uid in ADMIN_IDS

def admin_only(fn):
    @functools.wraps(fn)
    def wrapper(m):
        if not is_admin(m.from_user.id):
            return bot.reply_to(m, "⛔ Unauthorized access.")
        return fn(m)
    return wrapper

def fmt_bps(bps):
    for unit in ("bps", "Kbps", "Mbps", "Gbps"):
        if bps < 1000 or unit == "Gbps": return f"{bps:.2f} {unit}"
        bps /= 1000

def fmt_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB": return f"{n:.2f} {unit}"
        n /= 1024

def fmt_uptime():
    s = int(time.time() - psutil.boot_time())
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    return f"{d}d {h}h {s // 60}m"

def bar(pct, width=10):
    filled = round(pct / 100 * width)
    return "▓" * filled + "░" * (width - filled)

def run_cmd(*args):
    r = subprocess.run(args, capture_output=True, text=True, timeout=15)
    return r.stdout.strip(), r.stderr.strip(), r.returncode

def read_net_io():
    rx = tx = 0
    for name, c in psutil.net_io_counters(pernic=True).items():
        if name.startswith(SKIP_IFACES): continue
        rx += c.bytes_recv
        tx += c.bytes_sent
    return rx, tx

state_lock = threading.Lock()
state = {
    "cpu": 0.0, "ram": 0.0, "disk": 0.0,
    "down": 0.0, "up": 0.0,
    "max_down": 0.0, "max_up": 0.0,
    "min_down": None, "min_up": None,
    "rx_total": 0, "tx_total": 0,
}

def snapshot():
    with state_lock: return dict(state)

def reset_minmax():
    with state_lock:
        state.update(max_down=0.0, max_up=0.0, min_down=None, min_up=None)

def sampler():
    psutil.cpu_percent(None)
    last_t = time.time()
    last_rx, last_tx = read_net_io()
    while True:
        time.sleep(1)
        now = time.time()
        rx, tx = read_net_io()
        dt = max(now - last_t, 1e-6)
        down = max(rx - last_rx, 0) * 8 / dt
        up = max(tx - last_tx, 0) * 8 / dt
        last_t, last_rx, last_tx = now, rx, tx

        with state_lock:
            state.update(
                cpu=psutil.cpu_percent(None),
                ram=psutil.virtual_memory().percent,
                disk=psutil.disk_usage("/").percent,
                down=down, up=up, rx_total=rx, tx_total=tx
            )
            state["max_down"] = max(state["max_down"], down)
            state["max_up"] = max(state["max_up"], up)
            if down > 0: state["min_down"] = down if state["min_down"] is None else min(state["min_down"], down)
            if up > 0: state["min_up"] = up if state["min_up"] is None else min(state["min_up"], up)

def dashboard_markup(remaining=0):
    s = snapshot()
    kb = types.InlineKeyboardMarkup(row_width=2)
    kb.add(
        types.InlineKeyboardButton(f"🖥 CPU: {s['cpu']:.1f}%", callback_data="noop"),
        types.InlineKeyboardButton(f"🧠 RAM: {s['ram']:.1f}%", callback_data="noop"),
        types.InlineKeyboardButton(f"💽 Disk: {s['disk']:.1f}%", callback_data="noop"),
        types.InlineKeyboardButton(f"⏱ Up: {fmt_uptime()}", callback_data="noop"),
        types.InlineKeyboardButton(f"📥 DL: {fmt_bps(s['down'])}", callback_data="noop"),
        types.InlineKeyboardButton(f"📤 UL: {fmt_bps(s['up'])}", callback_data="noop"),
        types.InlineKeyboardButton(f"🔻 Max: {fmt_bps(s['max_down'])}", callback_data="noop"),
        types.InlineKeyboardButton(f"🔺 Max: {fmt_bps(s['max_up'])}", callback_data="noop"),
        types.InlineKeyboardButton(f"📉 Min: {fmt_bps(s['min_down'] or 0)}", callback_data="noop"),
        types.InlineKeyboardButton(f"📈 Min: {fmt_bps(s['min_up'] or 0)}", callback_data="noop"),
        types.InlineKeyboardButton(f"💾 Ttl ↓ {fmt_bytes(s['rx_total'])}", callback_data="noop"),
        types.InlineKeyboardButton(f"💾 Ttl ↑ {fmt_bytes(s['tx_total'])}", callback_data="noop")
    )
    if remaining > 0:
        kb.add(types.InlineKeyboardButton(f"⏱ Live ({remaining}s) — Extend", callback_data="refresh"))
    else:
        kb.add(types.InlineKeyboardButton("🔄 Restart Live", callback_data="refresh"))
    kb.add(
        types.InlineKeyboardButton("♻️ Reset Min/Max", callback_data="reset"),
        types.InlineKeyboardButton("⏹ Stop", callback_data="stop")
    )
    return kb

live = {}
live_lock = threading.Lock()

def start_live(chat_id, msg_id):
    with live_lock: live[msg_id] = {"chat": chat_id, "until": time.time() + LIVE_SECONDS}

def stop_live(msg_id):
    with live_lock: live.pop(msg_id, None)

def safe_edit(chat_id, msg_id, markup):
    try:
        bot.edit_message_reply_markup(chat_id, msg_id, reply_markup=markup)
    except ApiTelegramException as e:
        text = (e.description or "").lower()
        if "not modified" in text: return
        if "not found" in text or "can't be edited" in text: stop_live(msg_id)
        elif e.error_code == 429: time.sleep(((e.result_json or {}).get("parameters") or {}).get("retry_after", 5))

def live_loop():
    while True:
        time.sleep(2)
        now = time.time()
        with live_lock: items = list(live.items())
        for msg_id, info in items:
            remaining = int(info["until"] - now)
            if remaining <= 0:
                stop_live(msg_id)
                safe_edit(info["chat"], msg_id, dashboard_markup(0))
            else:
                safe_edit(info["chat"], msg_id, dashboard_markup(remaining))

def notify_admins(text):
    for uid in ADMIN_IDS:
        try: bot.send_message(uid, text, parse_mode="HTML")
        except: pass

def alert_loop():
    last_alerts = {}
    active_ssh_users = set()
    
    while True:
        time.sleep(10)
        s = snapshot()
        now = time.time()
        
        # Resource Alerts
        for key, threshold in ALERTS.items():
            value = s[key]
            if value >= threshold and now - last_alerts.get(key, 0) > ALERT_COOLDOWN:
                last_alerts[key] = now
                notify_admins(f"🚨 <b>{key.upper()} ALERT</b> — <code>{HOSTNAME}</code>\nCurrent: {value:.1f}% (Threshold: {threshold:.0f}%)")
        
        # SSH Login Alerts
        try:
            current_users = {f"{u.name} @ {u.host or 'local'}" for u in psutil.users()}
            new_users = current_users - active_ssh_users
            if new_users and active_ssh_users:
                notify_admins(f"⚠️ <b>New SSH Login</b>\nUser(s): <code>{', '.join(new_users)}</code>")
            active_ssh_users = current_users
        except: pass

HELP = (
    "🤖 <b>Server Monitor Bot</b>\n\n"
    "/stats — Live Resource Dashboard\n"
    "/top — Top Consuming Processes\n"
    "/net — Open Ports & Connections\n"
    "/disk — Storage Information\n"
    "/services — Systemd Services\n"
    "/docker — Docker Containers\n"
    "/cmd [cmd] — Execute Terminal Command\n"
    "/reboot — Reboot Server\n"
)

@bot.message_handler(commands=["start", "help"])
@admin_only
def cmd_help(m): bot.reply_to(m, HELP)

@bot.message_handler(commands=["stats"])
@admin_only
def cmd_stats(m):
    sent = bot.reply_to(m, f"📊 <b>Live Monitoring</b> — <code>{HOSTNAME}</code>\n<i>Updates every 2 seconds.</i>", reply_markup=dashboard_markup(LIVE_SECONDS))
    start_live(m.chat.id, sent.message_id)

@bot.message_handler(commands=["top"])
@admin_only
def cmd_top(m):
    procs = []
    for p in psutil.process_iter(['pid', 'name', 'cpu_percent', 'memory_percent']):
        try: procs.append(p.info)
        except: pass
    time.sleep(0.5)
    for p in procs:
        try: p['cpu_percent'] = psutil.Process(p['pid']).cpu_percent(None)
        except: p['cpu_percent'] = 0
    procs.sort(key=lambda x: x.get('cpu_percent', 0), reverse=True)
    
    lines = [f"{i}. <code>{html.escape(p['name'])}</code> (pid {p['pid']}) — CPU {p['cpu_percent']:.1f}% | RAM {p['memory_percent']:.1f}%" for i, p in enumerate(procs[:10], 1)]
    bot.reply_to(m, "🔥 <b>Top Processes</b>\n\n" + "\n".join(lines))

@bot.message_handler(commands=["net"])
@admin_only
def cmd_net(m):
    out, err, _ = run_cmd("ss", "-tulnp")
    lines = out.split("\n")
    result = "\n".join(lines[:15])
    if len(lines) > 15: result += f"\n... and {len(lines)-15} more connections."
    bot.reply_to(m, f"🌐 <b>Open Ports & Services</b>\n<pre>{html.escape(result)}</pre>")

@bot.message_handler(commands=["cmd"])
@admin_only
def cmd_exec(m):
    cmd = m.text[4:].strip()
    if not cmd: return bot.reply_to(m, "⚠️ Please provide a command. Example:\n`/cmd ls -la`", parse_mode="Markdown")
    bot.send_chat_action(m.chat.id, 'typing')
    out, err, code = run_cmd("bash", "-c", cmd)
    res = out or err or "Command executed successfully (no output)."
    bot.reply_to(m, f"💻 <b>Terminal Output</b>\n<pre>{html.escape(res[-3800:])}</pre>")

@bot.message_handler(commands=["disk"])
@admin_only
def cmd_disk(m):
    lines = []
    for part in psutil.disk_partitions(all=False):
        if part.mountpoint.startswith(("/snap", "/boot", "/sys", "/proc", "/dev")): continue
        try: u = psutil.disk_usage(part.mountpoint)
        except OSError: continue
        lines.append(f"<code>{html.escape(part.mountpoint)}</code> ({part.fstype})\n{bar(u.percent)} {u.percent:.1f}%  ({fmt_bytes(u.used)} / {fmt_bytes(u.total)})")
    bot.reply_to(m, "💽 <b>Disk Usage</b>\n\n" + ("\n\n".join(lines) or "No disks found."))

def services_markup():
    kb = types.InlineKeyboardMarkup(row_width=2)
    for svc in WATCH_SERVICES:
        out, _, _ = run_cmd("systemctl", "is-active", svc)
        icon = "🟢" if out == "active" else "🔴"
        kb.add(
            types.InlineKeyboardButton(f"{icon} {svc}", callback_data="noop"),
            types.InlineKeyboardButton("🔄 Restart", callback_data=f"sys_restart:{svc}")
        )
    kb.add(types.InlineKeyboardButton("🔃 Refresh", callback_data="svc_refresh"))
    return kb

@bot.message_handler(commands=["services"])
@admin_only
def cmd_services(m):
    if not WATCH_SERVICES: return bot.reply_to(m, "No services configured in WATCH_SERVICES.")
    bot.reply_to(m, "⚙️ <b>System Services</b>", reply_markup=services_markup())

def docker_markup(containers):
    kb = types.InlineKeyboardMarkup(row_width=2)
    for name, status in containers:
        icon = "🟢" if "Up" in status else "🔴"
        kb.add(
            types.InlineKeyboardButton(f"{icon} {name}", callback_data="noop"),
            types.InlineKeyboardButton("🔄 Restart", callback_data=f"dkr_restart:{name}")
        )
    kb.add(types.InlineKeyboardButton("🔃 Refresh Docker", callback_data="dkr_refresh"))
    return kb

@bot.message_handler(commands=["docker"])
@admin_only
def cmd_docker(m):
    out, _, code = run_cmd("docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}")
    if code != 0: return bot.reply_to(m, "⚠️ Docker is not installed or accessible.")
    containers = [line.split("|") for line in out.split("\n") if "|" in line]
    if not containers: return bot.reply_to(m, "No containers found.")
    bot.reply_to(m, "🐳 <b>Docker Containers</b>", reply_markup=docker_markup(containers))

@bot.message_handler(commands=["reboot"])
@admin_only
def cmd_reboot(m):
    kb = types.InlineKeyboardMarkup()
    kb.add(types.InlineKeyboardButton("✅ Yes, Reboot", callback_data="reboot_yes"), types.InlineKeyboardButton("❌ Cancel", callback_data="reboot_no"))
    bot.reply_to(m, "⚠️ Are you sure you want to reboot the server?", reply_markup=kb)

@bot.callback_query_handler(func=lambda c: True)
def on_callback(c):
    if not is_admin(c.from_user.id): return bot.answer_callback_query(c.id, "⛔ Unauthorized access", show_alert=True)
    msg, data = c.message, c.data or ""
    if data == "noop": return bot.answer_callback_query(c.id)

    if data == "refresh":
        start_live(msg.chat.id, msg.message_id)
        return bot.answer_callback_query(c.id, f"✅ Extended by {LIVE_SECONDS}s")

    if data == "reset":
        reset_minmax()
        return bot.answer_callback_query(c.id, "♻️ Min/Max reset")

    if data == "stop":
        stop_live(msg.message_id)
        safe_edit(msg.chat.id, msg.message_id, dashboard_markup(0))
        return bot.answer_callback_query(c.id, "⏹ Stopped")

    if data == "svc_refresh":
        return safe_edit(msg.chat.id, msg.message_id, services_markup())
        
    if data == "dkr_refresh":
        out, _, _ = run_cmd("docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}")
        containers = [line.split("|") for line in out.split("\n") if "|" in line]
        return safe_edit(msg.chat.id, msg.message_id, docker_markup(containers))

    if data.startswith("sys_restart:"):
        svc = data.split(":", 1)[1]
        bot.answer_callback_query(c.id, f"⏳ Restarting {svc}...")
        _, err, code = run_cmd("systemctl", "restart", svc)
        status = "✅ Successfully restarted" if code == 0 else f"❌ Error: {html.escape(err[:100])}"
        bot.send_message(msg.chat.id, f"<code>{html.escape(svc)}</code>: {status}")
        return safe_edit(msg.chat.id, msg.message_id, services_markup())

    if data.startswith("dkr_restart:"):
        name = data.split(":", 1)[1]
        bot.answer_callback_query(c.id, f"⏳ Restarting container {name}...")
        _, err, code = run_cmd("docker", "restart", name)
        status = "✅ Successfully restarted" if code == 0 else f"❌ Error: {html.escape(err[:100])}"
        bot.send_message(msg.chat.id, f"🐳 <code>{html.escape(name)}</code>: {status}")
        out, _, _ = run_cmd("docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}")
        containers = [line.split("|") for line in out.split("\n") if "|" in line]
        return safe_edit(msg.chat.id, msg.message_id, docker_markup(containers))

    if data == "reboot_yes":
        bot.answer_callback_query(c.id, "🔄 Rebooting...")
        bot.edit_message_text("🔄 Server is rebooting...", chat_id=msg.chat.id, message_id=msg.message_id)
        subprocess.Popen(["systemctl", "reboot"])
        return

    if data == "reboot_no":
        bot.edit_message_text("❌ Reboot canceled.", chat_id=msg.chat.id, message_id=msg.message_id)
        return bot.answer_callback_query(c.id)

if __name__ == "__main__":
    threading.Thread(target=sampler, daemon=True).start()
    threading.Thread(target=live_loop, daemon=True).start()
    threading.Thread(target=alert_loop, daemon=True).start()
    log.info("Bot started on %s", HOSTNAME)
    bot.infinity_polling(skip_pending=True, timeout=60)
PYEOF

echo -e "${YELLOW}Creating systemd configuration...${NC}"
umask 077
cat > "$ENV_FILE" << EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_IDS=$ADMIN_IDS
WATCH_SERVICES=$WATCH_SERVICES
ALERT_CPU=90
ALERT_RAM=90
ALERT_DISK=90
EOF
chmod 600 "$ENV_FILE"
umask 022

cat > "$UNIT" << 'EOF'
[Unit]
Description=Telegram Server Monitor Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/tg-monitor
EnvironmentFile=/etc/tg-monitor.env
ExecStart=/opt/tg-monitor/venv/bin/python /opt/tg-monitor/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

"$APP_DIR/venv/bin/python" -m py_compile "$APP_DIR/bot.py"
systemctl daemon-reload
systemctl enable --now tg-monitor.service
systemctl restart tg-monitor.service
echo -e "${GREEN}✅ Bot installed and started successfully.${NC}"
echo -e "Check logs using: ${YELLOW}journalctl -u tg-monitor -f${NC}"
