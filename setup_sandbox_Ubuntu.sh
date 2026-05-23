#!/bin/bash
# =============================================================================
# AI SANDBOX - v78 - Ubuntu ALPINE VM 9p
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

WORK_DIR="/root/ai_sandbox"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$WORK_DIR" "$LOG_DIR"
cd "$WORK_DIR"

if [ "$(id -u)" -ne 0 ]; then
    err "Ce script doit être exécuté en root"
    exit 1
fi

# =============================================================================
# 1. DÉPENDANCES
# =============================================================================
log "Installation des dépendances..."

apt update -qq
apt install -y qemu-system-x86 qemu-utils curl cpio busybox-static wget squashfs-tools zstd nodejs npm gcc build-essential

pip3 install flask flask-cors --break-system-packages 2>/dev/null || true

ok "Dépendances installées"

# =============================================================================
# 2. TÉLÉCHARGEMENT DE L'ISO ALPINE VIRT
# =============================================================================
log "Vérification de l'ISO Alpine virt..."

ISO_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-virt-3.23.1-x86_64.iso"
ISO_FILE="alpine-virt.iso"

if [ -f "$ISO_FILE" ]; then
    ok "ISO déjà présente: $(ls -lh $ISO_FILE | awk '{print $5}')"
else
    log "Téléchargement de l'ISO..."
    wget --show-progress -O "$ISO_FILE" "$ISO_URL" 2>&1
    if [ ! -s "$ISO_FILE" ]; then
        err "Impossible de télécharger l'ISO Alpine"
        exit 1
    fi
    ok "ISO téléchargée: $(ls -lh $ISO_FILE | awk '{print $5}')"
fi

# =============================================================================
# 3. EXTRACTION DU KERNEL ET MODLOOP
# =============================================================================
log "Extraction du kernel et modloop..."

EXTRACT_NEEDED=0
[ ! -f "vmlinuz" ] && EXTRACT_NEEDED=1
[ ! -f "modloop-virt" ] && EXTRACT_NEEDED=1

if [ $EXTRACT_NEEDED -eq 1 ]; then
    ISO_MOUNT="/tmp/alpine_iso_$$"
    mkdir -p "$ISO_MOUNT"
    
    mount -o loop,ro "$ISO_FILE" "$ISO_MOUNT" 2>/dev/null
    
    if [ ! -f "$ISO_MOUNT/boot/vmlinuz-virt" ]; then
        err "Impossible de monter l'ISO"
        umount "$ISO_MOUNT" 2>/dev/null
        rmdir "$ISO_MOUNT" 2>/dev/null
        exit 1
    fi
    
    [ ! -f "vmlinuz" ] && cp "$ISO_MOUNT/boot/vmlinuz-virt" vmlinuz
    [ ! -f "modloop-virt" ] && cp "$ISO_MOUNT/boot/modloop-virt" modloop-virt
    
    umount "$ISO_MOUNT" 2>/dev/null || umount -l "$ISO_MOUNT" 2>/dev/null
    rmdir "$ISO_MOUNT" 2>/dev/null
fi

ok "Kernel: $(ls -lh vmlinuz | awk '{print $5}')"
ok "Modloop: $(ls -lh modloop-virt | awk '{print $5}')"

# =============================================================================
# 4. EXTRACTION DES MODULES
# =============================================================================
if [ ! -d "initramfs-modules" ] || [ -z "$(ls initramfs-modules 2>/dev/null)" ]; then
    log "Extraction des modules..."
    
    rm -rf modules_extract
    mkdir -p initramfs-modules/lib/modules modules_extract
    
    cd modules_extract
    
    MODLOOP_TYPE=$(file ../modloop-virt 2>/dev/null)
    
    if echo "$MODLOOP_TYPE" | grep -qi "squashfs"; then
        unsquashfs ../modloop-virt 2>/dev/null
        [ -d squashfs-root ] && find squashfs-root -name "*.ko" -exec cp {} . \;
    elif echo "$MODLOOP_TYPE" | grep -qi "zstandard"; then
        zstdcat ../modloop-virt | cpio -idm 2>/dev/null
    else
        zcat ../modloop-virt | cpio -idm 2>/dev/null
    fi
    
    cd ..
    
    find modules_extract -name "9p*.ko" -exec cp {} initramfs-modules/lib/modules/ \; 2>/dev/null
    find modules_extract -name "virtio*.ko" -exec cp {} initramfs-modules/lib/modules/ \; 2>/dev/null
    find modules_extract -name "netfs.ko" -exec cp {} initramfs-modules/lib/modules/ \; 2>/dev/null
    
    NB_MODULES=$(find initramfs-modules/lib/modules -name "*.ko" 2>/dev/null | wc -l)
    ok "$NB_MODULES modules extraits"
    
    rm -rf modules_extract
fi

# =============================================================================
# 5. CRÉATION DU DISQUE PERSISTANT
# =============================================================================
if [ ! -f "disk.qcow2" ]; then
    log "Création du disque persistant (2GB)..."
    qemu-img create -f qcow2 disk.qcow2 2G
    ok "Disque créé: disk.qcow2"
fi

# =============================================================================
# 6. CONSTRUCTION DE L'INITRAMFS
# =============================================================================
log "Construction de l'initramfs..."

rm -rf initramfs
mkdir -p initramfs/{bin,sbin,dev,proc,sys,mnt,tmp,etc,usr/bin,usr/lib,lib,lib64,modules,run,root,var}

# Busybox
cp $(which busybox) initramfs/bin/busybox
chmod 755 initramfs/bin/busybox

cd initramfs/bin
for cmd in $(./busybox --list 2>/dev/null); do
    ln -sf busybox $cmd 2>/dev/null
done
cd ../..
ok "Busybox configuré"

# Python
cp /usr/bin/python3 initramfs/usr/bin/python3
chmod 755 initramfs/usr/bin/python3

PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
if [ -d "/usr/lib/python$PYVER" ]; then
    cp -r "/usr/lib/python$PYVER" initramfs/usr/lib/ 2>/dev/null
fi

# Node.js
if [ -f /usr/bin/node ]; then
    cp /usr/bin/node initramfs/usr/bin/
    cp /usr/bin/npm initramfs/usr/bin/ 2>/dev/null
fi

# GCC et outils de compilation
if [ -f /usr/bin/gcc ]; then
    mkdir -p initramfs/usr/bin initramfs/usr/lib/gcc
    cp /usr/bin/gcc initramfs/usr/bin/
    cp /usr/bin/g++ initramfs/usr/bin/ 2>/dev/null
    cp -r /usr/lib/gcc/x86_64-linux-gnu/* initramfs/usr/lib/gcc/ 2>/dev/null
fi

# =============================================================================
# COPIE AUTO DE TOUTES LES LIBS NÉCESSAIRES
# =============================================================================
log "Analyse et copie des bibliothèques..."

copy_binary_libs() {
    local binary="$1"
    [ ! -f "$binary" ] && return
    
    ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | while read lib; do
        if [ -f "$lib" ]; then
            local dest="initramfs$lib"
            mkdir -p "$(dirname "$dest")"
            cp -L "$lib" "$dest" 2>/dev/null
        fi
    done
}

for bin in /usr/bin/python3 /usr/bin/node /usr/bin/gcc; do
    [ -f "$bin" ] && copy_binary_libs "$bin"
done

LIBPYTHON=$(find /usr/lib -maxdepth 2 -name "libpython${PYVER}*.so*" 2>/dev/null | head -1)
if [ -n "$LIBPYTHON" ]; then
    copy_binary_libs "$LIBPYTHON"
    cp -L "$LIBPYTHON" initramfs/usr/lib/ 2>/dev/null
fi

# Fichiers de configuration
mkdir -p initramfs/etc
echo "nameserver 8.8.8.8" > initramfs/etc/resolv.conf
echo "nameserver 1.1.1.1" >> initramfs/etc/resolv.conf

cat > initramfs/etc/passwd << 'PASSWD'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/:/sbin/nologin
PASSWD

cat > initramfs/etc/group << 'GROUP'
root:x:0:
nobody:x:65534:
GROUP

# Modules kernel
if [ -d initramfs-modules/lib/modules ]; then
    cp -r initramfs-modules/lib/modules/* initramfs/modules/ 2>/dev/null
fi

# =============================================================================
# 7. AGENT DAEMON
# =============================================================================
cat > agent_daemon.py << 'DAEMONEOF'
#!/usr/bin/python3
import json
import sys
import io
import traceback
import time
import os
import fcntl
import subprocess

REQUEST_FILE = "/mnt/request.json"
RESPONSE_FILE = "/mnt/response.json"
READY_FILE = "/mnt/agent_ready"
LOCK_FILE = "/mnt/request.lock"

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

def main():
    try:
        with open(READY_FILE, "w") as f:
            f.write("ready")
        print("Agent v78.0 ready", file=sys.stderr)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
    
    while True:
        try:
            if os.path.exists(REQUEST_FILE):
                lock_fd = open(LOCK_FILE, 'w')
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if os.path.exists(REQUEST_FILE):
                    with open(REQUEST_FILE, "r") as f:
                        data = json.load(f)
                    result = execute_code(data.get("code", ""))
                    with open(RESPONSE_FILE, "w") as f:
                        json.dump(result, f)
                    os.remove(REQUEST_FILE)
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
                lock_fd.close()
                try:
                    os.remove(LOCK_FILE)
                except:
                    pass
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
        time.sleep(0.008)

if __name__ == "__main__":
    main()
DAEMONEOF
chmod +x agent_daemon.py

# =============================================================================
# 8. INIT SCRIPT
# =============================================================================
cat > initramfs/init << 'INITEOF'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "========================================="
echo "AI SANDBOX VM v78.0"
echo "========================================="

# Mount de base
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /tmp /mnt
/bin/busybox mount -t tmpfs tmpfs /tmp

echo "[1/4] Chargement modules..."
if [ -d /modules ]; then
    for mod in netfs 9pnet 9pnet_virtio 9p virtio virtio_pci virtio_ring; do
        if [ -f "/modules/$mod.ko" ]; then
            /bin/busybox insmod "/modules/$mod.ko" 2>/dev/null && echo "→ $mod"
        fi
    done
fi

echo "[2/4] Montage 9p..."
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L m /mnt 2>/dev/null && echo " ✓ 9p monté"

echo "[3/4] Configuration réseau..."
if [ -d /sys/class/net ]; then
    for iface in $(ls /sys/class/net); do
        case "$iface" in
            lo|sit*|tun*|docker*) continue ;;
            *)
                /bin/busybox ip link set "$iface" up 2>/dev/null
                /bin/busybox udhcpc -i "$iface" -q 2>/dev/null &
                ;;
        esac
    done
fi

echo "[4/4] Mode de fonctionnement..."
if [ -f "/mnt/.daemon_mode" ]; then
    echo "▶ MODE DAEMON v78.0"
    /usr/bin/python3 /agent_daemon.py 2>&1 &
    echo "VM persistante prête"
    while true; do sleep 3600; done
else
    echo "▶ MODE COLD START"
    if [ -f "/mnt/user_script.py" ]; then
        /usr/bin/python3 /agent_cold.py /mnt/user_script.py 2>&1
    fi
    poweroff -f
fi
INITEOF
chmod 755 initramfs/init

cp agent_daemon.py initramfs/

# Build initramfs
cd initramfs
find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > ../initrd.img
cd ..

SIZE=$(ls -lh initrd.img | awk '{print $5}')
ok "Initramfs construit: $SIZE"

# =============================================================================
# 9. VM MANAGER
# =============================================================================
cat > vm_manager.sh << 'VMMANAGER'
#!/bin/bash
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
    
    echo "daemon" > "$MODE_FILE"
    rm -f "$READY_FILE" request.json response.json request.lock
    
    echo "Démarrage VM v78.0..."
    
    nohup qemu-system-x86_64 \
        -nographic \
        -m 2048 \
        -smp 2 \
        -kernel "$WORK_DIR/vmlinuz" \
        -initrd "$WORK_DIR/initrd.img" \
        -append "console=ttyS0" \
        -fsdev local,security_model=none,id=fsdev0,path=$WORK_DIR \
        -device virtio-9p-pci,fsdev=fsdev0,mount_tag=m \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0 \
        -drive file=$WORK_DIR/disk.qcow2,format=qcow2,if=virtio \
        -no-reboot \
        > "$LOG_DIR/vm_daemon.log" 2>&1 &
    
    PID=$!
    echo $PID > "$VM_PID_FILE"
    echo "VM lancée (PID: $PID)"
    
    for i in $(seq 1 45); do
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

case "$1" in
    start) start_vm ;;
    stop) stop_vm ;;
    *) echo "Usage: $0 {start|stop}" ;;
esac
VMMANAGER
chmod +x vm_manager.sh

# =============================================================================
# 10. BRIDGE FLASK (avec locks corrigés)
# =============================================================================
cat > bridge.py << 'BRIDGEPY'
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

def send_to_agent_file(code, timeout=8):
    start = time.time()
    RESPONSE_FILE.unlink(missing_ok=True)
    
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
    
    while time.time() - start < timeout:
        if RESPONSE_FILE.exists():
            try:
                data = json.loads(RESPONSE_FILE.read_text())
                RESPONSE_FILE.unlink(missing_ok=True)
                return data
            except:
                pass
        time.sleep(0.002)
    
    REQUEST_FILE.unlink(missing_ok=True)
    return {"status": "error", "error": "Timeout"}

@app.route('/execute', methods=['POST'])
def execute():
    exec_id = str(uuid.uuid4())[:6]
    
    try:
        data = request.get_json()
        if not data or not data.get('code', '').strip():
            return jsonify({"success": False, "error": "Code vide"}), 400
        
        code = data.get('code')
        
        if not READY_FILE.exists():
            subprocess.run([str(VM_MANAGER), "start"], capture_output=True)
            for i in range(40):
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
        
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/health')
def health():
    return jsonify({
        "status": "ok",
        "mode": "daemon" if is_daemon_mode() else "cold",
        "agent_ready": READY_FILE.exists(),
        "version": "v78.0"
    })

def signal_handler(sig, frame):
    print("\nArrêt du bridge...")
    sys.exit(0)

if __name__ == '__main__':
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    mode = "daemon" if is_daemon_mode() else "cold"
    print("\n" + "="*50)
    print(f"AI SANDBOX BRIDGE v78.0 - Mode: {mode.upper()}")
    print("="*50 + "\n")
    app.run(host='0.0.0.0', port=9999, debug=False)
BRIDGEPY
chmod +x bridge.py

# =============================================================================
# 11. SCRIPTS DE COMMANDE
# =============================================================================
cat > start.sh << 'STARTSCRIPT'
#!/bin/bash
cd /root/ai_sandbox
echo "========================================="
echo "AI SANDBOX v78.0 - Démarrage"
echo "========================================="
cleanup() { echo ""; ./stop.sh; exit 0; }
trap cleanup INT TERM
./vm_manager.sh start
echo ""
echo "Bridge API sur http://localhost:9999"
echo "SSH: ssh -p 2222 root@localhost (si configuré)"
echo "Ctrl+C pour arrêter"
echo ""
python3 bridge.py
STARTSCRIPT
chmod +x start.sh

cat > stop.sh << 'STOPSCRIPT'
#!/bin/bash
cd /root/ai_sandbox
pkill -f "python3 bridge.py" 2>/dev/null
./vm_manager.sh stop
echo "✅ Arrêté"
STOPSCRIPT
chmod +x stop.sh

cat > test.sh << 'TESTSCRIPT'
#!/bin/bash
echo "=== Test Sandbox v78.0 ==="
curl -s -X POST http://localhost:9999/execute \
  -H "Content-Type: application/json" \
  -d '{"code":"print(\"Hello Sandbox!\")"}' | python3 -m json.tool
TESTSCRIPT
chmod +x test.sh

cat > debug.sh << 'DEBUGSCRIPT'
#!/bin/bash
cd /root/ai_sandbox
echo "=== DEBUG v78.0 ==="
echo "agent_ready: $(cat agent_ready 2>/dev/null || echo 'NON')"
echo ".daemon_mode: $(cat .daemon_mode 2>/dev/null || echo 'NON')"
echo ""
echo "--- Log VM ---"
tail -30 logs/vm_daemon.log 2>/dev/null
echo ""
echo "--- Processus ---"
ps aux | grep -E "qemu|bridge" | grep -v grep
DEBUGSCRIPT
chmod +x debug.sh

# =============================================================================
# 12. WRAPPERS
# =============================================================================
for cmd in start stop test debug; do
    cat > /usr/local/bin/sandbox-$cmd << EOF
#!/bin/bash
cd /root/ai_sandbox && ./$cmd.sh
EOF
    chmod +x /usr/local/bin/sandbox-$cmd
done

# =============================================================================
# FIN
# =============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ INSTALLATION TERMINEE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "COMMANDES:"
echo "   sandbox-start   # Démarrer"
echo "   sandbox-stop    # Arrêter"
echo "   sandbox-test    # Tester"
echo "   sandbox-debug   # Debug"
echo ""
echo "📡 SSH: ssh -p 2222 root@localhost (si configuré dans la VM)"
echo "💾 Disque persistant: disk.qcow2"
echo "🐍 Python, Node.js, GCC disponibles dans la VM"
echo ""
