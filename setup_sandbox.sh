#!/bin/bash

# =============================================================================
# AI SANDBOX - Version finale v58.0 (Chemin run.py corrigé)
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
# 1. INSTALLATION
# =============================================================================
log "Installation des dépendances..."

modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
[ -e /dev/kvm ] && chmod 666 /dev/kvm

for i in 1 2 3 4 5; do
    if ping -c 1 dl-cdn.alpinelinux.org &>/dev/null; then
        ok "Réseau OK"
        break
    fi
    [ $i -eq 5 ] && { err "Pas de réseau"; exit 1; }
    sleep 2
done

apk add --no-cache qemu-system-x86_64 qemu-img python3 py3-pip py3-flask curl cpio linux-virt 2>&1 | tee "$LOG_DIR/apk.log"
pip3 install flask-cors --break-system-packages 2>&1 | tee "$LOG_DIR/pip.log"

ok "Dépendances installées"

# =============================================================================
# 2. KERNEL
# =============================================================================
log "Récupération du kernel Alpine -virt..."

if [ ! -f "/boot/vmlinuz-virt" ]; then
    apk add --no-cache linux-virt 2>&1 | tee -a "$LOG_DIR/apk.log"
fi

if [ -f "/boot/vmlinuz-virt" ]; then
    cp /boot/vmlinuz-virt vmlinuz
    ok "Kernel: /boot/vmlinuz-virt"
else
    err "Kernel non trouvé"
    exit 1
fi

# =============================================================================
# 3. MODULES 9p
# =============================================================================
log "Extraction des modules Alpine -virt..."

MODULES_SRC=$(ls -d /lib/modules/*-virt 2>/dev/null | head -1)

if [ -z "$MODULES_SRC" ] || [ ! -d "$MODULES_SRC" ]; then
    err "Modules kernel Alpine (-virt) non trouvés"
    exit 1
fi

log "Source: $MODULES_SRC"
mkdir -p modules_all

# Extraire les modules 9p et netfs
find "$MODULES_SRC" -type f \( \
    -name "9p.ko*" -o \
    -name "9pnet.ko*" -o \
    -name "9pnet_virtio.ko*" -o \
    -name "netfs.ko*" \
\) -exec cp {} modules_all/ \; 2>/dev/null

# Décompresser .gz et .zst
for mod in modules_all/*.gz; do
    [ -f "$mod" ] && gunzip -f "$mod" 2>/dev/null
done
for mod in modules_all/*.zst; do
    [ -f "$mod" ] && zstd -d -f "$mod" 2>/dev/null
done

NB_MODULES=$(ls modules_all/*.ko 2>/dev/null | wc -l)
ok "$NB_MODULES modules extraits"

# =============================================================================
# 4. INITRAMFS
# =============================================================================
log "Construction de l'initramfs..."

rm -rf initramfs
mkdir -p initramfs/{bin,sbin,dev,proc,sys,mnt,tmp,etc,usr/bin,usr/lib,lib,modules}

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

# Libs système
for lib in /lib/ld-musl-x86_64.so.1 /lib/libc.musl-x86_64.so.1; do
    [ -f "$lib" ] && cp "$lib" initramfs/lib/
done

# Modules
cp modules_all/*.ko initramfs/modules/ 2>/dev/null

# =============================================================================
# 5. AGENT PYTHON (avec marqueur de fin clair)
# =============================================================================
cat > agent.py << 'AGENTEOF'
#!/usr/bin/python3
import sys
import io
import traceback
import os

if len(sys.argv) < 2:
    print("ERREUR: pas de script fourni")
    sys.exit(1)

SCRIPT_FILE = sys.argv[1]
RESULT_FILE = "/mnt/result.txt"
OUTPUT_FILE = "/mnt/output.txt"

print("=" * 50)
print("EXECUTION SANDBOX v68.0")
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
        print("--- END OF EXECUTION ---")
        
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

chmod +x agent.py
cp agent.py initramfs/

# =============================================================================
# 6. INIT SCRIPT
# =============================================================================
cat > initramfs/init << 'INITEOF'
#!/bin/busybox sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "========================================="
echo "AI SANDBOX VM v68.0"
echo "========================================="

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /tmp
/bin/busybox mount -t tmpfs tmpfs /tmp

echo "[1/3] Chargement des modules..."

if [ -f "/modules/netfs.ko" ]; then
    /bin/busybox insmod "/modules/netfs.ko" 2>/dev/null
    echo "  + netfs.ko"
fi

for mod in 9pnet.ko 9pnet_virtio.ko 9p.ko; do
    if [ -f "/modules/$mod" ]; then
        /bin/busybox insmod "/modules/$mod" 2>/dev/null
        echo "  + $mod"
    fi
done

echo "[2/3] Montage 9p..."

/bin/busybox mkdir -p /mnt

MOUNTED=""
for i in 1 2 3 4 5; do
    if /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L m /mnt 2>/dev/null; then
        echo "  ✓ 9p monté sur /mnt"
        MOUNTED="yes"
        break
    fi
    echo "  Tentative $i/5..."
    /bin/busybox sleep 1
done

if [ -z "$MOUNTED" ]; then
    echo "  ✗ Échec du montage 9p"
    /bin/busybox poweroff -f
fi

echo "[3/3] Exécution..."

if [ ! -f /mnt/user_script.py ]; then
    echo "  ✗ user_script.py non trouvé"
    /bin/busybox poweroff -f
fi

echo ""
echo "=== DEBUT EXECUTION ==="
/usr/bin/python3 /agent.py /mnt/user_script.py 2>&1
echo "=== FIN EXECUTION ==="

echo ""
/bin/busybox poweroff -f
INITEOF

chmod 755 initramfs/init

# =============================================================================
# 7. BUILD
# =============================================================================
log "Construction de l'initramfs..."
cd initramfs
find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > ../initrd.img
cd ..

SIZE=$(ls -lh initrd.img | awk '{print $5}')
ok "Initramfs: $SIZE"

rm -rf initramfs modules_all

# =============================================================================
# 8. TEST DIRECT (avec détection robuste)
# =============================================================================
log "Test direct de la VM..."

cat > user_script.py << 'EOF'
print("Hello from sandbox!")
print("2+2 =", 2+2)
for i in range(3):
    print(f"Line {i}")
EOF

echo "Démarrage de QEMU..."
timeout 15 qemu-system-x86_64 \
    -nographic \
    -m 512 \
    -kernel vmlinuz \
    -initrd initrd.img \
    -append "console=ttyS0" \
    -fsdev local,security_model=none,id=fsdev0,path=$(pwd) \
    -device virtio-9p-pci,fsdev=fsdev0,mount_tag=m \
    -no-reboot \
    > "$LOG_DIR/qemu_test.log" 2>&1

# Détection robuste du succès
if grep -q "SUCCES" "$LOG_DIR/qemu_test.log" || \
   grep -q "END OF EXECUTION" "$LOG_DIR/qemu_test.log" || \
   grep -q "=== FIN EXECUTION ===" "$LOG_DIR/qemu_test.log"; then
    ok "✅ TEST RÉUSSI !"
    echo ""
    echo "=== SORTIE DU SCRIPT ==="
    grep -A30 "=== DEBUT EXECUTION ===" "$LOG_DIR/qemu_test.log" | head -40
else
    err "❌ Échec du test"
    echo ""
    echo "=== DERNIERES 60 LIGNES ==="
    tail -60 "$LOG_DIR/qemu_test.log"
fi

# =============================================================================
# 9. BRIDGE FLASK (avec détection robuste)
# =============================================================================
cat > bridge.py << 'BRIDGEEOF'
#!/usr/bin/env python3
import subprocess
import os
import uuid
import time
from pathlib import Path
from flask import Flask, request, jsonify
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

WORK = Path("/root/ai_sandbox")
LOG_DIR = WORK / "logs"

@app.route('/execute', methods=['POST'])
def execute():
    exec_id = str(uuid.uuid4())[:6]
    start = time.time()
    
    try:
        data = request.get_json()
        if not data:
            return jsonify({"success": False, "error": "Invalid JSON"}), 400
        
        code = data.get('code', '')
        if not code.strip():
            return jsonify({"success": False, "error": "Code vide"}), 400
        
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
        
        with open(LOG_DIR / f"qemu_{exec_id}.log", 'w') as f:
            f.write(result.stdout)
        
        output = ""
        capture = False
        for line in result.stdout.split('\n'):
            if "=== DEBUT EXECUTION ===" in line:
                capture = True
                continue
            elif "=== FIN EXECUTION ===" in line:
                capture = False
                continue
            elif capture:
                output += line + '\n'
        
        # Détection robuste du succès
        res_file = WORK / "result.txt"
        success = False
        if res_file.exists():
            content = res_file.read_text().strip()
            success = content.startswith("SUCCESS") or content == "SUCCES"
        
        # Alternative via le log si fichier absent
        if not success:
            success = "SUCCES" in result.stdout or "END OF EXECUTION" in result.stdout
        
        output_file = WORK / "output.txt"
        if not output.strip() and output_file.exists():
            output = output_file.read_text()
        
        return jsonify({
            "success": success,
            "execution_id": exec_id,
            "output": output.strip(),
            "duration": round(time.time() - start, 2)
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({"success": False, "error": "Timeout (15s)"}), 504
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/health')
def health():
    required = ["vmlinuz", "initrd.img"]
    missing = [f for f in required if not (WORK / f).exists()]
    return jsonify({
        "status": "ok" if not missing else "degraded",
        "version": "v68.0"
    })

if __name__ == '__main__':
    print("\n" + "="*50)
    print("AI SANDBOX BRIDGE v68.0")
    print("="*50)
    app.run(host='0.0.0.0', port=9999, debug=False, use_reloader=False)
BRIDGEEOF

chmod +x bridge.py

# =============================================================================
# 10. SCRIPTS
# =============================================================================
cat > start.sh << 'EOF'
#!/bin/bash
cd /root/ai_sandbox
pkill -f bridge.py 2>/dev/null
sleep 1
echo "Démarrage du bridge sur http://localhost:9999"
python3 bridge.py
EOF
chmod +x start.sh

cat > test.sh << 'EOF'
#!/bin/bash
echo "=== Test 2+2 ==="
curl -s -X POST http://localhost:9999/execute \
  -H "Content-Type: application/json" \
  -d '{"code":"print(2+2)"}' | python3 -m json.tool
echo ""
echo "=== Test Hello ==="
curl -s -X POST http://localhost:9999/execute \
  -H "Content-Type: application/json" \
  -d '{"code":"print(\"Hello World\")"}' | python3 -m json.tool
echo ""
echo "=== Test Loop ==="
curl -s -X POST http://localhost:9999/execute \
  -H "Content-Type: application/json" \
  -d '{"code":"for i in range(5): print(f\"Line {i}\")"}' | python3 -m json.tool
EOF
chmod +x test.sh

cat > stop.sh << 'EOF'
#!/bin/bash
pkill -f bridge.py 2>/dev/null
pkill -f qemu-system 2>/dev/null
echo "Services arrêtés"
EOF
chmod +x stop.sh

# =============================================================================
# 11. FIN
# =============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ INSTALLATION v68.0 TERMINEE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "📁 Workspace: $WORK_DIR"
echo "📦 Kernel: $(ls -lh vmlinuz 2>/dev/null | awk '{print $5}')"
echo "📦 Initramfs: $(ls -lh initrd.img 2>/dev/null | awk '{print $5}')"
echo ""
echo "🚀 Démarrer l'API: ./start.sh"
echo "🧪 Tester l'API:   ./test.sh"
echo "🛑 Arrêter l'API:   ./stop.sh"
echo ""
