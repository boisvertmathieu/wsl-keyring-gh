# Stocker les jetons de `gh` dans un keyring sous WSL

Ce guide part d’Ubuntu 26.04 dans WSL, sans bureau GNOME. Le coffre chiffre les secrets sur disque ; une application du même utilisateur ayant accès au coffre déverrouillé peut les lire.

## 1. Prérequis

Utilisez WSL 2 récent et un utilisateur Linux ordinaire disposant de `sudo`. N’exécutez pas `gh` avec `sudo` : root aurait son propre coffre et sa propre configuration. Si nécessaire, créez un utilisateur avec `adduser`, ajoutez-le au groupe `sudo`, puis ouvrez WSL avec cet utilisateur.

Dans PowerShell :

```powershell
wsl --version
wsl --update
wsl --list --verbose
```

Dans Ubuntu, vérifiez `cat /etc/os-release` et `id -un`. **systemd n’est pas requis**. Le cas de référence testé est un bus privé `dbus-run-session`, sans systemd. La voie systemd ci-dessous reste **non testée** ; ne mélangez pas les deux branches.

## 2. Installer la pile principale

**GNOME Keyring + libsecret + D-Bus** expose le service de secrets Linux utilisé par `gh`, sans intégration GPG supplémentaire ni jeton enregistré en clair. `pass` seul n’expose pas ce service.

```bash
sudo apt update
apt-cache policy gnome-keyring libsecret-tools dbus dbus-user-session gh
sudo apt install --no-install-recommends gnome-keyring libsecret-tools dbus dbus-user-session gh ca-certificates procps
```

Ces noms correspondent à Ubuntu 26.04 : [`gnome-keyring`](https://packages.ubuntu.com/resolute/gnome-keyring) fournit le daemon, [`libsecret-tools`](https://packages.ubuntu.com/resolute/libsecret-tools) fournit `secret-tool` et tire la bibliothèque libsecret. `dbus` fournit notamment `dbus-run-session` ; `dbus-user-session` intègre le bus à la session utilisateur. `procps` fournit `pgrep` et `pkill` pour détecter et arrêter les daemons. Le paquet [`gh`](https://packages.ubuntu.com/resolute/gh) de la distribution est dans `universe` et évite un dépôt et une clé de signature supplémentaires. Il peut être plus ancien que les paquets officiels GitHub : lors des tests sous Ubuntu 26.04.1 LTS, sa version était `2.46.0-4`. L’aide de cette version confirme le coffre système par défaut, le repli en clair si le coffre est absent ou inutilisable et la présence de `--insecure-storage`. Contrôlez votre installation avec `gh --version` et `gh auth login --help`.

Si un paquet n’a aucun candidat, vérifiez les sources Ubuntu 26.04 et l’activation de `universe` (notamment pour `gh` et `libsecret-tools`). Au besoin :

```bash
sudo apt install software-properties-common
sudo add-apt-repository universe
sudo apt update
apt-cache search '^libsecret-tools$|^gnome-keyring$|^dbus-user-session$|^gh$'
```

## 3. Ouvrir une session et gérer le coffre

D-Bus transporte les requêtes entre `gh`, `secret-tool` et le service `org.freedesktop.secrets`. Les programmes doivent partager le même **bus de session**. Sans affichage, le prompteur GNOME peut échouer avec `cannot open display` : le premier déverrouillage doit se faire en ligne de commande.

### 3.1 Sans systemd : bus privé (cas de référence)

Retirez de `~/.bashrc` les anciens exports systemd si vous suivez cette branche. N’exportez pas `XDG_RUNTIME_DIR=/run/user/…` ici. Préparez un répertoire privé accessible, puis ouvrez le shell dédié :

```bash
install -d -m 700 "$HOME/.cache"
export XDG_RUNTIME_DIR="$(mktemp -d "$HOME/.cache/keyring-session.XXXXXX")"
dbus-run-session -- bash
```

Dans ce nouveau shell, définissez les fonctions suivantes. Vous pouvez les conserver dans `~/.bashrc` : ouvrez `touch ~/.bashrc && nano ~/.bashrc`, ajoutez ce bloc, enregistrez et quittez, puis exécutez `source ~/.bashrc`. `nano` peut être installé avec `sudo apt install nano` si nécessaire (également pour éditer `/etc/wsl.conf` plus bas). Ces définitions ne lancent aucun daemon à l’ouverture d’un terminal.

```bash
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
```

Cette procédure suppose **un seul bus et aucun lancement concurrent pour cet utilisateur**. La détection par utilisateur est volontairement prudente : un daemon sur un autre bus empêche aussi un nouveau lancement. Le nom court et le filtre d’états sont décrits dans le [manuel de `pgrep`](https://manpages.ubuntu.com/manpages/resolute/man1/pgrep.1.html) ; un zombie n’est plus un daemon actif.

Pour le premier démarrage, utilisez :

```bash
read -r -s -p 'Mot de passe du coffre login : ' keyring_password; printf '\n'
printf %s "$keyring_password" | coffre_demarrer
unset keyring_password
```

Choisissez un mot de passe non vide. Le premier `--unlock` crée `login` s’il n’existe pas. `printf %s` évite d’ajouter un saut de ligne au mot de passe. Le mot de passe du coffre peut différer du mot de passe Linux ; ne le stockez pas dans `.bashrc` ou un fichier.

**Ne répétez pas directement `gnome-keyring-daemon --unlock`** : sous GNOME Keyring 50.0-1 sans systemd, deux appels peuvent créer deux daemons, même avec deux codes de sortie 0. `coffre_demarrer` détecte un daemon actif et saute le second lancement ; ce saut **ne prouve pas que le coffre est déverrouillé**. Le test réel B1 sous `ubuntu:26.04`, sans systemd, a confirmé qu’après deux appels de cette procédure, un seul daemon reste actif, avec le même PID et un lookup identique.

Ne lancez pas `--start` avant `--unlock`, ni les deux ensemble. `--start` sert surtout à terminer une initialisation déjà commencée (par exemple via PAM `--login`) ; il n’est pas nécessaire au premier `store` / `lookup` testé ici. Voir les [options du daemon](https://manpages.ubuntu.com/manpages/resolute/man1/gnome-keyring-daemon.1.html).

Gardez `gh` et `secret-tool` dans ce shell. Chaque `dbus-run-session` crée un autre bus ; ne multipliez pas ces sessions pour le même utilisateur. En fin d’utilisation, après avoir fermé les applications qui utilisent le coffre :

```bash
coffre_arreter
exit
```

De retour dans le shell parent, `rmdir "$XDG_RUNTIME_DIR"` enlève le répertoire s’il est vide ; sinon, conservez-le pour examen. N’utilisez pas de suppression récursive sur une variable de session.

### 3.2 Coffre déjà verrouillé : reprise testée par B2

Le QA a montré qu’un nouveau `--unlock` sur un daemon existant pouvait retourner 0 tout en laissant `Locked=true`. N’en faites pas une commande de réouverture fiable.

La procédure validée par le test réel B2 sous `ubuntu:26.04`, sans systemd, consiste à arrêter le daemon puis à le relancer avec `coffre_demarrer` dans **le même bus**, sans toucher aux fichiers du coffre. Fermez d’abord les applications qui utilisent le coffre. Dans le shell de la section 3.1, avec ses fonctions déjà définies :

```bash
if coffre_arreter; then
    read -r -s -p 'Mot de passe du coffre login : ' keyring_password; printf '\n'
    printf %s "$keyring_password" | coffre_demarrer
    unset keyring_password
fi
```

Refaites ensuite le diagnostic `store` / `lookup` de la section 4. Ce redémarrage touche tous les daemons de coffre de cet utilisateur ; il est destiné à la session privée décrite ici. **Cette reprise a été validée dans le conteneur `ubuntu:26.04`, sans systemd** : le test B2 a constaté `Locked=true` après verrouillage, puis `Locked=false` et la restitution de la valeur stockée après cette séquence, sans redémarrer le bus ni changer de HOME. Ne considérez pas le seul code 0 du daemon comme une preuve. Si la reprise échoue, le redémarrage complet de la session reste l’issue observée par le QA : arrêtez le daemon, quittez le shell privé et reprenez la section 3.1 avec le même mot de passe et les mêmes fichiers de coffre.

### 3.3 Avec systemd : voie non testée

Cette voie n’est pas validée par le test en conteneur. Si vous souhaitez l’essayer, ne lancez pas aussi la branche `dbus-run-session`. Pour activer systemd, ouvrez le fichier avec les droits administrateur :

```bash
sudo touch /etc/wsl.conf
sudo nano /etc/wsl.conf
```

Conservez les autres sections et ajoutez ou adaptez exactement cette entrée (sans dupliquer une section `[boot]` existante) :

```ini
[boot]
systemd=true
```

Depuis PowerShell, `wsl --shutdown` arrête toutes les distributions et leurs processus ; rouvrez ensuite Ubuntu. Vérifiez dans Ubuntu :

```bash
cat /etc/wsl.conf
ps -p 1 -o comm=
systemctl --user is-system-running
systemctl --user status dbus.socket
```

PID 1 doit être `systemd` et le bus utilisateur doit être accessible. Un état `degraded` demande d’examiner les unités en échec ; « Failed to connect to bus » indique un problème de session utilisateur. Voir la [documentation WSL de Microsoft](https://learn.microsoft.com/en-us/windows/wsl/systemd).

Pour raccorder les terminaux au socket utilisateur, ouvrez `touch ~/.bashrc && nano ~/.bashrc` et ajoutez **seulement dans cette branche** :

```bash
if [[ $- == *i* ]]; then
    if [ -S "/run/user/$(id -u)/bus" ]; then
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    fi
fi
```

Enregistrez, quittez puis exécutez `source ~/.bashrc`. Ce bloc ne lance ni ne déverrouille le coffre. Un service utilisateur ou PAM peut déjà avoir démarré un daemon : ne lui appliquez pas aveuglément la procédure d’arrêt de la branche privée. Le partage entre terminaux, l’activation systemd et le déverrouillage dans cette voie restent à tester. WSL ne fournit pas toujours le login PAM ou graphique qui transmettrait le mot de passe au coffre ; aucune ouverture silencieuse n’est garantie.

## 4. Vérifier le coffre avant de connecter `gh`

Utilisez uniquement une valeur publique de diagnostic :

```bash
printf %s 'valeur-publique-de-test' | secret-tool store --label='Diagnostic WSL' application diagnostic-wsl purpose smoke
secret-tool lookup application diagnostic-wsl purpose smoke
secret-tool clear application diagnostic-wsl purpose smoke
```

Le `lookup` doit rendre `valeur-publique-de-test`. Ces attributs sont ceux de notre test, pas ceux de `gh`. Un blocage ou une fenêtre de déverrouillage indique souvent un coffre fermé ; interrompez et consultez la reprise de la section 3.2, sans répéter directement `--unlock`.

## 5. Connecter GitHub CLI et contrôler le stockage

```bash
gh --version
gh auth login --help
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
gh auth login --hostname github.com --git-protocol https --web
```

Suivez le parcours navigateur ; si le navigateur ne s’ouvre pas depuis WSL, ouvrez vous-même l’URL indiquée sous Windows. Les variables de jeton doivent être absentes pour tester les identifiants enregistrés. Utilisez la même session et le même utilisateur que pour `secret-tool`.

Sous Linux, `gh` utilise par défaut le keyring système via Secret Service (la pile libsecret ici). Si ce stockage échoue, il peut retomber sur un fichier en clair, normalement `~/.config/gh/hosts.yml`. `GH_CONFIG_DIR` ou `XDG_CONFIG_HOME` peuvent déplacer ce fichier. Aucun réglage `gh config set` n’est nécessaire. Ce comportement est décrit dans le [manuel de connexion](https://cli.github.com/manual/gh_auth_login).

`--insecure-storage` force le stockage en clair. Cela peut servir dans un environnement éphémère sans coffre, avec des protections adaptées ; on l’évite ici puisque le but est de chiffrer les jetons persistants. Vérifiez l’aide de la version installée, surtout si elle diffère du paquet Ubuntu.

```bash
gh auth status --hostname github.com
config_dir="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
if [ ! -f "$config_dir/hosts.yml" ]; then
    echo 'hosts.yml absent : aucun jeton dans ce fichier'
elif grep -Eq '^[[:space:]]*oauth_token[[:space:]]*:' "$config_dir/hosts.yml"; then
    echo 'ATTENTION : champ oauth_token présent ; stockage en clair à migrer'
else
    echo 'Aucun champ oauth_token dans hosts.yml'
fi
```

Un succès de `gh auth status` indique un compte connecté et des identifiants valides ; certaines versions précisent `(keyring)`. Ne passez pas `--show-token`. Le contrôle ci-dessus n’affiche aucun contenu du fichier. Un `hosts.yml` contenant seulement des métadonnées est normal. Contrôlez chaque compte/hôte si vous en utilisez plusieurs.

Les attributs Secret Service de `gh` relèvent de son implémentation et de sa bibliothèque de keyring ; ils ne constituent pas une interface publique stable documentée. Nous ne proposons donc pas de `secret-tool lookup` ciblant son jeton. La vérification indirecte est : test `secret-tool` réussi, variables de jeton absentes, `gh auth status` réussi et aucun champ `oauth_token` en clair.

### Migrer une configuration déjà en clair

Préparez et testez d’abord le coffre. Le parcours le plus simple est une déconnexion locale suivie d’une nouvelle connexion navigateur :

```bash
gh auth logout --hostname github.com --user VOTRE_IDENTIFIANT
gh auth login --hostname github.com --git-protocol https --web
gh auth status --hostname github.com
```

Remplacez `VOTRE_IDENTIFIANT` par le compte concerné. La déconnexion supprime les identifiants locaux de ce compte ; elle ne révoque pas le jeton côté GitHub. Ne la faites que si vous pouvez vous reconnecter. Reprenez le contrôle du fichier ci-dessus ; répétez pour chaque compte en clair. N’utilisez pas `cat hosts.yml` ni `gh auth token` pour cette migration : ils pourraient afficher le jeton. Les anciennes copies et sauvegardes restent sensibles ; supprimez celles devenues inutiles, et révoquez côté GitHub tout jeton ancien potentiellement exposé.

## 6. Dépannage courant

- **Bus absent / `Cannot autolaunch D-Bus` / `Failed to connect to bus`** : vérifiez `printenv DBUS_SESSION_BUS_ADDRESS`. Sans systemd, reprenez la section 3.1 avec son répertoire privé. Dans la branche systemd uniquement, examinez `systemctl --user status dbus.socket` et le socket utilisateur. Une variable définie peut pointer vers un bus disparu ; ne mélangez pas les exports des deux branches.
- **Daemon absent ou coffre `login` verrouillé** : utilisez `coffre_demarrer` pour le premier lancement. S’il existe déjà un daemon, ne supposez pas que `--unlock` le réutilise ou rouvre le coffre. La reprise décrite en section 3.2 a été validée par B2 dans le conteneur sans systemd : arrêt du daemon, puis `coffre_demarrer` sur le même bus. `cannot open display` ou `Object does not exist at path …/collection/login` peuvent signaler un coffre fermé. Ne supprimez pas ses fichiers et ne contournez pas l’erreur par un mot de passe vide.
- **`gh` écrit encore en clair** : confirmez que `secret-tool` fonctionne depuis exactement le même terminal, sans `sudo`. Contrôlez les variables de jeton, `GH_CONFIG_DIR`, les permissions du HOME et la version de `gh`. Retirez `--insecure-storage`, puis migrez les identifiants : installer les paquets ne déplace pas un jeton déjà enregistré.
- **WSL sans systemd** : le shell `dbus-run-session` fonctionne sans gestionnaire systemd ; gardez-y le daemon et `gh`. Ne mélangez pas les exports de la branche systemd avec ce bus privé. La voie systemd de la section 3.3 reste non testée.
- **Mot de passe oublié ou coffre recréé** : si vous connaissez l’ancien mot de passe, changez-le avec Seahorse (outil graphique facultatif, paquet `seahorse`). Sans ce mot de passe, les secrets chiffrés ne sont pas récupérables. Arrêtez les processus utilisant le coffre et le daemon (y compris son unité utilisateur si active), sauvegardez le répertoire `~/.local/share/keyrings` en lieu sûr, puis écartez uniquement le coffre concerné, généralement `login.keyring`. Ne supprimez pas tout le répertoire par réflexe. Recréez `login` via le premier lancement de la section 3.1, puis reconnectez les applications dont les secrets étaient dans ce coffre. Un changement de mot de passe Linux ne change pas nécessairement celui du coffre sous WSL.

## 7. Alternatives brèves

`pass` convient si vous gérez déjà vos secrets et vos clés GPG de cette manière. Il chiffre les entrées, mais `gh` ne l’utilise pas directement comme backend de keyring Linux : il faut un pont Secret Service compatible ou une intégration explicite supplémentaire. On perd donc la simplicité du stockage système automatique de la pile choisie ici.

Git Credential Manager côté Windows est pertinent sous WSL si vous souhaitez que les identifiants de **Git** soient gérés dans le coffre Windows. Il faut configurer Git dans WSL pour utiliser ce gestionnaire Windows. `gh` exécuté sous Linux dans WSL n’utilise pas automatiquement ce coffre : cette alternative ne remplace donc pas directement le stockage système de `gh` décrit ici.

## Comment lancer le test

Depuis la racine du dépôt, avec Docker (ou remplacez `docker` par `podman`) :

```bash
docker run --rm -v "$PWD:/src:ro" ubuntu:26.04 bash /src/test/run.sh
```

Le conteneur est jetable, le dépôt monté en lecture seule. Le script installe les paquets via APT, crée un utilisateur non-root et un HOME temporaire, démarre un bus privé, puis crée et déverrouille un coffre avec le mot de passe **public de test** `mot-de-passe-public-de-test`. Il compare exactement le résultat de `secret-tool store` / `lookup`, teste B1 (deux appels de `coffre_demarrer`, même PID et un seul daemon actif), puis B2 (verrouillage D-Bus, `Locked=true`, `coffre_arreter` puis `coffre_demarrer` sur le même bus, `Locked=false` et lookup identique) avant de tenter `gh auth login` avec la chaîne fictive `fake`. Aucun HOME de l’hôte n’est monté, aucun vrai jeton n’est utilisé.

Le résumé distingue le premier accès au coffre, B1, B2 et `gh`. Le test installe aussi `procps` pour compter les daemons et `libglib2.0-bin` pour les appels D-Bus avec `gdbus`. Un refus du faux jeton, une erreur réseau ou un délai dépassé est attendu : cela ne valide pas le stockage de `gh`, mais n’annule pas le test du coffre. Le code de sortie est non nul si la préparation nécessaire au test ou la partie keyring/`secret-tool` (y compris B1 ou B2) échoue ; un échec de `gh` seul laisse le code à zéro. Les délais bornent les appels susceptibles de bloquer. APT nécessite le réseau ; ce test ne simule ni le démarrage réel de WSL ni PAM, et ne valide aucune authentification réelle GitHub.

Lors de l’exécution réelle de la commande Docker ci-dessus sous `ubuntu:26.04` (Ubuntu 26.04.1 LTS, GNOME Keyring 50.0-1, `gh` 2.46.0-4), le premier déverrouillage (`Locked=false`), la comparaison `store` / `lookup` et les régressions B1 et B2 ont réussi. B1 a confirmé un seul daemon actif avec le même PID après deux appels ; B2 a confirmé la transition `Locked=true` puis `Locked=false` et la conservation de la valeur après arrêt et relance du daemon sur le même bus. GitHub a refusé `fake` avec `HTTP 401: Bad credentials` ; le script a terminé avec le code 0 conformément à son contrat. **Le stockage réel de `gh` dans le coffre n’a pas été prouvé.** Ce résultat en conteneur ne valide pas le démarrage sur une installation WSL réelle, son bus utilisateur systemd, l’intégration PAM ou un prompteur graphique.

La voie systemd reste non testée. La réussite de B1/B2 porte sur le bus privé sans systemd du conteneur ; elle ne prouve pas le fonctionnement dans les autres environnements mentionnés ci-dessus.
