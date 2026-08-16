# PLUS TARD

Idées et constats **hors périmètre** de la tâche en cours, consignés pour ne pas
être perdus et pour ne pas élargir un lot en silence.

---

## Découvert pendant le lot 1, non traité

### Glissières : `metallic 0.92` supprime la réponse diffuse

Modification tentée puis **annulée** : le brief de cause racine classe l'acier
parmi les surfaces correctement valorisées (albédo 0,535), et la toucher
fausserait la mesure du lot 1.

Le constat reste néanmoins valide sur un autre axe que l'albédo : à
`metallic 0.92`, la surface ne s'éclaire quasiment que par réflexion
d'environnement — **donc devient noire dès que le SSR disparaît**, ce qui est le
cas à l'export web en renderer Compatibility. Même mécanisme que la carrosserie
ci-dessous.

**Piste** : `metallic 0.92 → 0.55`, `roughness 0.26 → 0.45`. À reprendre après
mesure du lot 1, et seulement si la lisibilité des rails pose réellement
problème en Compatibility.

### Carrosserie : même mécanisme que les glissières

`car_visuals.gd` pose la carrosserie à `metallic = 0.7`, `roughness = 0.12`.
C'est **exactement le cas des glissières** — une forte composante métallique
supprime la réponse diffuse, la surface ne s'éclaire plus que par réflexion
d'environnement et devient noire dès que le SSR disparaît (export web).

Mesure : albédo linéaire **0,310** pour le bleu de carrosserie, mais rendu
quasi nul en pratique faute de diffus.

Non traité parce que le lot 1 nomme explicitement l'asphalte, le terrain, les
glissières et le vitrage — pas la carrosserie. Vérifier-puis-corriger était dans
le périmètre pour les glissières (« vérifier que … ne sont pas dans le même
cas ») ; découvrir un problème adjacent ne l'est pas.

**Piste** : `metallic 0.7 → 0.35`, `roughness 0.12 → 0.28`, en conservant le
`clearcoat` qui porte l'aspect verni. À mesurer après décision de direction
artistique.

---

## Décisions en attente

### Direction artistique : nuit contre crépuscule

Explicitement hors périmètre. Le lot 1 ne touche que des albédos de surface,
qui sont des propriétés physiques des matériaux : ils restent valables quelle
que soit la direction retenue. Seul l'éclairage la départagera.

### Ciel : contribution ambiante en Compatibility

`ambient_light_source = SKY` avec `sky_contribution` partielle se comporte
différemment en renderer Compatibility. À vérifier au moment de l'export web,
indépendamment de la direction artistique retenue.

---

## Dette technique connue

- **Constantes mortes** dans `car.gd` : `MIN_IMPACT_SPEED` et
  `RAM_INERTIA_KEEP` n'ont plus aucune référence depuis la refonte du résolveur
  d'impact.
- **Version déclarée incohérente** : `project.godot` annonce `4.7` alors que le
  moteur local et l'image Docker sont en `4.5`.
- **Coût des ombres non chiffré** : six projecteurs à ombres portées sur le
  circuit, jamais mesurés faute d'affichage.
- **T-Bones rares en course** : la fenêtre de croisement dure environ une
  seconde ; augmenter le nombre de concurrents ou élargir le carrefour.
