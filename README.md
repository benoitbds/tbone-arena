# T-Bone Arena

Jeu de stock-car de destruction multijoueur sous Godot 4.5, autoritatif serveur.
Deux modes : **Arène Derby** (combat libre 80 × 80 m) et **Course Figure-8**
(circuit en 8 à croisement à niveau, 3 tours).

Le projet est **100 % procédural** : aucun asset image ni audio. Géométrie,
matériaux, textures et formes d'onde sont tous générés par code.

---

## Lancer le jeu

```bash
godot4 --path game                       # menu principal
godot4 --path game -- --solo             # arène derby, 4 bots
godot4 --path game -- --solo --race      # course Figure-8, 4 bots
```

## Serveur dédié

```bash
godot4 --headless --path game -- --server --port=7777          # derby
godot4 --headless --path game -- --server --race --port=7777   # course
```

Ou via Docker :

```bash
cd docker/server
docker compose up -d                                    # derby
docker compose --profile race up -d                     # course
docker compose --profile test up -d --scale tbone-bot=4 # bots de charge
```

Le client bot **doit** recevoir le même mode que le serveur (`--race` des deux
côtés) : les chemins de nœuds servent d'adresses aux RPC.

---

## Validation

### Compilation et simulation

```bash
rm -rf game/.godot                                      # cache froid EN PREMIER
godot4 --headless --path game --quit-after 900 -- --solo
godot4 --headless --editor --quit --path game
```

Cinq passes doivent rester à 0 erreur / 0 avertissement : départ à froid, scan
éditeur, derby, course, réseau. Détail dans la spécification technique.

### Mesure du rendu et de l'audio

Le scan éditeur ne dit rien de ce que voit et entend le joueur.
`scripts/mesure_rendu.py` analyse une capture vidéo du jeu et rend un verdict
objectif :

```bash
python3 scripts/mesure_rendu.py capture.mp4
```

| Option | Défaut | Rôle |
|---|---|---|
| `--images N` | 12 | images échantillonnées sur la durée |
| `--crop-haut F` | 0.20 | fraction supérieure exclue (HUD) |
| `--crop-bas/-gauche/-droite F` | 0 | exclusions complémentaires |

Le recadrage est **fractionnaire**, donc indépendant de la résolution de
capture. La sortie donne, pour chaque critère, la valeur mesurée en regard de
sa cible, puis un verdict global. **Le code de retour est non nul dès qu'un
critère échoue**, ce qui permet de le brancher sur la validation.

Sortie type :

```
IMAGE
  luminance_moyenne           0.171   cible ≥ 0.15          PASS
  part_sous_10                42.3 %  cible ≤ 55 %          PASS
AUDIO
  lufs                       -19.2 LUFS  cible −20 à −18    PASS
```

Dépendances : `ffmpeg` (avec `ffprobe`), `numpy`, `Pillow`.

```bash
sudo apt install ffmpeg && pip install numpy Pillow
```

Les cibles et leurs mesures d'origine sont consignées dans `CLAUDE.md` — elles
ne doivent pas dériver silencieusement.

---

## Repères

| Fichier | Contenu |
|---|---|
| `CLAUDE.md` | Valeurs cibles, albédos calibrés, pièges connus |
| `PLUS_TARD.md` | Idées hors périmètre et dette technique |
| `scripts/deploy_server.sh` | Build et redéploiement du serveur dédié |
