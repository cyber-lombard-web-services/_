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
KERNEL_VERSION="6.18.31-0-virt"
MODULES_SRC="/lib/modules/$KERNEL_VERSION"

mkdir -p "$WORK_DIR" "$LOG_DIR"
cd "$WORK_DIR"

if [ "$(id -u)" -ne 0 ]; then
    err "Ce script doit être exécuté en root"
    exit 1
fi

# =============================================================================
# 1. VÉRIFICATION RÉSEAU
# =============================================================================
log "Vérification du réseau..."
for i in 1 2 3; do
    if ping -c 1 dl-cdn.alpinelinux.org &>/dev/null; then
        ok "Réseau OK"
        break
    fi
    [ $i -eq 3 ] && { err "Pas de réseau"; exit 1; }
    sleep 2
done

# =============================================================================
# 2. INSTALLATION DES PAQUETS
# =============================================================================
log "Installation des paquets..."

modprobe loop 2>/dev/null || true
modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
[ -e /dev/kvm ] && chmod 666 /dev/kvm

apk add --no-cache \
    python3 py3-pip py3-flask \
    qemu-system-x86_64 qemu-img \
    curl cpio xorriso wget squashfs-tools 2>&1 | tee "$LOG_DIR/apk.log"

pip3 install flask-cors --break-system-packages 2>&1 | tee "$LOG_DIR/pip.log"

ok "Paquets installés"

# =============================================================================
# 3. RÉCUPÉRATION DU KERNEL LOCAL
# =============================================================================
log "Récupération du kernel local..."

if [ -f "/boot/vmlinuz-virt" ]; then
    cp /boot/vmlinuz-virt vmlinuz
    ok "Kernel copié depuis /boot/vmlinuz-virt"
elif [ -f "/boot/vmlinuz-lts" ]; then
    cp /boot/vmlinuz-lts vmlinuz
    ok "Kernel copié depuis /boot/vmlinuz-lts"
else
    err "Aucun kernel trouvé dans /boot/"
    exit 1
fi

ok "Kernel: $(ls -lh vmlinuz | awk '{print $5}')"

# =============================================================================
# 4. EXTRACTION DES MODULES
# =============================================================================
log "Extraction des modules 9p..."

mkdir -p modules_all

find "$MODULES_SRC" -type f \( \
    -name "9p.ko*" -o \
    -name "9pnet*.ko*" -o \
    -name "virtio*.ko*" -o \
    -name "netfs.ko*" \
\) -exec cp {} modules_all/ \; 2>/dev/null

for mod in modules_all/*.gz; do
    [ -f "$mod" ] && gunzip -f "$mod" 2>/dev/null
done

NB_MODULES=$(ls modules_all/*.ko 2>/dev/null | wc -l)
ok "$NB_MODULES modules extraits"

# =============================================================================
# 5. CRÉATION DE L'INITRAMFS
# =============================================================================
log "Construction de l'initramfs..."

rm -rf initramfs
mkdir -p initramfs/{bin,sbin,dev,proc,sys,mnt,etc,usr/bin,usr/lib,lib,modules}

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
for lib in /lib/ld-musl-x86_64.so.1 /lib/libc.musl-x86_64.so.1 /lib/libresolv.so.2; do
    [ -f "$lib" ] && cp "$lib" initramfs/lib/
done

# Modules
cp modules_all/*.ko initramfs/modules/ 2>/dev/null

# =============================================================================
# 6. SCRIPT INIT (avec run.py à la racine)
# =============================================================================
cat > initramfs/init << 'EOF'
#!/bin/busybox sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "========================================="
echo "AI SANDBOX v58.0"
echo "========================================="

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev

echo "[1/4] Chargement des modules..."
for mod in /modules/virtio.ko /modules/virtio_ring.ko; do
    [ -f "$mod" ] && /bin/busybox insmod "$mod" 2>/dev/null
done
[ -f /modules/netfs.ko ] && /bin/busybox insmod /modules/netfs.ko 2>/dev/null
[ -f /modules/9pnet.ko ] && /bin/busybox insmod /modules/9pnet.ko 2>/dev/null
[ -f /modules/9pnet_virtio.ko ] && /bin/busybox insmod /modules/9pnet_virtio.ko 2>/dev/null
[ -f /modules/9p.ko ] && /bin/busybox insmod /modules/9p.ko 2>/dev/null

echo "[2/4] Modules chargés:"
/bin/busybox lsmod | head -8

echo "[3/4] Montage 9p..."
/bin/busybox mkdir -p /mnt

for i in 1 2 3; do
    if /bin/busybox mount -t 9p -o trans=virtio,version=9p2000.L m /mnt 2>/dev/null; then
        echo "  ✓ 9p monté"
        MOUNTED=1
        break
    fi
    /bin/busybox sleep 1
done

echo "[4/4] Exécution..."
if [ "$MOUNTED" = "1" ] && [ -f /mnt/user_script.py ]; then
    echo ""
    echo "=== DEBUT EXECUTION ==="
    /usr/bin/python3 /run.py /mnt/user_script.py 2>&1
    echo "=== FIN EXECUTION ==="
else
    echo "  ✗ Échec montage ou script absent"
fi

echo ""
/bin/busybox poweroff -f
EOF

chmod 755 initramfs/init

# =============================================================================
# 7. SCRIPT D'EXÉCUTION PYTHON (à la racine de l'initramfs)
# =============================================================================
cat > initramfs/run.py << 'EOF'
#!/usr/bin/python3
import sys, os

if len(sys.argv) < 2:
    print("Usage: run.py <script_file>")
    sys.exit(1)

SCRIPT = sys.argv[1]
RESULT = "/mnt/result.txt"

print("=" * 50)
print("EXECUTION SANDBOX")
print("=" * 50)
print(f"Python: {sys.version}")
print(f"Script: {SCRIPT}")
print("-" * 40)

try:
    with open(SCRIPT, 'r') as f:
        code = f.read()
    
    exec(code, {'__name__': '__main__'})
    
    with open(RESULT, 'w') as f:
        f.write("SUCCESS")
    
    print("SUCCESS")
    
except Exception as e:
    import traceback
    traceback.print_exc()
    with open(RESULT, 'w') as f:
        f.write(f"ERROR: {str(e)}")
    sys.exit(1)

print("=" * 50)
EOF

chmod 755 initramfs/run.py

# =============================================================================
# 8. CONSTRUCTION FINALE
# =============================================================================
log "Construction de l'initramfs..."
cd initramfs
find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > ../initrd.img
cd ..

SIZE=$(ls -lh initrd.img | awk '{print $5}')
ok "Initramfs construit: $SIZE"

# Nettoyage
rm -rf initramfs modules_all

# =============================================================================
# 9. TEST
# =============================================================================
log "Test avec QEMU..."

cat > user_script.py << 'EOF'
print("Hello from sandbox!")
print("2+2 =", 2+2)
for i in range(3):
    print(f"Line {i}")
EOF

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

if grep -q "SUCCESS" "$LOG_DIR/qemu_test.log"; then
    ok "✅ TEST RÉUSSI !"
    grep -A10 "=== DEBUT EXECUTION ===" "$LOG_DIR/qemu_test.log"
else
    err "❌ Échec"
    echo ""
    tail -30 "$LOG_DIR/qemu_test.log"
fi

# =============================================================================
# 10. BRIDGE
# =============================================================================
log "Création du bridge..."

cat > bridge.py << 'EOF'
#!/usr/bin/env python3
import subprocess, os, uuid, time
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
        code = request.get_json().get('code', '')
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
            elif "=== FIN EXECUTION ===" in line:
                capture = False
            elif capture:
                output += line + '\n'
        
        res_file = WORK / "result.txt"
        success = res_file.exists() and "SUCCESS" in res_file.read_text()
        
        return jsonify({
            "success": success,
            "execution_id": exec_id,
            "output": output.strip(),
            "duration": round(time.time() - start, 2)
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({"success": False, "error": "Timeout"}), 504
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route('/health')
def health():
    return jsonify({"status": "ok"})

if __name__ == '__main__':
    print("\n" + "="*50)
    print("AI SANDBOX BRIDGE v58.0")
    print("="*50)
    app.run(host='0.0.0.0', port=9999, debug=False, use_reloader=False)
EOF

chmod +x bridge.py

# =============================================================================
# 11. SCRIPTS
# =============================================================================
cat > start.sh << 'EOF'
#!/bin/bash
cd /root/ai_sandbox
pkill -f bridge.py 2>/dev/null
python3 bridge.py
EOF
chmod +x start.sh

cat > test.sh << 'EOF'
#!/bin/bash
curl -s -X POST http://localhost:9999/execute \
  -H "Content-Type: application/json" \
  -d '{"code":"print(2+2)"}' | python3 -m json.tool
EOF
chmod +x test.sh

# =============================================================================
# FIN
# =============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ INSTALLATION v58.0 TERMINEE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "🚀 Démarrer: cd $WORK_DIR && ./start.sh"
echo "🧪 Tester:   cd $WORK_DIR && ./test.sh"
echo ""
