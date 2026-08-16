#!/bin/bash
set -e

echo "=== [TBONE-ARENA] Build & Relance Serveur Dédié ==="

cd "$(dirname "$0")/.."

# 1. Validation du projet Godot avant tout déploiement.
#    Le conteneur exécute les sources telles quelles : un script qui ne compile
#    pas ne serait détecté qu'au runtime, en production.
if command -v godot4 >/dev/null 2>&1; then
    echo "→ Validation du projet Godot..."
    godot4 --headless --editor --quit --path game >/dev/null
    echo "✅ Projet valide."
else
    echo "⚠️  godot4 introuvable en local : validation ignorée."
fi

# 2. Build et redémarrage du conteneur.
#    Aucun binaire exporté n'est requis : l'image embarque le runtime Godot
#    headless et monte directement le dossier game/.
cd docker/server
docker compose down
docker compose build
docker compose up -d

echo "✅ Serveur tbone-arena déployé et actif sur le port UDP 7777."
echo "   Bots de test :  docker compose --profile test up -d --scale tbone-bot=4"
docker logs -f tbone-arena-server
