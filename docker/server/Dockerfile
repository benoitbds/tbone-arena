FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Dépendances requises par le runner headless Godot 4 (y compris libfontconfig1 pour supprimer les alertes au démarrage)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    unzip \
    libgl1 \
    libxcursor1 \
    libxinerama1 \
    libxrandr2 \
    libxi6 \
    libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

# Godot 4.5 stable : doit correspondre à la version qui valide le projet
# (les scènes sont écrites au format 4.5, un runtime 4.3 les rejetterait).
RUN wget -O /tmp/godot.zip https://github.com/godotengine/godot/releases/download/4.5-stable/Godot_v4.5-stable_linux.x86_64.zip \
    && unzip /tmp/godot.zip -d /tmp/ \
    && mv /tmp/Godot_v4.5-stable_linux.x86_64 /usr/local/bin/godot4 \
    && chmod +x /usr/local/bin/godot4 \
    && rm /tmp/godot.zip

WORKDIR /app

# Copie du code du jeu dans le conteneur
COPY game/ /app/

EXPOSE 7777/udp

# Exécution directe en mode headless sur le port 7777.
# `--server` est explicite : le NetworkManager n'a ainsi pas à déduire son mode
# du seul DisplayServer headless.
ENTRYPOINT ["godot4", "--headless", "--path", "/app", "--", "--server", "--port=7777"]
