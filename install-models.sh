#!/bin/bash
# Script d'installation des modèles 

echo "🔄 Installation des modèles Ollama..."

# Vérifier qu'Ollama est executé
if ! curl -s http://localhost:11434/api/tags > /dev/null; then
    echo "❌ Ollama ne répond pas. Démarrage..."
    ollama serve > /tmp/ollama.log 2>&1 &
    sleep 5
fi

# Liste des modèles à installer
declare -A MODELS=(
    ["MiMo-7B"]="hf.co/mradermacher/MiMo-7B-Base-Qwenified-GGUF:Q4_K_M"
    ["Qwen Coder 3B"]="qwen2.5-coder:3b"
    ["CodeQwen"]="codeqwen:latest"
    ["DeepSeek Coder"]="deepseek-coder:6.7b"
)

for name in "${!MODELS[@]}"; do
    model="${MODELS[$name]}"
    echo ""
    echo "📦 Téléchargement de $name ($model)..."
    
    if ollama pull "$model"; then
        echo "✅ $name restauré"
    else
        echo "❌ Échec pour $name"
    fi
done

echo ""
echo "✅ Installation terminée !"
ollama list
