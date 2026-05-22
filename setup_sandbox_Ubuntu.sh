#!/bin/bash
# =============================================================================
# AI SANDBOX - v77.4 - Ubuntu ALPINE VM 9p
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
apt install -y qemu-system-x86 qemu-utils curl cpio busybox-static wget squashfs-tools zstd

pip3 install flask flask-cors --break-system-packages 2>/dev/null || true

ok "Dépendances installées"

# =============================================================================
# 2. TÉLÉCHARGEMENT DE L'ISO ALPINE VIRT (si non existante)
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
# 3. EXTRACTION DU KERNEL ET MODLOOP (si non existants)
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
    
    # Copier le kernel si nécessaire
    if [ ! -f "vmlinuz" ]; then
        cp "$ISO_MOUNT/boot/vmlinuz-virt" vmlinuz
        ok "Kernel: $(ls -lh vmlinuz | awk '{print $5}')"
    fi
    
    # Copier le modloop si nécessaire
    if [ ! -f "modloop-virt" ]; then
        cp "$ISO_MOUNT/boot/modloop-virt" modloop-virt
        ok "Modloop: $(ls -lh modloop-virt | awk '{print $5}')"
    fi
    
    umount "$ISO_MOUNT" 2>/dev/null || umount -l "$ISO_MOUNT" 2>/dev/null
    rmdir "$ISO_MOUNT" 2>/dev/null
else
    ok "Kernel et modloop déjà extraits"
fi

# =============================================================================
# 4. EXTRACTION DES MODULES 9P (si nécessaire)
# =============================================================================
if [ ! -d "initramfs-modules" ] || [ -z "$(ls initramfs-modules 2>/dev/null)" ]; then
    log "Extraction des modules 9p depuis modloop..."
    
    rm -rf modules_extract
    mkdir -p initramfs-modules/lib/modules modules_extract
    
    cd modules_extract
    
    MODLOOP_TYPE=$(file ../modloop-virt 2>/dev/null)
    
    if echo "$MODLOOP_TYPE" | grep -qi "squashfs"; then
        log "Modloop = SquashFS"
        unsquashfs ../modloop-virt 2>/dev/null
        if [ -d squashfs-root ]; then
            find squashfs-root -name "*.ko" -exec cp {} . \; 2>/dev/null
        fi
    elif echo "$MODLOOP_TYPE" | grep -qi "zstandard"; then
        log "Modloop = Zstandard"
        zstdcat ../modloop-virt | cpio -idm 2>/dev/null
    elif echo "$MODLOOP_TYPE" | grep -qi "gzip"; then
        log "Modloop = gzip + cpio"
        zcat ../modloop-virt | cpio -idm 2>/dev/null
    else
        log "Tentative cpio direct..."
        cpio -idm < ../modloop-virt 2>/dev/null
    fi
    
    cd ..
    
    # Copie des modules
    find modules_extract -name "9p*.ko" -exec cp {} initramfs-modules/lib/modules/ \; 2>/dev/null
    find modules_extract -name "9p*.ko.*" -exec cp {} initramfs-modules/lib/modules/ \; 2>/dev/null
    find modules_extract -name "virtio*.ko" -exec cp {} initramfs-modules/lib/modules/ \; 2>/dev/null
    find modules_extract -name "netfs.ko" -exec cp {} initramfs-modules/lib/modules/ \; 2>/dev/null
    
    NB_MODULES=$(find initramfs-modules/lib/modules -name "*.ko" 2>/dev/null | wc -l)
    ok "$NB_MODULES modules extraits"
    
    rm -rf modules_extract
else
    ok "Modules déjà extraits"
fi

# =============================================================================
# 5. CONSTRUCTION DE L'INITRAMFS AVEC TOUTES LES LIBS PYTHON
# =============================================================================
log "Construction de l'initramfs..."

rm -rf initramfs
mkdir -p initramfs/{bin,sbin,dev,proc,sys,mnt,tmp,etc,usr/bin,usr/lib,lib,lib64,modules,run,root}

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

# =============================================================================
# COPIE AUTO DE TOUTES LES LIBS NÉCESSAIRES (ldd)
# =============================================================================
log "Analyse et copie des bibliothèques..."

# Fonction: copier toutes les libs d'un binaire
copy_binary_libs() {
    local binary="$1"
    [ ! -f "$binary" ] && return
    
    ldd "$binary" 2>/dev/null | while read line; do
        # Extraire le chemin de la lib
        local libpath=$(echo "$line" | grep -o '/[^ ]*' | head -1)
        if [ -n "$libpath" ] && [ -f "$libpath" ]; then
            local dest="initramfs$libpath"
            mkdir -p "$(dirname "$dest")"
            cp -L "$libpath" "$dest" 2>/dev/null
        fi
    done
}

# Copier les libs de python3
copy_binary_libs /usr/bin/python3

# Copier les libs de libpython
LIBPYTHON=$(find /usr/lib -maxdepth 2 -name "libpython${PYVER}*.so*" 2>/dev/null | head -1)
if [ -n "$LIBPYTHON" ]; then
    log "LibPython trouvée: $LIBPYTHON"
    copy_binary_libs "$LIBPYTHON"
    cp -L "$LIBPYTHON" initramfs/usr/lib/ 2>/dev/null
fi

# Copier les libs supplémentaires courantes
for lib in /usr/lib/x86_64-linux-gnu/libz.so* \
           /usr/lib/x86_64-linux-gnu/libexpat.so* \
           /usr/lib/x86_64-linux-gnu/libssl.so* \
           /usr/lib/x86_64-linux-gnu/libcrypto.so* \
           /usr/lib/x86_64-linux-gnu/libffi.so* \
           /usr/lib/x86_64-linux-gnu/libdl.so* \
           /usr/lib/x86_64-linux-gnu/libpthread.so* \
           /usr/lib/x86_64-linux-gnu/libutil.so*; do
    [ -f "$lib" ] && cp -L "$lib" initramfs/usr/lib/ 2>/dev/null
done

# Lien ld-linux dans /lib64 (python3 l'attend là)
mkdir -p initramfs/lib64
if [ -f "initramfs/lib/ld-linux-x86-64.so.2" ]; then
    ln -sf /lib/ld-linux-x86-64.so.2 initramfs/lib64/ld-linux-x86-64.so.2 2>/dev/null
elif [ -f "initramfs/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" ]; then
    cp initramfs/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 initramfs/lib64/ 2>/dev/null
fi

# Créer ld.so.cache
mkdir -p initramfs/etc
echo "/lib" > initramfs/etc/ld.so.conf
echo "/usr/lib" >> initramfs/etc/ld.so.conf
echo "/usr/lib/x86_64-linux-gnu" >> initramfs/etc/ld.so.conf
ldconfig -r initramfs 2>/dev/null || true

# Vérification: tester python en chroot
log "Vérification Python dans l'initramfs..."
if chroot initramfs /usr/bin/python3 -c "print('Python OK')" 2>/dev/null; then
    ok "Python fonctionne dans l'initramfs"
else
    err "Python ne fonctionne pas dans l'initramfs"
    echo "Liste des libs copiées:"
    find initramfs -name "*.so*" 2>/dev/null | head -20
fi

# Modules kernel
if [ -d initramfs-modules/lib/modules ]; then
    cp -r initramfs-modules/lib/modules/* initramfs/modules/ 2>/dev/null
fi

# =============================================================================
# 6. AGENT DAEMON
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
        print("Agent v77.4 ready", file=sys.stderr)
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
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
        time.sleep(0.008)

if __name__ == "__main__":
    main()
DAEMONEOF
chmod +x agent_daemon.py

# =============================================================================
# 7. AGENT COLD
# =============================================================================
cat > agent_cold.py << 'COLDOEF'
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
print("EXECUTION SANDBOX v77.4")
print("=" * 50)
print(f"Script: {SCRIPT_FILE}")
print("-" * 40)

try:
    with open(SCRIPT_FILE, 'r') as f:
        code = f.read()
    
    old_stdout = sys.stdout
    old_stderr = sys.stderr
    sys.stdout = io.StringIO()
    sys.stderr = io.StringIO()
    
    try:
        exec(code, {'__name__': '__main__'})
        output = sys.stdout.getvalue()
        error = sys.stderr.getvalue()
        
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
COLDOEF
chmod +x agent_cold.py

# =============================================================================
# 8. INIT SCRIPT
# =============================================================================
cat > initramfs/init << 'INITEOF'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "========================================="
echo "AI SANDBOX VM v77.4"
echo "========================================="

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /tmp /mnt
/bin/busybox mount -t tmpfs tmpfs /tmp

echo "[1/3] Chargement modules..."
if [ -d /modules ]; then
    for mod in netfs 9pnet 9pnet_virtio 9p; do
        if [ -f "/modules/$mod.ko" ]; then
            /bin/busybox insmod "/modules/$mod.ko" 2>/dev/null && echo "→ $mod chargé"
        fi
    done
fi

echo "[2/3] Montage 9p..."
/bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L m /mnt 2>/dev/null && echo " ✓ 9p monté"

if [ -f /mnt/.daemon_mode ]; then
    echo "▶ Mode démon v77.4"
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

# Build initramfs
cd initramfs
find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > ../initrd.img
cd ..

SIZE=$(ls -lh initrd.img | awk '{print $5}')
ok "Initramfs construit: $SIZE"

# Ne pas supprimer initramfs pour debug possible
# rm -rf initramfs

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

case "$1" in
    start) start_vm ;;
    stop) stop_vm ;;
    *) echo "Usage: $0 {start|stop}" ;;
esac
VMMANAGER
chmod +x vm_manager.sh

# =============================================================================
# 10. BRIDGE FLASK
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

def send_to_agent_file(code, timeout=6):
    start = time.time()
    RESPONSE_FILE.unlink(missing_ok=True)
    
    lock_fd = None
    while time.time() - start < timeout:
        try:
            lock_fd = open(LOCK_FILE, 'w')
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except:
            time.sleep(0.005)
    
    if not lock_fd:
        return {"status": "error", "error": "Lock timeout"}
    
    try:
        REQUEST_FILE.write_text(json.dumps({"code": code}))
    except Exception as e:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
        return {"status": "error", "error": f"Write error: {e}"}
    
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
    
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
        
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/health')
def health():
    return jsonify({
        "status": "ok",
        "mode": "daemon" if is_daemon_mode() else "cold",
        "agent_ready": READY_FILE.exists(),
        "version": "v77.4"
    })

if __name__ == '__main__':
    mode = "daemon" if is_daemon_mode() else "cold"
    print("\n" + "="*50)
    print(f"AI SANDBOX BRIDGE v77.4 - Mode: {mode.upper()}")
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
echo "AI SANDBOX v77.4 - Démarrage"
echo "========================================="

cleanup() { echo ""; ./stop.sh; exit 0; }
trap cleanup INT TERM

./vm_manager.sh start

echo ""
echo "Bridge API sur http://localhost:9999"
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
echo "=== Test Sandbox v77.4 ==="
curl -s -X POST http://localhost:9999/execute \
  -H "Content-Type: application/json" \
  -d '{"code":"print(\"Hello Sandbox!\")"}' | python3 -m json.tool
TESTSCRIPT
chmod +x test.sh

cat > debug.sh << 'DEBUGSCRIPT'
#!/bin/bash
cd /root/ai_sandbox
echo "=== DEBUG v77.4 ==="
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
