#!/bin/bash
# =============================================================================
# Nafis -- Multiples AI with Qemu Sandbox
# By thibaut LOMBARD © copyright all rights reserved
# =============================================================================
cat > /usr/local/bin/nafis << 'EOF'
#!/usr/bin/env python3
"""NAFIS - AI CLI avec Ollama et Sandbox"""
import sys, json, requests, readline, os

OLLAMA = "http://localhost:11434/api/generate"
SANDBOX = "http://localhost:9999/execute"

MODELS = {
    "1": ("MiMo-7B", "hf.co/mradermacher/MiMo-7B-Base-Qwenified-GGUF:Q4_K_M"),
    "2": ("Qwen Coder 3B", "qwen2.5-coder:3b"),
    "3": ("CodeQwen", "codeqwen:latest"),
    "4": ("DeepSeek Coder", "deepseek-coder:6.7b"),
}

def ask(prompt, model):
    r = requests.post(OLLAMA, json={
        "model": model, "prompt": prompt, "stream": False,
        "options": {"temperature": 0.7, "num_predict": 4000}
    }, timeout=120)
    return r.json().get("response", "Erreur")

def sandbox_run(code):
    try:
        r = requests.post(SANDBOX, json={"code": code}, timeout=30)
        return r.json().get("output", "Pas de sortie")
    except:
        return "❌ Sandbox indisponible"

def main():
    print("🤖 NAFIS - Sélectionnez un modèle:")
    for k, (name, _) in MODELS.items():
        print(f"  [{k}] {name}")
    
    choice = input("\nChoix [1-4] (défaut: 2): ").strip() or "2"
    model_name, model_id = MODELS.get(choice, MODELS["2"])
    
    print(f"\n✅ Modèle: {model_name}")
    print("Commandes: /exit, /model, /run <code>, /sandbox")
    print("-" * 50)
    
    while True:
        try:
            query = input("\n>>> ").strip()
            if query in ["/exit", "exit", "quit"]: break
            if query == "/model":
                for k, (name, _) in MODELS.items(): print(f"  [{k}] {name}")
                continue
            if query.startswith("/run "):
                print(sandbox_run(query[5:])); continue
            if not query: continue
            
            print("\n⚡ Génération...")
            resp = ask(query, model_id)
            print(f"\n📝 {resp}")
            
            # Auto-détection code Python
            if "```python" in resp:
                code = resp.split("```python")[1].split("```")[0].strip()
                print(f"\n🔧 Sandbox:\n{sandbox_run(code)}")
                
        except KeyboardInterrupt: break
        except Exception as e: print(f"Erreur: {e}")
    
    print("\n👋 Au revoir!")

if __name__ == "__main__":
    main()
EOF
chmod +x /usr/local/bin/nafis
