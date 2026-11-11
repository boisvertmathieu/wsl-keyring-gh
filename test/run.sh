#!/usr/bin/env bash
set -euo pipefail

# À lancer comme root, exclusivement dans un conteneur jetable Ubuntu 26.04.
if [ "$(id -u)" -ne 0 ]; then
    echo 'ÉCHEC : lancer ce script comme root dans ubuntu:26.04.' >&2
    exit 1
fi
trap 'if [ "$?" -ne 0 ]; then echo "ÉCHEC : préparation ou test keyring/secret-tool." >&2; fi' EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    dbus dbus-user-session gnome-keyring libsecret-tools gh ca-certificates procps libglib2.0-bin

# Nouveau HOME à chaque exécution ; aucune configuration de l’hôte n’est utilisée.
if ! id keyring-test >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash keyring-test
fi
test_home=$(mktemp -d /tmp/keyring-test.XXXXXX)
chown keyring-test:keyring-test "$test_home"
trap 'if [ "$?" -ne 0 ]; then echo "ÉCHEC : préparation ou test keyring/secret-tool." >&2; fi; rm -rf "$test_home"' EXIT
runuser -u keyring-test -- env -i \
    HOME="$test_home" USER=keyring-test LOGNAME=keyring-test \
    PATH=/usr/bin:/bin LANG=C.UTF-8 \
    dbus-run-session -- bash -s <<'SESSION'
set -euo pipefail
umask 077
export XDG_RUNTIME_DIR="$HOME/runtime"
export GH_CONFIG_DIR="$HOME/gh"
export GH_PROMPT_DISABLED=1 GH_PAGER=cat
mkdir -p "$XDG_RUNTIME_DIR" "$GH_CONFIG_DIR"

coffre_pids() {
    # Nom Linux limité à 15 caractères ; exclure les processus zombies.
    pgrep -u "$(id -u)" -x -r RSDTt gnome-keyring-d
}

coffre_demarrer() {
    if coffre_pids >/dev/null; then
        echo 'Daemon déjà présent : aucun lancement (état du coffre à vérifier).' >&2
        return 0
    fi
    timeout 20s gnome-keyring-daemon --unlock --components=secrets
}

coffre_arreter() {
    local tentative
    if coffre_pids >/dev/null; then
        pkill -TERM -u "$(id -u)" -x -r RSDTt gnome-keyring-d || return 1
    fi
    for ((tentative=0; tentative<50; tentative++)); do
        if ! coffre_pids >/dev/null; then
            unset GNOME_KEYRING_CONTROL
            return 0
        fi
        sleep 0.1
    done
    echo 'ÉCHEC : daemon encore actif après 5 secondes.' >&2
    return 1
}

# Même procédure que le README ; un seul utilisateur et un seul bus privé.
# Même HOME pour B2 : les données du coffre doivent survivre au daemon.
trap 'coffre_arreter || true' EXIT
collection=/org/freedesktop/secrets/collection/login
coffre_locked() {
    timeout 10s gdbus call --session --dest org.freedesktop.secrets \
        --object-path "$collection" --method org.freedesktop.DBus.Properties.Get \
        org.freedesktop.Secret.Collection Locked
}
coffre_lookup() {
    local value
    value=$(timeout 20s secret-tool lookup application test-wsl purpose smoke) &&
        [ "$value" = 'valeur-publique-de-test' ]
}

keyring_result='ÉCHEC'
b1_result='ÉCHEC (premier accès non validé)'
b2_result='ÉCHEC (premier accès ou B1 non validé)'
gh_result='ÉCHEC (non tenté)'
# Valeurs publiques de test, sans lien avec un compte réel.
if printf %s 'mot-de-passe-public-de-test' | coffre_demarrer; then
    if printf %s 'valeur-publique-de-test' |
        timeout 20s secret-tool store --label='Test WSL' application test-wsl purpose smoke; then
        if [ "$(coffre_locked)" = '(<false>,)' ] && coffre_lookup; then
            keyring_result='OK (Locked=false, store et lookup identique)'
        fi
    fi
fi

# B1 : une seconde invocation ne doit pas créer un autre daemon.
if [[ "$keyring_result" == OK* ]]; then
    b1_result='ÉCHEC (relance, nombre de daemons ou lookup)'
    pids_avant=$(coffre_pids) || pids_avant=''
    if printf %s 'mot-de-passe-public-de-test' | coffre_demarrer &&
        [ "$(coffre_pids | wc -l)" -eq 1 ] &&
        [ "$(coffre_pids)" = "$pids_avant" ] && coffre_lookup; then
        b1_result='OK (deux appels, un seul daemon actif, même PID, lookup identique)'
    fi
fi

# B2 : verrouiller, arrêter et relancer le daemon sans redémarrer le bus.
# Lire Locked=true avant la reprise évite un faux succès sans verrouillage.
if [[ "$b1_result" == OK* ]]; then
    b2_result='ÉCHEC (verrouillage, arrêt/relance, état Locked ou lookup)'
    if timeout 10s gdbus call --session --dest org.freedesktop.secrets \
        --object-path /org/freedesktop/secrets \
        --method org.freedesktop.Secret.Service.Lock "['$collection']" &&
        [ "$(coffre_locked)" = '(<true>,)' ] &&
        coffre_arreter; then
        if printf %s 'mot-de-passe-public-de-test' | coffre_demarrer &&
            [ "$(coffre_locked)" = '(<false>,)' ] &&
            [ "$(coffre_pids | wc -l)" -eq 1 ] && coffre_lookup; then
            b2_result='OK (Locked=true, arrêt/relance sur le même bus, Locked=false, lookup identique)'
        fi
    fi
fi

gh --version
if printf %s 'fake' |
    timeout 45s gh auth login --hostname github.com --git-protocol https --with-token \
        >"$HOME/gh-login.log" 2>&1; then
    # Même un succès inattendu ne suffit pas à prouver le stockage sécurisé.
    if grep -Eq '^[[:space:]]*oauth_token[[:space:]]*:' "$GH_CONFIG_DIR/hosts.yml" 2>/dev/null; then
        gh_result='ÉCHEC (login accepté, jeton stocké en clair)'
    elif timeout 30s gh auth status --hostname github.com >"$HOME/gh-status.log" 2>&1; then
        gh_result='OK (login/status acceptés, aucun champ oauth_token ; résultat inattendu avec fake)'
    else
        gh_result='ÉCHEC (login accepté, status invalide ; stockage non validé)'
    fi
else
    gh_result='ÉCHEC attendu (faux jeton, réseau ou délai ; stockage par gh non validé)'
fi
# Les journaux ne peuvent contenir ici que le faux jeton et des diagnostics.
cat "$HOME/gh-login.log"
if [ -f "$HOME/gh-status.log" ]; then cat "$HOME/gh-status.log"; fi
printf '\nRésumé\nKeyring / secret-tool : %s\nB1 : %s\nB2 : %s\ngh : %s\n' \
    "$keyring_result" "$b1_result" "$b2_result" "$gh_result"
if [[ "$keyring_result" == OK* && "$b1_result" == OK* && "$b2_result" == OK* ]]; then
    exit 0
fi
exit 1
SESSION
