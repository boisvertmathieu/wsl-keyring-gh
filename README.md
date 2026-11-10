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

Dans Ubuntu, vérifiez `cat /etc/os-release` et `id -un`. **systemd est recommandé, pas requis** : il fournit un bus utilisateur partagé entre les terminaux. Pour l’activer, conservez les autres réglages de `/etc/wsl.conf` et ajoutez ou adaptez :

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

PID 1 doit être `systemd`. Un état utilisateur `degraded` demande d’examiner les unités en échec ; « Failed to connect to bus » signifie que le gestionnaire ou son bus utilisateur n’est pas accessible. Voir la [documentation WSL de Microsoft](https://learn.microsoft.com/en-us/windows/wsl/systemd).

## 2. Installer la pile principale

**GNOME Keyring + libsecret + D-Bus** expose le service de secrets Linux utilisé par `gh`, sans intégration GPG supplémentaire ni jeton enregistré en clair. `pass` seul n’expose pas ce service.

```bash
sudo apt update
apt-cache policy gnome-keyring libsecret-tools dbus dbus-user-session gh
sudo apt install --no-install-recommends gnome-keyring libsecret-tools dbus dbus-user-session gh ca-certificates
```

Ces noms correspondent à Ubuntu 26.04 : [`gnome-keyring`](https://packages.ubuntu.com/resolute/gnome-keyring) fournit le daemon, [`libsecret-tools`](https://packages.ubuntu.com/resolute/libsecret-tools) fournit `secret-tool` et tire la bibliothèque libsecret. `dbus` fournit notamment `dbus-run-session` ; `dbus-user-session` intègre le bus à la session utilisateur. Le paquet [`gh`](https://packages.ubuntu.com/resolute/gh) de la distribution est dans `universe` et évite un dépôt et une clé de signature supplémentaires. Il peut être plus ancien que les paquets officiels GitHub : lors des tests sous Ubuntu 26.04.1 LTS, sa version était `2.46.0-4`. L’aide de cette version confirme le coffre système par défaut, le repli en clair si le coffre est absent ou inutilisable et la présence de `--insecure-storage`. Contrôlez votre installation avec `gh --version` et `gh auth login --help`.

Si un paquet n’a aucun candidat, vérifiez les sources Ubuntu 26.04 et l’activation de `universe` (notamment pour `gh` et `libsecret-tools`). Au besoin :

```bash
sudo apt install software-properties-common
sudo add-apt-repository universe
sudo apt update
apt-cache search '^libsecret-tools$|^gnome-keyring$|^dbus-user-session$|^gh$'
```

## 3. Ouvrir une session et déverrouiller le coffre

D-Bus transporte les requêtes entre `gh`, `secret-tool` et le service `org.freedesktop.secrets`. Installer les paquets ne suffit pas : les programmes doivent partager le même **bus de session**, et le coffre `login` doit être déverrouillé.

Avec systemd, si le bus existe mais que la variable manque :

```bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
test -S "$XDG_RUNTIME_DIR/bus" && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
```

Sans systemd ou sans bus utilisateur fonctionnel, ouvrez un shell dédié :

```bash
dbus-run-session -- bash
```

Effectuez les étapes suivantes et utilisez `gh` **dans ce shell**. `exit` termine cette session ; chaque shell lancé ainsi a son propre bus. Évitez plusieurs bus et daemons concurrents sur le même coffre.

Dans la session choisie, saisissez le mot de passe du coffre sans l’afficher ni l’inscrire dans l’historique. `--unlock` déverrouille le coffre et démarre le daemon s’il n’existe pas encore ; ne le faites pas précéder de `--start` :

```bash
read -r -s -p 'Mot de passe du coffre login : ' keyring_password; printf '\n'
printf %s "$keyring_password" | gnome-keyring-daemon --unlock --components=secrets
unset keyring_password
```

Choisissez un mot de passe non vide. Au premier `--unlock`, le coffre `login` est créé s’il n’existe pas ; ensuite, utilisez son mot de passe existant. Il peut différer du mot de passe Linux. La commande lit l’entrée standard : `printf %s` évite d’ajouter un saut de ligne au mot de passe. Voir les [options du daemon](https://manpages.ubuntu.com/manpages/resolute/man1/gnome-keyring-daemon.1.html).

Avec GNOME Keyring 50.0-1 sous Ubuntu 26.04, lancer `--start` avant `--unlock` peut laisser un premier daemon verrouillé propriétaire de Secret Service tandis que `--unlock` en démarre un second. `secret-tool` contacte alors le premier et échoue. `--start` sert surtout à terminer l’initialisation d’un daemon déjà lancé, souvent par PAM avec `--login` (qui implique `--unlock`). Si nécessaire, il vient **après** un `--unlock` réussi ; ne combinez pas les deux options. Il n’est pas nécessaire pour `secret-tool` ou `gh` lorsque le déverrouillage a réussi et que le bus de session est le bon.

### Au démarrage des terminaux

Avec systemd, cet extrait peut être ajouté à `~/.bashrc` pour raccorder les terminaux interactifs au bus partagé, sans démarrer de daemon avant le premier déverrouillage :

```bash
if [[ $- == *i* ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    fi
fi
```

Après le démarrage de WSL, exécutez les trois lignes `read` / `printf … --unlock` / `unset` ci-dessus dans un premier terminal. Les autres terminaux utilisant ce bus profitent du coffre ouvert ; ils n’ont pas besoin de `GNOME_KEYRING_CONTROL` pour utiliser `secret-tool` ou `gh`. Il faut normalement saisir le mot de passe une fois par session de coffre, et de nouveau après verrouillage ou redémarrage. Sans systemd, utilisez le shell `dbus-run-session` et déverrouillez-y le coffre.

WSL ne passe pas toujours par PAM ou un login graphique qui transmettrait le mot de passe Linux au coffre. Le raccordement au bus **ne déverrouille pas silencieusement le coffre**. Sans interface graphique, le prompteur GNOME peut être indisponible (`cannot open display`) : déverrouillez en ligne de commande avant d’utiliser le service de secrets. Ne placez pas son mot de passe dans `.bashrc`, un service ou un fichier.

## 4. Vérifier le coffre avant de connecter `gh`

Utilisez uniquement une valeur publique de diagnostic :

```bash
printf %s 'valeur-publique-de-test' | secret-tool store --label='Diagnostic WSL' application diagnostic-wsl purpose smoke
secret-tool lookup application diagnostic-wsl purpose smoke
secret-tool clear application diagnostic-wsl purpose smoke
```

Le `lookup` doit rendre `valeur-publique-de-test`. Ces attributs sont ceux de notre test, pas ceux de `gh`. Un blocage ou une fenêtre de déverrouillage indique souvent un coffre fermé ; interrompez et déverrouillez-le dans le même bus.

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

- **Bus absent / `Cannot autolaunch D-Bus` / `Failed to connect to bus`** : vérifiez `printenv DBUS_SESSION_BUS_ADDRESS` et `systemctl --user status dbus.socket`. Raccordez-vous au socket utilisateur comme indiqué plus haut. Sans ce socket, utilisez `dbus-run-session -- bash`, puis recommencez dans ce shell. Une variable définie peut aussi pointer vers un bus disparu.
- **Daemon absent ou coffre `login` verrouillé** : utilisez directement la saisie masquée et `--unlock` de la section 3, sans `--start` préalable. Si un daemon verrouillé a déjà été lancé avant le déverrouillage, arrêtez d’abord les applications utilisant le coffre, puis ce daemon et son éventuelle unité utilisateur avant de reprendre avec `--unlock`. Dans le cas d’un shell `dbus-run-session`, quittez cette session et ouvrez-en une nouvelle après avoir arrêté son daemon. Ne supprimez pas les fichiers du coffre. `cannot open display` ou `Object does not exist at path …/collection/login` peuvent être les symptômes de cette mauvaise séquence. Un code de sortie du daemon ne prouve pas à lui seul le déverrouillage : refaites `store` / `lookup`. N’utilisez pas un mot de passe vide pour contourner l’erreur.
- **`gh` écrit encore en clair** : confirmez que `secret-tool` fonctionne depuis exactement le même terminal, sans `sudo`. Contrôlez les variables de jeton, `GH_CONFIG_DIR`, les permissions du HOME et la version de `gh`. Retirez `--insecure-storage`, puis migrez les identifiants : installer les paquets ne déplace pas un jeton déjà enregistré.
- **WSL sans systemd** : le shell `dbus-run-session` fonctionne sans gestionnaire systemd ; gardez-y le daemon et `gh`. Si vous voulez partager le bus entre terminaux, privilégiez l’activation de systemd plutôt que de fabriquer des adresses D-Bus persistantes.
- **Mot de passe oublié ou coffre recréé** : si vous connaissez l’ancien mot de passe, changez-le avec Seahorse (outil graphique facultatif, paquet `seahorse`). Sans ce mot de passe, les secrets chiffrés ne sont pas récupérables. Arrêtez les processus utilisant le coffre et le daemon (y compris son unité utilisateur si active), sauvegardez le répertoire `~/.local/share/keyrings` en lieu sûr, puis écartez uniquement le coffre concerné, généralement `login.keyring`. Ne supprimez pas tout le répertoire par réflexe. Recréez `login` avec `--unlock`, puis reconnectez les applications dont les secrets étaient dans ce coffre. Un changement de mot de passe Linux ne change pas nécessairement celui du coffre sous WSL.

## 7. Alternatives brèves

`pass` convient si vous gérez déjà vos secrets et vos clés GPG de cette manière. Il chiffre les entrées, mais `gh` ne l’utilise pas directement comme backend de keyring Linux : il faut un pont Secret Service compatible ou une intégration explicite supplémentaire. On perd donc la simplicité du stockage système automatique de la pile choisie ici.

Git Credential Manager côté Windows est pertinent sous WSL si vous souhaitez que les identifiants de **Git** soient gérés dans le coffre Windows. Il faut configurer Git dans WSL pour utiliser ce gestionnaire Windows. `gh` exécuté sous Linux dans WSL n’utilise pas automatiquement ce coffre : cette alternative ne remplace donc pas directement le stockage système de `gh` décrit ici.

## Comment lancer le test

Depuis la racine du dépôt, avec Docker (ou remplacez `docker` par `podman`) :

```bash
docker run --rm -v "$PWD:/src:ro" ubuntu:26.04 bash /src/test/run.sh
```

Le conteneur est jetable, le dépôt monté en lecture seule. Le script installe les paquets via APT, crée un utilisateur non-root et un HOME temporaire, démarre un bus privé, puis crée et déverrouille un coffre avec le mot de passe **public de test** `mot-de-passe-public-de-test`. Il compare exactement le résultat de `secret-tool store` / `lookup` avant de tenter `gh auth login` avec la chaîne fictive `fake`. Aucun HOME de l’hôte n’est monté, aucun vrai jeton n’est utilisé.

Le résumé distingue le coffre et `gh`. Un refus du faux jeton, une erreur réseau ou un délai dépassé est attendu : cela ne valide pas le stockage de `gh`, mais n’annule pas le test du coffre. Le code de sortie est non nul si la préparation nécessaire au test ou la partie keyring/`secret-tool` échoue ; un échec de `gh` seul laisse le code à zéro. Les délais bornent les appels susceptibles de bloquer. APT nécessite le réseau ; ce test ne simule ni le démarrage réel de WSL ni PAM, et ne valide aucune authentification réelle GitHub.

Lors du test fourni sous `ubuntu:26.04` (Ubuntu 26.04.1 LTS, GNOME Keyring 50.0-1, `gh` 2.46.0-4), le déverrouillage et la comparaison `store` / `lookup` ont réussi. GitHub a refusé `fake` avec `HTTP 401: Bad credentials` ; le script a terminé avec le code 0 conformément à son contrat. **Le stockage réel de `gh` dans le coffre n’a pas été prouvé.** Ce résultat en conteneur ne valide pas le démarrage sur une installation WSL réelle, son bus utilisateur systemd, l’intégration PAM ou un prompteur graphique.
