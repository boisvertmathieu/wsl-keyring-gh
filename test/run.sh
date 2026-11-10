#!/usr/bin/env bash
set -eu

# À lancer comme root, exclusivement dans un conteneur jetable Ubuntu 26.04.
if [ "$(id -u)" -ne 0 ]; then
    echo 'ÉCHEC : lancer ce script comme root dans ubuntu:26.04.' >&2
    exit 1
fi
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "ÉCHEC : préparation ou test keyring/secret-tool." >&2; fi' EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    dbus dbus-user-session gnome-keyring libsecret-tools gh ca-certificates

# Nouveau HOME à chaque exécution ; aucune configuration de l’hôte n’est utilisée.
if ! id keyring-test >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash keyring-test
fi
test_home=$(mktemp -d /tmp/keyring-test.XXXXXX)
chown keyring-test:keyring-test "$test_home"
trap 'rc=$?; rm -rf "$test_home"; if [ "$rc" -ne 0 ]; then echo "ÉCHEC : préparation ou test keyring/secret-tool." >&2; fi' EXIT
runuser -u keyring-test -- env -i \
    HOME="$test_home" USER=keyring-test LOGNAME=keyring-test \
    PATH=/usr/bin:/bin LANG=C.UTF-8 \
    dbus-run-session -- bash -s <<'SESSION'
set -eu
umask 077
export XDG_RUNTIME_DIR="$HOME/runtime"
export GH_CONFIG_DIR="$HOME/gh"
export GH_PROMPT_DISABLED=1 GH_PAGER=cat
mkdir -p "$XDG_RUNTIME_DIR" "$GH_CONFIG_DIR"

keyring_result='ÉCHEC'
gh_result='ÉCHEC (non tenté)'
# Valeurs publiques de test, sans lien avec un compte réel.
if printf %s 'mot-de-passe-public-de-test' |
    timeout 20s gnome-keyring-daemon --unlock --components=secrets; then
    if printf %s 'valeur-publique-de-test' |
        timeout 20s secret-tool store --label='Test WSL' application test-wsl purpose smoke; then
        if value=$(timeout 20s secret-tool lookup application test-wsl purpose smoke) &&
            [ "$value" = 'valeur-publique-de-test' ]; then
            keyring_result='OK (déverrouillage, store et lookup identique)'
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
printf '\nRésumé\nKeyring / secret-tool : %s\ngh : %s\n' "$keyring_result" "$gh_result"
case "$keyring_result" in OK*) exit 0 ;; *) exit 1 ;; esac
SESSION
