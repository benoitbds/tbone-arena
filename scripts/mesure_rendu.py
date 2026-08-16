#!/usr/bin/env python3
"""Mesure objective du rendu et de l'audio de T-Bone Arena.

Prend une capture vidéo du jeu et produit un verdict PASS/FAIL par rapport aux
cibles consignées dans CLAUDE.md. Conçu pour être branché sur le protocole de
validation : code de retour non nul dès qu'un critère échoue.

    python3 scripts/mesure_rendu.py capture.mp4

Convention de mesure
--------------------
La luminance est calculée en Rec. 709 sur les valeurs de pixels TELLES QUE
STOCKÉES dans la vidéo (espace d'affichage, normalisé 0..1), sans
linéarisation : c'est ce que perçoit le joueur et ce sur quoi portent les
mesures d'origine. Ne pas linéariser ici, sous peine de chiffres non
comparables à la ligne de base.

Le HUD est exclu par recadrage fractionnaire (donc indépendant de la
résolution de capture) : par défaut les 20 % supérieurs de l'image, où logent
les deux panneaux d'interface.

Dépendances : ffmpeg + ffprobe sur le PATH, numpy, Pillow.
"""

from __future__ import annotations

import argparse
import math
import re
import shutil
import subprocess
import sys

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_SETUP = 2

# --- Cibles (miroir de CLAUDE.md ; toute évolution doit être répercutée là-bas) ---
CIBLES = {
    "luminance_moyenne": (0.15, None, "≥ 0.15"),
    "part_sous_10": (None, 0.55, "≤ 55 %"),
    "part_au_dessus_75": (0.02, 0.08, "2 – 8 %"),
    "lufs": (-20.0, -18.0, "−20 à −18 LUFS"),
    "bande_4_16k": (0.10, None, "≥ 10 %"),
    "bande_2_4k": (None, 0.25, "≤ 25 %"),
}

BANDES = [
    ("0–250 Hz", 0, 250),
    ("250–1 k", 250, 1000),
    ("1–2 kHz", 1000, 2000),
    ("2–4 kHz", 2000, 4000),
    ("4–8 kHz", 4000, 8000),
    ("8–16 kHz", 8000, 16000),
    ("> 16 kHz", 16000, math.inf),
]


def verifier_dependances() -> None:
    """Échoue tôt et explicitement plutôt qu'au milieu d'un décodage vidéo."""
    manquants = []
    for binaire in ("ffmpeg", "ffprobe"):
        if shutil.which(binaire) is None:
            manquants.append(f"{binaire} (paquet système « ffmpeg »)")
    for module, paquet in (("numpy", "numpy"), ("PIL", "Pillow")):
        try:
            __import__(module)
        except ImportError:
            manquants.append(f"{module} (pip install {paquet})")
    if manquants:
        print("Dépendances manquantes :", file=sys.stderr)
        for m in manquants:
            print(f"  - {m}", file=sys.stderr)
        print("\nInstallation :  sudo apt install ffmpeg && pip install numpy Pillow",
              file=sys.stderr)
        sys.exit(EXIT_SETUP)


def sonde(chemin: str) -> dict:
    """Dimensions, durée et présence d'une piste audio."""
    def _q(*args: str) -> str:
        return subprocess.run(["ffprobe", "-v", "error", *args, chemin],
                              capture_output=True, text=True).stdout.strip()

    dims = _q("-select_streams", "v:0", "-show_entries",
              "stream=width,height", "-of", "csv=p=0:s=x")
    if not dims:
        print(f"Aucune piste vidéo exploitable dans « {chemin} ».", file=sys.stderr)
        sys.exit(EXIT_SETUP)
    largeur, hauteur = (int(v) for v in dims.split("x")[:2])
    duree = _q("-show_entries", "format=duration", "-of", "csv=p=0")
    audio = _q("-select_streams", "a:0", "-show_entries", "stream=index", "-of", "csv=p=0")
    return {
        "largeur": largeur,
        "hauteur": hauteur,
        "duree": float(duree) if duree else 0.0,
        "audio": bool(audio),
    }


# ---------------------------------------------------------------------------
# VIDÉO
# ---------------------------------------------------------------------------

def mesurer_video(chemin: str, info: dict, images: int, crop: dict) -> dict:
    import numpy as np

    largeur, hauteur = info["largeur"], info["hauteur"]
    x = int(largeur * crop["gauche"])
    y = int(hauteur * crop["haut"])
    w = max(2, int(largeur * (1.0 - crop["gauche"] - crop["droite"])))
    h = max(2, int(hauteur * (1.0 - crop["haut"] - crop["bas"])))
    # Dimensions paires : impératif pour la plupart des formats de pixels.
    w -= w % 2
    h -= h % 2

    # Échantillonnage régulier : `images` vignettes réparties sur la durée.
    fps = images / info["duree"] if info["duree"] > 0 else 1.0
    filtre = f"crop={w}:{h}:{x}:{y},fps={fps:.6f},format=rgb24"
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", chemin, "-vf", filtre,
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True)
    if proc.returncode != 0 or not proc.stdout:
        print("Échec du décodage vidéo :", proc.stderr.decode(errors="replace")[:400],
              file=sys.stderr)
        sys.exit(EXIT_SETUP)

    octets_par_image = w * h * 3
    total = len(proc.stdout) // octets_par_image
    if total == 0:
        print("Aucune image extraite ; vérifier le recadrage.", file=sys.stderr)
        sys.exit(EXIT_SETUP)

    brut = np.frombuffer(proc.stdout[:total * octets_par_image], dtype=np.uint8)
    pixels = brut.reshape(total, h, w, 3).astype(np.float32) / 255.0
    # Rec. 709 en espace d'affichage (cf. docstring).
    luma = (0.2126 * pixels[..., 0] + 0.7152 * pixels[..., 1] + 0.0722 * pixels[..., 2])

    par_image = luma.reshape(total, -1).mean(axis=1)
    return {
        "images": total,
        "zone": f"{w}×{h} px",
        "luminance_moyenne": float(luma.mean()),
        "luminance_min_image": float(par_image.min()),
        "luminance_max_image": float(par_image.max()),
        "part_sous_10": float((luma < 0.10).mean()),
        "part_sous_25": float((luma < 0.25).mean()),
        "part_au_dessus_75": float((luma > 0.75).mean()),
    }


# ---------------------------------------------------------------------------
# AUDIO
# ---------------------------------------------------------------------------

def mesurer_audio(chemin: str) -> dict:
    import numpy as np

    # --- Loudness intégrée : ebur128 écrit sur stderr, et la valeur qui compte
    # --- est celle du bloc « Summary », pas les lignes par trame.
    proc = subprocess.run(
        ["ffmpeg", "-v", "info", "-nostats", "-i", chemin,
         "-af", "ebur128=peak=true", "-f", "null", "-"],
        capture_output=True, text=True)
    journal = proc.stderr
    resume = journal.split("Summary:")[-1] if "Summary:" in journal else ""
    def _extraire(motif: str, source: str):
        m = re.search(motif, source)
        return float(m.group(1)) if m else None
    lufs = _extraire(r"I:\s*(-?\d+\.?\d*)\s*LUFS", resume)
    crete = _extraire(r"Peak:\s*(-?\d+\.?\d*)\s*dBFS", resume)
    plage = _extraire(r"LRA:\s*(-?\d+\.?\d*)\s*LU", resume)

    # --- Spectre : PCM mono 48 kHz, moyenne des spectres de puissance ---
    pcm = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", chemin,
         "-ac", "1", "-ar", "48000", "-f", "f32le", "-"],
        capture_output=True)
    bandes = {}
    if pcm.returncode == 0 and pcm.stdout:
        signal = np.frombuffer(pcm.stdout, dtype=np.float32)
        taille = 8192
        blocs = len(signal) // taille
        if blocs > 0:
            fenetre = np.hanning(taille).astype(np.float32)
            decoupe = signal[:blocs * taille].reshape(blocs, taille) * fenetre
            spectre = np.abs(np.fft.rfft(decoupe, axis=1)) ** 2
            puissance = spectre.mean(axis=0)
            freqs = np.fft.rfftfreq(taille, 1.0 / 48000.0)
            # Normalisation sur le spectre COMPLET, bande > 16 kHz incluse,
            # sans quoi les pourcentages ne sont pas comparables à la ligne
            # de base d'origine.
            total = float(puissance.sum()) or 1.0
            for nom, bas, haut in BANDES:
                masque = (freqs >= bas) & (freqs < haut)
                bandes[nom] = float(puissance[masque].sum() / total)
    return {"lufs": lufs, "crete_dbfs": crete, "plage_lu": plage, "bandes": bandes}


# ---------------------------------------------------------------------------
# RESTITUTION
# ---------------------------------------------------------------------------

def juger(nom: str, valeur, unite: str = "", pourcent: bool = False):
    """Renvoie (ligne, ok) ; ok vaut None si la mesure est indisponible."""
    mini, maxi, libelle = CIBLES[nom]
    if valeur is None:
        return f"  {nom:<20} {'indisponible':>12}   cible {libelle:<16} —", None
    ok = True
    if mini is not None and valeur < mini:
        ok = False
    if maxi is not None and valeur > maxi:
        ok = False
    affiche = f"{valeur * 100:.1f} %" if pourcent else f"{valeur:.3f}{unite}"
    return f"  {nom:<20} {affiche:>12}   cible {libelle:<16} {'PASS' if ok else 'FAIL'}", ok


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Mesure la lisibilité visuelle et l'équilibre sonore d'une capture.")
    ap.add_argument("capture", help="fichier vidéo à analyser")
    ap.add_argument("--images", type=int, default=12,
                    help="nombre d'images échantillonnées (défaut : 12)")
    ap.add_argument("--crop-haut", type=float, default=0.20,
                    help="fraction supérieure exclue, où loge le HUD (défaut : 0.20)")
    ap.add_argument("--crop-bas", type=float, default=0.0)
    ap.add_argument("--crop-gauche", type=float, default=0.0)
    ap.add_argument("--crop-droite", type=float, default=0.0)
    args = ap.parse_args()

    verifier_dependances()
    info = sonde(args.capture)
    crop = {"haut": args.crop_haut, "bas": args.crop_bas,
            "gauche": args.crop_gauche, "droite": args.crop_droite}

    video = mesurer_video(args.capture, info, args.images, crop)
    audio = mesurer_audio(args.capture) if info["audio"] else None

    print(f"\nCapture : {args.capture}")
    print(f"  source {info['largeur']}×{info['hauteur']} px · {info['duree']:.1f} s")
    print(f"  zone analysée {video['zone']} · {video['images']} images "
          f"(HUD exclu : {args.crop_haut:.0%} supérieurs)")

    verdicts = []

    print("\nIMAGE")
    for nom, val, pct in (("luminance_moyenne", video["luminance_moyenne"], False),
                          ("part_sous_10", video["part_sous_10"], True),
                          ("part_au_dessus_75", video["part_au_dessus_75"], True)):
        ligne, ok = juger(nom, val, pourcent=pct)
        print(ligne)
        verdicts.append(ok)
    print(f"  {'part_sous_25':<20} {video['part_sous_25'] * 100:>11.1f} %   (indicatif)")
    print(f"  {'écart entre images':<20} "
          f"{video['luminance_min_image']:.3f} – {video['luminance_max_image']:.3f}   (indicatif)")

    print("\nAUDIO")
    if audio is None:
        print("  Aucune piste audio dans la capture : critères sonores NON évalués.")
        print("  (Ce n'est pas un PASS — refaire une capture avec le son.)")
        verdicts.append(None)
    else:
        ligne, ok = juger("lufs", audio["lufs"], unite=" LUFS")
        print(ligne)
        verdicts.append(ok)
        if audio["crete_dbfs"] is not None:
            marge = -audio["crete_dbfs"]
            print(f"  {'crête':<20} {audio['crete_dbfs']:>10.1f} dBFS   "
                  f"marge inutilisée {marge:.1f} dB   (indicatif)")
        b = audio["bandes"]
        if b:
            haut = b.get("4–8 kHz", 0) + b.get("8–16 kHz", 0)
            ligne, ok = juger("bande_4_16k", haut, pourcent=True)
            print(ligne)
            verdicts.append(ok)
            ligne, ok = juger("bande_2_4k", b.get("2–4 kHz", 0), pourcent=True)
            print(ligne)
            verdicts.append(ok)
            print("\n  Répartition spectrale")
            for nom, _, _ in BANDES:
                part = b.get(nom, 0.0)
                barre = "█" * int(round(part * 40))
                print(f"    {nom:<10} {part * 100:5.1f} %  {barre}")
        else:
            print("  Spectre non calculable (piste audio vide ou trop courte).")
            verdicts.append(None)

    echecs = [v for v in verdicts if v is False]
    indispo = [v for v in verdicts if v is None]
    print()
    if echecs:
        print(f"VERDICT : ÉCHEC — {len(echecs)} critère(s) hors cible.")
        return EXIT_FAIL
    if indispo:
        print(f"VERDICT : INCOMPLET — {len(indispo)} critère(s) non évalué(s).")
        return EXIT_FAIL
    print("VERDICT : CONFORME — tous les critères sont dans leur cible.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
