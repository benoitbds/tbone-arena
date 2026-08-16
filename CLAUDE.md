# T-Bone Arena — repères pour les sessions suivantes

Jeu de stock-car de destruction multijoueur, Godot 4.5, autoritatif serveur.
La spécification technique (STD) fait référence pour l'architecture ; ce fichier
ne contient que **les valeurs qui ne doivent pas dériver silencieusement**.

---

## 1. ⚠ La règle qui a produit le bug de rendu

**`albedo_color` porte le hint `source_color` : Godot l'interprète comme du
sRGB et le convertit en linéaire avant le shader.**

Les tables de référence d'albédo donnent des valeurs **linéaires**
(asphalte ≈ 0,09, terre ≈ 0,18). Les saisir directement comme couleur les
divise par un facteur 7 à 30.

```
Color(0.105, 0.11, 0.125)   ->  0.012 linéaire    au lieu de 0.09   (÷ 7,7)
Color(0.075, 0.068, 0.058)  ->  0.0056 linéaire   au lieu de 0.18   (÷ 32)
```

Conversion à utiliser : `Color(x, x, x).linear_to_srgb()`.
Repères : **linéaire 0,09 → sRGB 0,33** · **0,18 → sRGB 0,46**.

La signature du bug était la coexistence de deux populations de valeurs :
les surfaces d'**accent** (vibreurs, acier, débris) avaient reçu des valeurs
sRGB correctes — ce sont exactement les seules qui étaient visibles ; les
surfaces de **sol et de structure** avaient reçu des valeurs physiques
linéaires — exactement les invisibles.

---

## 2. Albédos — mesure d'origine et valeur retenue

Luminance linéaire, Rec. 709.

| Surface | Origine | Retenu | Cible physique |
|---|---|---|---|
| Asphalte piste | 0,0117 | **0,0943** | 0,09 |
| Asphalte arène | 0,0134 | **0,1001** | 0,09 |
| Gravier circuit | 0,0059 | **0,1639** | 0,18 |
| Gravier arène | 0,0053 | **0,1561** | 0,18 |
| Mâts d'éclairage | 0,0224 | **0,1490** | — |
| Pare-chocs / pneus (`mat_dark`) | 0,0045 | **0,0338** | — |
| Vitrage | 0,0017 | **0,0109** | — |
| Bloc moteur | 0,0249 | **0,1495** | — |
| Pile de pneus | 0,0134 | **0,0432** | — |

Surfaces d'accent **inchangées** car déjà correctes : vibreur blanc 0,825 ·
acier 0,535 · débris 0,155.

Rapport de luminance vibreur blanc / asphalte : **70× → 8,7×**.

> `mat_dark` est **partagé** : jupes, capot, portières, pare-chocs tubulaires
> et pneus de roue. Le remonter les touche tous — c'est voulu, caoutchouc et
> tube noir mat veulent tous deux décoller de 0,0045.

Le gravier est **plus clair que l'asphalte** (0,16 vs 0,094). C'est
physiquement correct : la terre réfléchit deux fois plus que le bitume.

---

## 3. Ce qui n'est PAS en cause — vérifié, ne pas y toucher

| Réglage | Valeur | Statut |
|---|---|---|
| `tonemap_exposure` | 1,15 | ✅ correct — ACES à `white 3.0` ne pèse que 0,26 stop |
| `ambient_light_*` circuit | `SKY` · `Color(0.4,0.47,0.7)` · 0,3 · 1,35 | ✅ généreux et calibré |
| `ambient_light_*` arène | `SKY` · `Color(0.42,0.5,0.72)` · 0,35 · 1,25 | ✅ idem |
| Projecteurs de mât | énergie 7–9 · portée 70–95 | ✅ fonctionnels |
| Glissières | `metallic 0.92` · `roughness 0.26` | ✅ albédo correct |

**Ne pas monter l'exposition pour compenser un défaut de lisibilité.** Les
vibreurs, l'acier et les débris sont déjà correctement valorisés ; les
surexposer détruirait le contraste rouge/blanc des vibreurs, seul repère de
lecture actuel du joueur. **Le remède est l'albédo.**

---

## 4. Cibles de lisibilité et d'audio

Établies sur une capture de 19,5 s en mode course, 12 images échantillonnées,
zone de jeu HUD exclu.

| Métrique | Mesure d'origine | Cible |
|---|---|---|
| Luminance moyenne | 0,044 – 0,080 | **0,15 – 0,22** |
| Pixels sous 10 % | 85 – 95 % | **≤ 55 %** |
| Pixels au-dessus de 75 % | < 1 % | **2 – 8 %** |
| Loudness intégrée | −32,6 LUFS | **−20 à −18 LUFS** |
| Énergie 4 – 16 kHz | 1,56 % | **≥ 10 %** |
| Énergie 2 – 4 kHz | 37,4 % | **≤ 25 %** |

Crête d'origine : −14,3 dBFS, soit 14 dB de marge inutilisée.

### Vérification

```bash
python3 scripts/mesure_rendu.py capture.mp4
```

Code de retour non nul si un critère échoue. Dépendances : `ffmpeg`, `numpy`,
`Pillow`.

---

## 5. Non-régression

- **5 passes de validation** à 0 erreur / 0 avertissement (départ à froid, scan
  éditeur, derby, course, réseau) — cache de classes vidé **en premier**.
- **Classement de référence** : 63,5 / 63,9 / 68,7 / 69,0 s, **4/4 bots**.
- Aucun asset image ou audio : projet **100 % procédural** (build web < 20 Mo).
- Rien ne doit dépendre de **SSR, SSAO ou brouillard volumétrique** : ils
  disparaissent à l'export web en renderer Compatibility.

---

## 6. Pièges déjà rencontrés

- `albedo_color` est en sRGB — voir §1, c'est le piège le plus coûteux du projet.
- `PackedFloat32Array(...)` et `PackedColorArray(...)` **ne sont pas des
  expressions constantes** : utiliser `Array[float]` / `Array[Color]`.
- Les types issus de `class_name` dépendent du cache de classes, **absent d'un
  clone neuf ou d'une image Docker fraîche**. Utiliser `const X = preload(...)`.
- `ssr_max_roughness` **n'existe pas** dans `Environment` sous Godot 4.5.
- `alpha_curve` n'existe pas sur `CPUParticles3D` : c'est `color_ramp` qui porte
  l'alpha, et il **multiplie** l'albédo.
- Valider **cache froid en premier** : le scan éditeur construit le cache et
  masque les pannes de démarrage à froid.
