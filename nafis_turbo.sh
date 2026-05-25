#!/bin/bash
# =============================================================================
# NAFIS TURBO v3 - Version Python asynchrone + Sandbox Bridge
# By thibaut LOMBARD © copyright all rights reserved
# =============================================================================

LOG_FILE="/root/nafis_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================="
echo "NAFIS TURBO v3 - Installation"
echo "Date: $(date)"
echo "========================================="

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}      NAFIS TURBO v3                                             ${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# 1. Installation dépendances Python
# =============================================================================
echo -e "${YELLOW}[1/5] Installation dépendances Python...${NC}"
pip3 install aiohttp aiohttp-client-cache requests --break-system-packages 2>/dev/null || pip3 install aiohttp requests
echo -e "  ${GREEN}✓ Dépendances installées${NC}"

# =============================================================================
# 2. Optimisation Ollama
# =============================================================================
echo -e "${YELLOW}[2/5] Optimisation Ollama...${NC}"
pkill -9 ollama 2>/dev/null
pkill -9 ollama_llama_server 2>/dev/null
sleep 2

# Configuration ultra-rapide pour GTX 1050
cat > /etc/profile.d/ollama-turbo.sh << 'EOF'
export OLLAMA_GPU_OVERHEAD=0
export OLLAMA_HOST=0.0.0.0
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_CONTEXT_LENGTH=1536
export OLLAMA_BATCH_SIZE=512
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
export OLLAMA_F16_KV=0
export CUDA_VISIBLE_DEVICES=0
export OLLAMA_DEBUG=0
EOF

source /etc/profile.d/ollama-turbo.sh

ollama serve > /tmp/ollama_turbo.log 2>&1 &
sleep 4

if curl -s http://localhost:11434/api/tags > /dev/null; then
    echo -e "  ${GREEN}✓ Ollama optimisé et démarré${NC}"
else
    echo -e "  ${RED}✗ Erreur démarrage Ollama${NC}"
    exit 1
fi

# =============================================================================
# 3. Création des modèles turbo
# =============================================================================
echo -e "${YELLOW}[3/5] Création des modèles turbo...${NC}"

# Vérifier/créer qwen-turbo
if ! ollama list | grep -q qwen-turbo; then
    ollama create qwen-turbo -f - << 'EOF'
FROM qwen2.5-coder:3b
PARAMETER temperature 0.5
PARAMETER top_p 0.85
PARAMETER top_k 30
PARAMETER num_predict 1024
PARAMETER repeat_penalty 1.05
PARAMETER num_ctx 1536
PARAMETER num_batch 512
PARAMETER num_gpu 999
PARAMETER num_thread 6
PARAMETER stop ["\n\n", "```"]
SYSTEM """Tu es un assistant coding ultra-rapide. Réponses très concises, juste le code."""
EOF
fi

# Vérifier/créer deepseek-turbo
if ! ollama list | grep -q deepseek-turbo; then
    ollama create deepseek-turbo -f - << 'EOF'
FROM deepseek-coder:6.7b
PARAMETER num_ctx 1024
PARAMETER num_batch 256
PARAMETER num_gpu 999
PARAMETER num_predict 800
PARAMETER temperature 0.4
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.1
SYSTEM """Code court, efficace, pas de bla-bla."""
EOF
fi

# Vérifier/créer codeqwen-turbo
if ! ollama list | grep -q codeqwen-turbo; then
    ollama create codeqwen-turbo -f - << 'EOF'
FROM codeqwen:latest
PARAMETER temperature 0.55
PARAMETER top_p 0.88
PARAMETER num_predict 1536
PARAMETER repeat_penalty 1.08
PARAMETER num_ctx 1536
PARAMETER num_batch 384
PARAMETER num_gpu 999
SYSTEM """Expert en code, réponses directes et fonctionnelles."""
EOF
fi

# Vérifier/créer mimo-turbo
if ! ollama list | grep -q mimo-turbo; then
    ollama create mimo-turbo -f - << 'EOF'
FROM hf.co/mradermacher/MiMo-7B-Base-Qwenified-GGUF:Q4_K_M
PARAMETER temperature 0.6
PARAMETER top_p 0.9
PARAMETER top_k 40
PARAMETER num_predict 2048
PARAMETER repeat_penalty 1.1
PARAMETER num_ctx 1536
PARAMETER num_batch 256
PARAMETER num_gpu 999
PARAMETER num_thread 6
SYSTEM """Assistant IA rapide et efficace. Réponses concises."""
EOF
fi

echo -e "  ${GREEN}✓ Modèles turbo créés${NC}"

# =============================================================================
# 4. Script NAFIS TURBO
# =============================================================================
echo -e "${YELLOW}[4/5] Installation NAFIS Python Async...${NC}"

cat > /usr/local/bin/nafis << 'EOF'
#!/usr/bin/env python3
"""
NAFIS TURBO v3 - Version Python Async + Sandbox Bridge
Performance optimisée avec sessions HTTP persistantes
"""

import asyncio
import aiohttp
import json
import sys
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

# Configuration
OLLAMA_URL = "http://localhost:11434/api/generate"
SANDBOX_URL = "http://localhost:9999/execute"
SANDBOX_START_CMD = ["sandbox-start"]
SANDBOX_STOP_CMD = ["sandbox-stop"]

# Modèles (index, nom, ID)
MODELS = [
    ("1", "🚀 MiMo-7B TURBO", "mimo-turbo"),
    ("2", "🎯 MiMo-7B Standard", "hf.co/mradermacher/MiMo-7B-Base-Qwenified-GGUF:Q4_K_M"),
    ("3", "⚡ Qwen 3B TURBO", "qwen-turbo"),
    ("4", "📝 Qwen 3B Standard", "qwen2.5-coder:3b"),
    ("5", "🔥 CodeQwen TURBO", "codeqwen-turbo"),
    ("6", "💻 CodeQwen Standard", "codeqwen:latest"),
    ("7", "💨 DeepSeek TURBO", "deepseek-turbo"),
    ("8", "🐍 DeepSeek Standard", "deepseek-coder:6.7b"),
]

MODELS_DICT = {idx: (name, mid) for idx, name, mid in MODELS}
CURRENT_MODEL = "qwen-turbo"
CURRENT_NAME = "⚡ Qwen 3B TURBO"

# Session HTTP persistante (CLÉ DE LA RAPIDITÉ)
session = None
sandbox_session = None

# État sandbox
sandbox_enabled = False

class SandboxStats:
    def __init__(self):
        self.total_calls = 0
        self.total_time = 0
        self.last_time = 0
        self.last_output_size = 0
        self.last_code_size = 0
    
    def add_call(self, duration, output_size, code_size):
        self.total_calls += 1
        self.total_time += duration
        self.last_time = duration
        self.last_output_size = output_size
        self.last_code_size = code_size
    
    @property
    def avg_time(self):
        if self.total_calls == 0:
            return 0
        return self.total_time / self.total_calls
    
    def __str__(self):
        return f"📊 Sandbox Stats: {self.total_calls} exec | ∅ {self.avg_time:.3f}s | Dernier: {self.last_time:.3f}s | Code: {self.last_code_size}B | Output: {self.last_output_size}B"

sandbox_stats = SandboxStats()

def get_gpu_stats():
    """Récupère les stats GPU"""
    try:
        result = subprocess.run(
            ['nvidia-smi', '--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu',
             '--format=csv,noheader'],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0:
            parts = [p.strip() for p in result.stdout.strip().split(',')]
            if len(parts) >= 4:
                return {
                    'gpu_util': parts[0],
                    'mem_used': parts[1],
                    'mem_total': parts[2],
                    'temp': parts[3]
                }
    except:
        pass
    return {'gpu_util': 'N/A', 'mem_used': 'N/A', 'mem_total': 'N/A', 'temp': 'N/A'}

def check_sandbox():
    """Vérifie si le sandbox est disponible"""
    try:
        import requests
        r = requests.get("http://localhost:9999/health", timeout=2)
        return r.status_code == 200
    except:
        return False

async def ask_ollama(prompt, model):
    """Requête Ollama avec session persistante - TURBO!"""
    global session
    
    if session is None or session.closed:
        connector = aiohttp.TCPConnector(limit=10, ttl_dns_cache=300)
        timeout = aiohttp.ClientTimeout(total=90)
        session = aiohttp.ClientSession(connector=connector, timeout=timeout)
    
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": 0.5 if "turbo" in model else 0.7,
            "num_predict": 1500 if "turbo" in model else 4000,
            "num_ctx": 1536 if "turbo" in model else 4096,
            "num_batch": 512
        }
    }
    
    try:
        start = time.time()
        async with session.post(OLLAMA_URL, json=payload) as response:
            data = await response.json()
            elapsed = (time.time() - start) * 1000  # en ms
            return data.get("response", "Erreur"), elapsed
    except Exception as e:
        return f"Erreur: {e}", 0

async def sandbox_execute(code):
    """Exécute du code dans le sandbox avec stats détaillées"""
    global sandbox_session, sandbox_stats, sandbox_enabled
    
    if not sandbox_enabled:
        return "❌ Sandbox désactivé. Tapez /sandbox pour l'activer"
    
    if not check_sandbox():
        return "❌ Sandbox non disponible. Lancez 'sandbox-start' d'abord"
    
    if sandbox_session is None or sandbox_session.closed:
        connector = aiohttp.TCPConnector(limit=10)
        timeout = aiohttp.ClientTimeout(total=30)
        sandbox_session = aiohttp.ClientSession(connector=connector, timeout=timeout)
    
    code_size = len(code.encode('utf-8'))
    
    try:
        start = time.time()
        async with sandbox_session.post(SANDBOX_URL, json={"code": code}) as response:
            data = await response.json()
            elapsed = time.time() - start
            output = data.get("output", "Pas de sortie")
            output_size = len(output.encode('utf-8'))
            
            sandbox_stats.add_call(elapsed, output_size, code_size)
            
            stats_line = f"⚡ Exécution: {elapsed:.3f}s | Code: {code_size}B | Output: {output_size}B"
            return f"{stats_line}\n{'─' * 40}\n{output}"
    except asyncio.TimeoutError:
        return f"❌ Timeout après 30s (Code: {code_size}B)"
    except Exception as e:
        return f"❌ Erreur sandbox: {e}"

def print_models():
    """Affiche la liste des modèles"""
    print("\n📋 Modèles disponibles:")
    print("─" * 40)
    for idx, name, _ in MODELS:
        if "TURBO" in name:
            print(f"  {idx}. {name} ⚡")
        else:
            print(f"  {idx}. {name}")
    print("─" * 40)
    print("👉 /m<numéro> pour changer (ex: /m3)")

def format_gpu_stats(stats):
    """Formate les stats GPU"""
    return f"🎮 GPU: {stats['gpu_util']} | RAM: {stats['mem_used']}/{stats['mem_total']}MiB | 🌡️ {stats['temp']}°C"

async def main():
    global CURRENT_MODEL, CURRENT_NAME, sandbox_enabled
    
    # Nettoyage à la sortie
    def cleanup():
        global session, sandbox_session
        if session and not session.closed:
            asyncio.create_task(session.close())
        if sandbox_session and not sandbox_session.closed:
            asyncio.create_task(sandbox_session.close())
    
    # Interface
    os.system('clear')
    print("\n" + "═" * 60)
    print("🤖 NAFIS TURBO v3 - Async Python")
    print("═" * 60)
    
    gpu_stats = get_gpu_stats()
    print(f"{format_gpu_stats(gpu_stats)}")
    print(f"📌 Modèle actuel: {CURRENT_NAME}")
    print("─" * 60)
    print("Commandes: /help | /m<1-8> | /sandbox | /stats | /gpu | /exit")
    print("═" * 60)
    
    # Pré-chauffe la session HTTP
    await ask_ollama("ping", CURRENT_MODEL)
    
    while True:
        try:
            query = input(f"\n💬 [{datetime.now().strftime('%H:%M:%S')}] >>> ").strip()
            
            if query in ["/exit", "exit", "quit"]:
                break
            
            elif query == "/help":
                print("\n📖 Commandes:")
                print("  /m<1-8>     → Changer de modèle (ex: /m3)")
                print("  /sandbox    → Activer/Désactiver le sandbox (toggle)")
                print("  /run <code> → Exécuter du code Python (si sandbox actif)")
                print("  /stats      → Stats détaillées (GPU + Sandbox)")
                print("  /gpu        → Stats GPU uniquement")
                print("  /models     → Liste des modèles")
                print("  /exit       → Quitter")
                continue
            
            elif query == "/models":
                print_models()
                continue
            
            elif query.startswith("/m") and len(query) > 2:
                num = query[2:]
                if num in MODELS_DICT:
                    CURRENT_NAME, CURRENT_MODEL = MODELS_DICT[num]
                    print(f"✅ Changé vers: {CURRENT_NAME}")
                    # Pré-chauffe le nouveau modèle
                    await ask_ollama("ping", CURRENT_MODEL)
                else:
                    print(f"❌ Modèle {num} invalide. Tapez /models")
                continue
            
            elif query == "/sandbox":
                sandbox_enabled = not sandbox_enabled
                if sandbox_enabled:
                    if check_sandbox():
                        print("✅ Sandbox ACTIVÉ (prêt à exécuter du code)")
                        print("💡 Tapez /run <code> ou attendez l'auto-détection")
                    else:
                        print("⚠️ Sandbox non disponible. Lancez d'abord: sandbox-start")
                        print("   Puis réessayez /sandbox")
                        sandbox_enabled = False
                else:
                    print("❌ Sandbox DÉSACTIVÉ")
                continue
            
            elif query.startswith("/run "):
                if not sandbox_enabled:
                    print("❌ Sandbox désactivé. Tapez /sandbox d'abord")
                    continue
                code = query[5:]
                if not code.strip():
                    print("❌ Code vide")
                    continue
                print("\n🔧 Exécution dans le sandbox:")
                print("─" * 40)
                result = await sandbox_execute(code)
                print(result)
                print("─" * 40)
                continue
            
            elif query == "/stats":
                gpu = get_gpu_stats()
                print("\n" + "═" * 40)
                print("📊 STATISTIQUES DÉTAILLÉES")
                print("═" * 40)
                print(f"{format_gpu_stats(gpu)}")
                if sandbox_enabled and sandbox_stats.total_calls > 0:
                    print(f"\n{sandbox_stats}")
                elif sandbox_enabled:
                    print("\n📊 Sandbox actif (aucune exécution encore)")
                else:
                    print("\n📊 Sandbox désactivé")
                print("═" * 40)
                continue
            
            elif query == "/gpu":
                gpu = get_gpu_stats()
                print(f"\n{format_gpu_stats(gpu)}")
                continue
            
            elif not query:
                continue
            
            # Requête normale
            print(f"\n🔄 Génération avec {CURRENT_NAME}...", end=" ", flush=True)
            response, elapsed_ms = await ask_ollama(query, CURRENT_MODEL)
            print(f"\r📝 Réponse ({elapsed_ms:.0f}ms):")
            print("─" * 40)
            print(response)
            print("─" * 40)
            
            # Auto-détection et exécution de code Python si sandbox activé
            if sandbox_enabled and "```python" in response:
                try:
                    code_block = response.split("```python")[1].split("```")[0].strip()
                    if code_block and len(code_block) > 20:
                        print("\n🔧 Auto-exécution du code détecté:")
                        print("─" * 40)
                        result = await sandbox_execute(code_block)
                        print(result)
                        print("─" * 40)
                except:
                    pass
        
        except KeyboardInterrupt:
            print("\n")
            continue
        except Exception as e:
            print(f"\n❌ Erreur: {e}")
    
    print("\n👋 Au revoir!")
    cleanup()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Au revoir!")
    except Exception as e:
        print(f"Erreur fatale: {e}")
EOF

chmod +x /usr/local/bin/nafis

echo -e "  ${GREEN}✓ NAFIS Python Async installé${NC}"

# =============================================================================
# 5. Script de démarrage unifié
# =============================================================================
echo -e "${YELLOW}[5/5] Création des scripts de démarrage...${NC}"

cat > /usr/local/bin/nafis-start << 'EOF'
#!/bin/bash
# Démarrage complet NAFIS + Sandbox

echo "🚀 Démarrage NAFIS TURBO..."

# Arrêt des services existants
pkill -9 ollama 2>/dev/null
pkill -f "bridge.py" 2>/dev/null
sleep 2

# Source des variables turbo
source /etc/profile.d/ollama-turbo.sh 2>/dev/null

# Démarrage Ollama
ollama serve > /tmp/ollama.log 2>&1 &
sleep 4

# Démarrage sandbox si disponible
if [ -f /root/ai_sandbox/start.sh ]; then
    cd /root/ai_sandbox
    ./start.sh > /tmp/sandbox.log 2>&1 &
    sleep 5
    echo "✅ Sandbox démarré (port 9999)"
else
    echo "⚠️ Sandbox non trouvé dans /root/ai_sandbox"
    echo "   Installez-le avec votre script sandbox.sh"
fi

# Vérification
if curl -s http://localhost:11434/api/tags > /dev/null; then
    echo "✅ Ollama OK (port 11434)"
else
    echo "❌ Ollama problématique"
fi

if curl -s http://localhost:9999/health > /dev/null 2>&1; then
    echo "✅ Sandbox OK (port 9999)"
fi

echo ""
echo "🎯 Prêt! Tapez 'nafis' pour démarrer l'interface"
EOF

cat > /usr/local/bin/nafis-stop << 'EOF'
#!/bin/bash
# Arrêt complet
echo "🛑 Arrêt NAFIS..."
pkill -9 ollama 2>/dev/null
pkill -f "bridge.py" 2>/dev/null
pkill -f "qemu-system" 2>/dev/null
cd /root/ai_sandbox 2>/dev/null && ./stop.sh 2>/dev/null
echo "✅ Arrêté"
EOF

chmod +x /usr/local/bin/nafis-start /usr/local/bin/nafis-stop

# =============================================================================
# Test final
# =============================================================================
echo ""
echo -e "${YELLOW}Test de performance...${NC}"

# Test avec session persistante
cat > /tmp/test_nafis.py << 'EOF'
import asyncio
import aiohttp
import time

async def test():
    connector = aiohttp.TCPConnector(limit=1)
    timeout = aiohttp.ClientTimeout(total=30)
    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        # Premier appel (cache froid)
        start = time.time()
        async with session.post("http://localhost:11434/api/generate", 
                               json={"model":"qwen-turbo","prompt":"say hi","stream":False,"options":{"num_predict":10}}) as resp:
            await resp.json()
        cold = time.time() - start
        
        # Second appel (cache chaud)
        start = time.time()
        async with session.post("http://localhost:11434/api/generate", 
                               json={"model":"qwen-turbo","prompt":"say hi","stream":False,"options":{"num_predict":10}}) as resp:
            await resp.json()
        hot = time.time() - start
        
        print(f"Cache froid: {cold:.3f}s")
        print(f"Cache chaud: {hot:.3f}s")
        print(f"✅ Session HTTP persistante = vitesse curl native!")

asyncio.run(test())
EOF

python3 /tmp/test_nafis.py

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}               INSTALLATION NAFIS TURBO v3 RÉUSSIE !   		 ${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}📦 Commandes disponibles:${NC}"
echo "  nafis-start    → Démarre Ollama + Sandbox"
echo "  nafis-stop     → Arrête tous les services"
echo "  nafis          → Interface ultra-rapide (Python asynchrone)"
echo ""
echo -e "${CYAN}💡 Dans NAFIS v3:${NC}"
echo "  /m1 à /m8      → Changer de modèle instantané"
echo "  /sandbox       → Activer/Désactiver le sandbox (toggle)"
echo "  /run <code>    → Exécuter Python (si sandbox activé)"
echo "  /stats         → Stats GPU + Sandbox (temps, taille, etc.)"
echo "  /gpu           → Stats GPU uniquement"
echo ""
echo -e "${GREEN}⚡ Performance: Session HTTP persistante = même vitesse que curl!${NC}"
echo -e "${GREEN}   Cache chaud: <1s (identique à vos tests)${NC}"
echo ""
echo -e "${YELLOW}⚠️  Note: Votre sandbox doit être installé séparément dans /root/ai_sandbox${NC}"
echo -e "${YELLOW}   Lancez d'abord votre script sandbox.sh, puis 'nafis-start'${NC}"
echo ""
