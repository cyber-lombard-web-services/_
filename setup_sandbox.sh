#!/bin/bash
# =============================================================================
# AI SANDBOX (Alpine Host) - 76
# By thibaut LOMBARD © copyright all rights reserved
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; }

WORK_DIR="/root/ai_sandbox"
LOG_DIR="$WORK_DIR/logs"
VM_PID_FILE="$WORK_DIR/vm.pid"

mkdir -p "$WORK_DIR" "$LOG_DIR"
cd "$WORK_DIR"

if [ "$(id -u)" -ne 0 ]; then
    err "Ce script doit être exécuté en root"
    exit 1
fi

# =============================================================================
# 1. INSTALLATION
# =============================================================================
log "Vérification des dépendances..."

if [ -e /dev/kvm ]; then
    ok "/dev/kvm présent"
    chmod 666 /dev/kvm 2>/dev/null
fi

NEED_APK=0
NEED_PIP=0
NEED_KERNEL=0

for cmd in qemu-system-x86_64 python3 pip3 curl cpio; do
    if ! command -v $cmd &>/dev/null; then
        NEED_APK=1
    fi
done

if ! python3 -c "import flask_cors" 2>/dev/null; then
    NEED_PIP=1
fi

if [ ! -f "/boot/vmlinuz-virt" ] || [ -z "$(ls -d /lib/modules/*-virt 2>/dev/null)" ]; then
    NEED_KERNEL=1
fi

if [ $NEED_APK -eq 1 ] || [ $NEED_KERNEL -eq 1 ]; then
    log "Installation des paquets..."
    apk add --no-cache qemu-system-x86_64 qemu-img python3 py3-pip py3-flask curl cpio linux-virt 2>&1 | tee "$LOG_DIR/apk.log"
else
    skip "Paquets système déjà installés"
fi

if [ $NEED_PIP -eq 1 ]; then
    log "Installation flask-cors..."
    pip3 install flask-cors --break-system-packages 2>&1 | tee "$LOG_DIR/pip.log"
else
    skip "flask-cors déjà installé"
fi

ok "Dépendances vérifiées"

# =============================================================================
# 2. KERNEL
# =============================================================================
log "Vérification du kernel..."
if [ ! -f "/boot/vmlinuz-virt" ]; then
    apk add --no-cache linux-virt
fi
cp /boot/vmlinuz-virt vmlinuz
ok "Kernel: $(ls -lh vmlinuz | awk '{print $5}')"

# =============================================================================
# 3. MODULES
# =============================================================================
log "Extraction des modules..."
MODULES_SRC=$(ls -d /lib/modules/*-virt 2>/dev/null | head -1)
if [ -z "$MODULES_SRC" ]; then
    err "Modules non trouvés"
    exit 1
fi

log "Source: $MODULES_SRC"
rm -rf modules_all
mkdir -p modules_all

find "$MODULES_SRC" -type f \( \
    -name "9p.ko*" -o \
    -name "9pnet.ko*" -o \
    -name "9pnet_virtio.ko*" -o \
    -name "netfs.ko*" \
\) -exec cp {} modules_all/ \; 2>/dev/null

for mod in modules_all/*.gz; do gunzip -f "$mod" 2>/dev/null; done
for mod in modules_all/*.zst; do zstd -d -f "$mod" 2>/dev/null; done

NB_MODULES=$(ls modules_all/*.ko 2>/dev/null | wc -l)
ok "$NB_MODULES modules extraits"

# =============================================================================
# 4. INITRAMFS
# =============================================================================
log "Construction de l'initramfs v76.0..."

rm -rf initramfs
mkdir -p initramfs/{bin,sbin,dev,proc,sys,mnt,tmp,etc,usr/bin,usr/lib,lib,modules,run}

# Busybox
cp /bin/busybox initramfs/bin/
chmod 755 initramfs/bin/busybox
cd initramfs/bin
for cmd in $(./busybox --list 2>/dev/null); do
    ln -sf busybox $cmd
done
cd ../..
ok "Busybox configuré"

# Python
cp /usr/bin/python3 initramfs/usr/bin/
chmod 755 initramfs/usr/bin/python3

PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
cp -r /usr/lib/python$PYVER initramfs/usr/lib/ 2>/dev/null || true
cp /usr/lib/libpython3* initramfs/usr/lib/ 2>/dev/null || true

# Libs
for lib in /lib/ld-musl-x86_64.so.1 /lib/libc.musl-x86_64.so.1; do
    [ -f "$lib" ] && cp "$lib" initramfs/lib/
done

# Modules
cp modules_all/*.ko initramfs/modules/ 2>/dev/null

# =============================================================================
# 5. AGENT DAEMON (avec lock)
# =============================================================================
cat > agent_daemon.py << 'AGENTEOF'
#!/usr/bin/python3
import json
import sys
import io
import traceback
import time
import os
import fcntl

REQUEST_FILE = "/mnt/request.json"
RESPONSE_FILE = "/mnt/response.json"
READY_FILE = "/mnt/agent_ready"
LOCK_FILE = "/mnt/request.lock"
POLL_INTERVAL = 0.008

def execute_code(code):
    old_stdout = sys.stdout
    old_stderr = sys.stderr
    sys.stdout = io.StringIO()
    sys.stderr = io.StringIO()
    try:
        exec(code, {'__name__': '__main__'})
        output = sys.stdout.getvalue()
        error = sys.stderr.getvalue()
        return {"status": "success", "output": output, "error": error}
    except Exception as e:
        return {"status": "error", "error": str(e), "traceback": traceback.format_exc()}
    finally:
        sys.stdout = old_stdout
        sys.stderr = old_stderr

def acquire_lock():
    try:
        lock_fd = open(LOCK_FILE, 'w')
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return lock_fd
    except:
        return None

def release_lock(lock_fd):
    if lock_fd:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
        try:
            os.remove(LOCK_FILE)
        except:
            pass

def main():
    try:
        with open(READY_FILE, "w") as f:
            f.write("ready")
        print("Agent v76.0 ready (polling 8ms, with locks)", file=sys.stderr)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
    
    while True:
        try:
            if os.path.exists(REQUEST_FILE):
                lock_fd = acquire_lock()
                if lock_fd and os.path.exists(REQUEST_FILE):
                    with open(REQUEST_FILE, "r") as f:
                        data = json.load(f)
                    
                    result = execute_code(data.get("code", ""))
                    
                    with open(RESPONSE_FILE, "w") as f:
                        json.dump(result, f)
                    
                    os.remove(REQUEST_FILE)
                    release_lock(lock_fd)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
AGENTEOF
chmod +x agent_daemon.py

# =============================================================================
# 6. AGENT COLD
# =============================================================================
cat > agent_cold.py << 'AGENTEOF'
#!/usr/bin/python3
import sys
import io
import traceback
import os

if len(sys.argv) < 2:
    print("ERREUR: pas de script")
    sys.exit(1)

SCRIPT_FILE = sys.argv[1]
RESULT_FILE = "/mnt/result.txt"
OUTPUT_FILE = "/mnt/output.txt"

print("=" * 50)
print("EXECUTION SANDBOX v76.0")
print("=" * 50)
print(f"Script: {SCRIPT_FILE}")
print("-" * 40)

try:
    with open(SCRIPT_FILE, 'r') as f:
        code = f.read()
    
    stdout_capture = io.StringIO()
    stderr_capture = io.StringIO()
    
    old_stdout = sys.stdout
    old_stderr = sys.stderr
    sys.stdout = stdout_capture
    sys.stderr = stderr_capture
    
    try:
        exec(code, {'__name__': '__main__'})
        output = stdout_capture.getvalue()
        error = stderr_capture.getvalue()
        
        if output:
            print(output, end='')
        if error:
            print(f"[STDERR]\n{error}", end='')
        
        with open(OUTPUT_FILE, 'w') as f:
            f.write(output)
        if error:
            with open(OUTPUT_FILE, 'a') as f:
                f.write("\n[STDERR]\n" + error)
        
        with open(RESULT_FILE, 'w') as f:
            f.write("SUCCESS")
        
        print("-" * 40)
        print("SUCCES")
        
    finally:
        sys.stdout = old_stdout
        sys.stderr = old_stderr
        
except Exception as e:
    print(f"ERREUR: {e}")
    traceback.print_exc()
    with open(RESULT_FILE, 'w') as f:
        f.write(f"ERROR: {str(e)}")
    with open(OUTPUT_FILE, 'w') as f:
        f.write(traceback.format_exc())

print("=" * 50)
AGENTEOF
chmod +x agent_cold.py

# =============================================================================
# 7. INIT SCRIPT
# =============================================================================
cat > initramfs/init << 'INITEOF'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "========================================="
echo "AI SANDBOX VM v76.0"
echo "========================================="

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /tmp /mnt
/bin/busybox mount -t tmpfs tmpfs /tmp

echo "[1/3] Chargement des modules..."
[ -f "/modules/netfs.ko" ] && /bin/busybox insmod "/modules/netfs.ko" 2>/dev/null
for mod in 9pnet.ko 9pnet_virtio.ko 9p.ko; do
    [ -f "/modules/$mod" ] && /bin/busybox insmod "/modules/$mod" 2>/dev/null
done

echo "[2/3] Montage 9p..."
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L m /mnt 2>/dev/null && echo " ✓ 9p monté"

if [ -f /mnt/.daemon_mode ]; then
    echo "▶ Mode démon v76.0 (polling 8ms, locks)"
    /usr/bin/python3 /agent_daemon.py 2>&1 &
    echo "VM persistante prête"
    while true; do sleep 3600; done
else
    echo "▶ Mode cold start"
    [ ! -f /mnt/user_script.py ] && /bin/busybox poweroff -f
    echo "=== DEBUT EXECUTION ==="
    /usr/bin/python3 /agent_cold.py /mnt/user_script.py 2>&1
    echo "=== FIN EXECUTION ==="
    /bin/busybox poweroff -f
fi
INITEOF
chmod 755 initramfs/init

# Copier les agents
cp agent_daemon.py agent_cold.py initramfs/

# Build
cd initramfs
find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > ../initrd.img
cd ..

SIZE=$(ls -lh initrd.img | awk '{print $5}')
ok "Initramfs construit: $SIZE"

rm -rf initramfs modules_all

# =============================================================================
# 8. VM MANAGER
# =============================================================================
cat > vm_manager.sh << 'VMEEOF'
#!/bin/sh
WORK_DIR="/root/ai_sandbox"
LOG_DIR="$WORK_DIR/logs"
VM_PID_FILE="$WORK_DIR/vm.pid"
MODE_FILE="$WORK_DIR/.daemon_mode"
READY_FILE="$WORK_DIR/agent_ready"

start_vm() {
    if [ -f "$VM_PID_FILE" ] && kill -0 $(cat "$VM_PID_FILE") 2>/dev/null; then
        echo "VM déjà en cours (PID: $(cat $VM_PID_FILE))"
        return 0
    fi
    
    pkill -f "qemu-system-x86" 2>/dev/null
    sleep 1
    
    touch "$MODE_FILE"
    rm -f "$READY_FILE" request.json response.json request.lock
    
    echo "Démarrage VM..."
    nohup qemu-system-x86_64 \
        -nographic \
        -m 1024 \
        -smp 2 \
        -kernel "$WORK_DIR/vmlinuz" \
        -initrd "$WORK_DIR/initrd.img" \
        -append "console=ttyS0" \
        -fsdev local,security_model=none,id=fsdev0,path=$WORK_DIR \
        -device virtio-9p-pci,fsdev=fsdev0,mount_tag=m \
        -no-reboot \
        > "$LOG_DIR/vm_daemon.log" 2>&1 &
    
    PID=$!
    echo $PID > "$VM_PID_FILE"
    echo "VM lancée (PID: $PID)"
    
    for i in $(seq 1 35); do
        if [ -f "$READY_FILE" ]; then
            echo "✅ Agent prêt après ${i}s"
            return 0
        fi
        sleep 0.5
    done
    
    echo "⚠️ Timeout agent"
    return 1
}

stop_vm() {
    if [ -f "$VM_PID_FILE" ]; then
        kill $(cat "$VM_PID_FILE") 2>/dev/null
        rm -f "$VM_PID_FILE"
    fi
    pkill -f "qemu-system-x86" 2>/dev/null
    rm -f "$MODE_FILE" "$READY_FILE" request.json response.json request.lock
    echo "VM arrêtée"
}

status_vm() {
    if [ -f "$VM_PID_FILE" ] && kill -0 $(cat "$VM_PID_FILE") 2>/dev/null; then
        echo "✅ VM: running (PID: $(cat $VM_PID_FILE))"
        if [ -f "$READY_FILE" ]; then
            echo "✅ Agent: ready"
        else
            echo "⚠️ Agent: not ready"
        fi
    else
        echo "❌ VM: stopped"
    fi
}

case "$1" in
    start) start_vm ;;
    stop) stop_vm ;;
    status) status_vm ;;
    restart) stop_vm; sleep 2; start_vm ;;
    *) echo "Usage: $0 {start|stop|status|restart}" ;;
esac
VMEEOF
chmod +x vm_manager.sh

# =============================================================================
# 9. BRIDGE FLASK (avec lock)
# =============================================================================
cat > bridge.py << 'BRIDGEEOF'
#!/usr/bin/env python3
import subprocess
import os
import uuid
import time
import json
import signal
import sys
import fcntl
from pathlib import Path
from flask import Flask, request, jsonify
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

WORK = Path("/root/ai_sandbox")
LOG_DIR = WORK / "logs"
MODE_FILE = WORK / ".daemon_mode"
READY_FILE = WORK / "agent_ready"
REQUEST_FILE = WORK / "request.json"
RESPONSE_FILE = WORK / "response.json"
LOCK_FILE = WORK / "request.lock"
VM_MANAGER = WORK / "vm_manager.sh"

def is_daemon_mode():
    return MODE_FILE.exists()

def acquire_lock():
    try:
        lock_fd = open(LOCK_FILE, 'w')
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return lock_fd
    except:
        return None

def release_lock(lock_fd):
    if lock_fd:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
        try:
            LOCK_FILE.unlink(missing_ok=True)
        except:
            pass

def send_to_agent_file(code, timeout=6):
    start = time.time()
    
    RESPONSE_FILE.unlink(missing_ok=True)
    
    # Acquérir lock avant d'écrire
    lock_fd = None
    while time.time() - start < timeout:
        lock_fd = acquire_lock()
        if lock_fd:
            break
        time.sleep(0.005)
    
    if not lock_fd:
        return {"status": "error", "error": "Lock timeout"}
    
    try:
        REQUEST_FILE.write_text(json.dumps({"code": code}))
    except Exception as e:
        release_lock(lock_fd)
        return {"status": "error", "error": f"Write error: {e}"}
    
    release_lock(lock_fd)
    
    # Attendre réponse
    while time.time() - start < timeout:
        if RESPONSE_FILE.exists():
            try:
                data = json.loads(RESPONSE_FILE.read_text())
                RESPONSE_FILE.unlink(missing_ok=True)
                return data
            except:
                pass
        time.sleep(0.002)
    
    # Timeout - nettoyer
    REQUEST_FILE.unlink(missing_ok=True)
    return {"status": "error", "error": "Timeout"}

def execute_cold_start(code, exec_id):
    start = time.time()
    
    (WORK / "user_script.py").write_text(code)
    for f in ["result.txt", "output.txt"]:
        (WORK / f).unlink(missing_ok=True)
    
    cmd = [
        "qemu-system-x86_64", "-nographic", "-m", "512",
        "-kernel", str(WORK / "vmlinuz"),
        "-initrd", str(WORK / "initrd.img"),
        "-append", "console=ttyS0",
        "-fsdev", f"local,security_model=none,id=fsdev0,path={WORK}",
        "-device", "virtio-9p-pci,fsdev=fsdev0,mount_tag=m",
        "-no-reboot"
    ]
    
    if os.path.exists("/dev/kvm"):
        cmd.extend(["-enable-kvm", "-cpu", "host"])
    
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    
    with open(LOG_DIR / f"qemu_cold_{exec_id}.log", 'w') as f:
        f.write(result.stdout)
    
    output = ""
    capture = False
    for line in result.stdout.splitlines():
        if "DEBUT EXECUTION" in line:
            capture = True
        elif "FIN EXECUTION" in line:
            capture = False
        elif capture:
            output += line + "\n"
    
    if not output.strip():
        out_file = WORK / "output.txt"
        if out_file.exists():
            output = out_file.read_text()
    
    res_file = WORK / "result.txt"
    success = res_file.exists() and "SUCCESS" in res_file.read_text()
    
    # Nettoyer user_script.py après exécution cold
    (WORK / "user_script.py").unlink(missing_ok=True)
    
    return {
        "success": success,
        "output": output.strip(),
        "duration": round(time.time() - start, 3)
    }

@app.route('/execute', methods=['POST'])
def execute():
    exec_id = str(uuid.uuid4())[:6]
    
    try:
        data = request.get_json()
        if not data or not data.get('code', '').strip():
            return jsonify({"success": False, "error": "Code vide"}), 400
        
        code = data.get('code')
        
        if is_daemon_mode():
            # Attendre que l'agent soit prêt
            if not READY_FILE.exists():
                # Démarrer la VM si nécessaire
                subprocess.run([str(VM_MANAGER), "start"], capture_output=True)
                # Attendre agent_ready
                for i in range(30):
                    if READY_FILE.exists():
                        break
                    time.sleep(0.5)
            
            if not READY_FILE.exists():
                return jsonify({"success": False, "error": "Agent non prêt", "mode": "daemon"}), 503
            
            start = time.time()
            result = send_to_agent_file(code)
            duration = round(time.time() - start, 3)
            
            output = result.get("output", "") or result.get("error", "")
            success = result.get("status") == "success"
            
            return jsonify({
                "success": success,
                "execution_id": exec_id,
                "output": output.strip(),
                "duration": duration,
                "mode": "daemon"
            })
        else:
            result = execute_cold_start(code, exec_id)
            return jsonify({
                **result,
                "execution_id": exec_id,
                "mode": "cold"
            })
        
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/health')
def health():
    return jsonify({
        "status": "ok",
        "mode": "daemon" if is_daemon_mode() else "cold",
        "agent_ready": READY_FILE.exists(),
        "version": "v76.0"
    })

def signal_handler(sig, frame):
    print("\nArrêt du bridge...")
    sys.exit(0)

if __name__ == '__main__':
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    mode = "daemon" if is_daemon_mode() else "cold"
    
    print("\n" + "="*50)
    print(f"AI SANDBOX BRIDGE v76.0 - Mode: {mode.upper()}")
    print("="*50)
    print(f"Polling: 8ms | Locks: OUI | Communication: 9p")
    print("="*50 + "\n")
    
    if mode == "daemon" and not READY_FILE.exists():
        subprocess.run([str(VM_MANAGER), "start"], capture_output=True)
    
    app.run(host='0.0.0.0', port=9999, debug=False, use_reloader=False)
BRIDGEEOF
chmod +x bridge.py

# =============================================================================
# 10. SCRIPTS DE COMMANDE (shell-agnostic)
# =============================================================================
for script in start stop status restart test debug; do
    cat > ${script}.sh << EOF
#!/bin/sh
cd /root/ai_sandbox
./_${script}.sh
EOF
    chmod +x ${script}.sh
done

# Scripts internes
cat > _start.sh << 'STARTEOF'
#!/bin/sh
cd /root/ai_sandbox

echo "========================================="
echo "AI SANDBOX v76.0 - Démarrage"
echo "========================================="

cleanup() {
    echo ""
    echo "Arrêt demandé (Ctrl+C)..."
    ./stop.sh
    exit 0
}
trap cleanup INT TERM

./vm_manager.sh start

echo ""
echo "Bridge API démarré sur http://localhost:9999"
echo "Appuyez sur Ctrl+C pour arrêter"
echo "========================================="
echo ""

python3 bridge.py
STARTEOF
chmod +x _start.sh

cat > _stop.sh << 'STOPEOF'
#!/bin/sh
cd /root/ai_sandbox

echo "Arrêt de AI Sandbox v76.0..."

pkill -f bridge.py 2>/dev/null && echo "✓ Bridge arrêté" || echo "ℹ Bridge non actif"
./vm_manager.sh stop

echo "✅ Tout est arrêté"
STOPEOF
chmod +x _stop.sh

cat > _status.sh << 'STATUSEOF'
#!/bin/sh
cd /root/ai_sandbox

echo "=== AI SANDBOX v76.0 Status ==="
echo ""

./vm_manager.sh status

echo ""
echo "--- Bridge ---"
if pgrep -f "bridge.py" > /dev/null; then
    echo "✅ Bridge: running (PID: $(pgrep -f bridge.py))"
else
    echo "❌ Bridge: stopped"
fi

echo ""
echo "--- Health Check ---"
curl -s http://localhost:9999/health 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "⚠️ API inaccessible"
STATUSEOF
chmod +x _status.sh

cat > _restart.sh << 'RESTARTEOF'
#!/bin/sh
cd /root/ai_sandbox
echo "Redémarrage de AI Sandbox..."
./stop.sh
sleep 2
./start.sh
RESTARTEOF
chmod +x _restart.sh

cat > _debug.sh << 'DEBUGEOF'
#!/bin/sh
cd /root/ai_sandbox

echo "=== AI SANDBOX v76.0 DEBUG ==="
echo ""

echo "--- Fichiers temporaires ---"
ls -la *.json *.pid *.ready .daemon_mode *.lock 2>/dev/null || echo "Aucun"

echo ""
echo "--- Logs VM (20 dernières lignes) ---"
tail -20 logs/vm_daemon.log 2>/dev/null || echo "Pas de logs VM"

echo ""
echo "--- Processus ---"
ps aux | grep -E "(qemu|bridge|agent)" | grep -v grep

echo ""
echo "--- Test API rapide ---"
curl -s -X POST http://localhost:9999/execute \
  -H "Content-Type: application/json" \
  -d '{"code":"print(2+2)"}' | python3 -m json.tool 2>/dev/null || echo "API non répond"

echo ""
echo "--- Fin debug ---"
DEBUGEOF
chmod +x _debug.sh

cat > _test.sh << 'TESTEOF'
#!/bin/sh
echo "=== AI Sandbox v76.0 Performance Test ==="
echo ""

for i in 1 2 3; do
    echo "Requête $i:"
    curl -s -X POST http://localhost:9999/execute \
      -H "Content-Type: application/json" \
      -d '{"code":"print(2+2)"}' | python3 -m json.tool
    echo ""
done
TESTEOF
chmod +x _test.sh

# =============================================================================
# 11. CRÉATION DES WRAPPERS GLOBAUX (shell-agnostic)
# =============================================================================
log "Création des wrappers dans /usr/local/bin..."

for cmd in start stop status restart test debug; do
    cat > /usr/local/bin/sandbox-$cmd << EOF
#!/bin/sh
cd /root/ai_sandbox && ./$cmd.sh
EOF
    chmod +x /usr/local/bin/sandbox-$cmd
done

ok "Wrappers créés: sandbox-{start,stop,status,restart,test,debug}"

# =============================================================================
# 12. FIN
# =============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ INSTALLATION v76.0 TERMINEE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "📁 Workspace: $WORK_DIR"
echo "📡 Communication: 9p polling (8ms) avec locks"
echo ""
echo "🎮 COMMANDES:"
echo "   ./start.sh           # Démarrer (Ctrl+C pour arrêter)"
echo "   ./stop.sh            # Arrêter tout"
echo "   ./status.sh          # Voir l'état"
echo "   ./restart.sh         # Redémarrer"
echo "   ./debug.sh           # Mode debug"
echo "   ./test.sh            # Tester les performances"
echo ""
echo "⚡ COMMANDES GLOBALES (fonctionnent dans tous les shells):"
echo "   sandbox-start, sandbox-stop, sandbox-status"
echo "   sandbox-restart, sandbox-test, sandbox-debug"
echo ""
echo "🧪 Test rapide: sandbox-test"
echo "📊 Health: curl http://localhost:9999/health"
echo ""
