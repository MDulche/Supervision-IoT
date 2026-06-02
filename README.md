# Supervision IoT — Partie Base de données & PHP

Partie **serveur de données** de la chaîne de supervision : stockage des mesures en **MySQL** et affichage temps réel via un **dashboard PHP** (PDO) servi par **Apache**.

> Périmètre de ce repo : **MySQL + PHP + dashboard**.
> Les capteurs (M5Stack/ESP32), le broker **MQTT** et le **backend C++** qui insère les mesures sont gérés à part (binôme). Ici, on part du principe que les mesures **arrivent** dans la base ; ce repo s'occupe de **les stocker proprement et de les afficher**.

---

## Architecture (tranche concernée)

```
[ Backend C++ ]  --INSERT-->  [ MySQL : supervision ]  <--SELECT--  [ PHP / PDO ]  -->  [ Dashboard ]
   (hors repo)                     mesures, capteurs                  ce repo            Apache (HTTP)
```

- **MySQL** : base `supervision`, tables `mesures` (+ `capteurs`), compte applicatif `iot_app` (droits limités).
- **PHP/PDO** : connexion via un `config.php` central, requêtes en lecture (et écriture si besoin).
- **Apache** : sert le dashboard et **exécute** le PHP (mod_php ou php-fpm).

---

## Schéma de la base de données

La base s'appelle **`supervision`**. Elle contient **deux tables** et utilise **un seul compte applicatif** (`iot_app`). Voici le modèle.

```
┌──────────────────────────────┐                ┌────────────────────────────────────┐
│ capteurs                     │                │ mesures                            │
├──────────────────────────────┤   lien logique ├────────────────────────────────────┤
│ id           INT  PK  auto   │   (par le code)│ id           INT   PK  auto        │
│ code         VARCHAR(50) ────┼───────────────►│ capteur      VARCHAR(50)           │
│ emplacement  VARCHAR(100)    │                │ type         VARCHAR(30)           │
└──────────────────────────────┘                │ valeur       FLOAT                 │
                                                 │ date_mesure  DATETIME (auto)       │
                                                 └────────────────────────────────────┘
```

> `mesures.capteur` correspond à `capteurs.code`. C'est un lien **logique** (pas une clé étrangère stricte) : la table `mesures` peut très bien fonctionner seule, `capteurs` sert juste à décrire les appareils.

Le SQL exact (ce que crée le script) :

```sql
CREATE TABLE capteurs (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  code        VARCHAR(50) UNIQUE NOT NULL,   -- identifiant du capteur, ex: 'esp32-salle1'
  emplacement VARCHAR(100)                   -- ex: 'Salle serveur'
);

CREATE TABLE mesures (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  capteur     VARCHAR(50),                   -- code du capteur émetteur
  type        VARCHAR(30),                   -- grandeur mesurée: 'temperature', 'co2'...
  valeur      FLOAT,                          -- la valeur relevée
  date_mesure DATETIME DEFAULT CURRENT_TIMESTAMP,  -- horodatage automatique
  INDEX idx_date (date_mesure)
);
```

Chaque ligne de `mesures` = **une valeur relevée à un instant donné**. Exemple : `('esp32-salle1', 'temperature', 22.4, '2026-06-01 14:03:00')` se lit « le capteur *esp32-salle1* a mesuré une *température* de *22.4* le *1er juin à 14h03* ».

### Qui fournit quoi ?

- **Toi (administrateur), via le script** : tu lances `03-install` avec `sudo`. C'est lui qui crée la base, les tables et le compte. Le **mot de passe root MySQL n'est pas demandé** (connexion par socket `sudo mysql`).
- **Le compte applicatif `iot_app`** (c'est *le* « user à fournir », celui que le script te demande) : il sert à la fois au **dashboard** (qui lit) et au **backend** (qui écrit). Ses droits sont **volontairement limités** :

  ```sql
  CREATE USER 'iot_app'@'localhost' IDENTIFIED BY 'ton-mot-de-passe';
  GRANT SELECT, INSERT ON supervision.* TO 'iot_app'@'localhost';
  ```

  `SELECT` = lecture (pour afficher le dashboard), `INSERT` = écriture (pour enregistrer les mesures). Pas de `DROP`/`DELETE`/`UPDATE` : même si le mot de passe fuite, on ne peut pas effacer la base. Ce compte et son mot de passe sont stockés dans `config.php`.
- **Le binôme (backend MQTT/C++)** : se connecte avec `iot_app` et fait des `INSERT` dans `mesures` à chaque relevé.

### Valeurs de `type` attendues

Le dashboard filtre sur la colonne `type`. Il faut donc que le backend **écrive les mêmes mots-clés** que ceux choisis dans le dashboard. Conventions du projet : `temperature`, `humidite`, `pression`, `co2`, `luminosite`, `presence`. Si le backend insère `temp` mais que le dashboard attend `temperature`, la carte restera vide.

Tu peux tout créer à la main avec le fichier fourni (`sql/schema.sql`) — sinon `03-install` le fait pour toi :

```bash
sudo mysql < sql/schema.sql        # crée base + tables + compte + données d'exemple
```

## Exemple complet (de zéro au dashboard)

Un exemple concret avec des valeurs réelles, du même bout à l'autre. Reprends-les telles quelles ou remplace-les par les tiennes.

| Élément | Valeur d'exemple | Où ça vit |
|---|---|---|
| Base de données | `supervision` | MySQL |
| Utilisateur applicatif | `iot_app` | MySQL + `config.php` |
| Mot de passe | `Iot2026Lab!` | `config.php` (droits 640) |
| Hôte BDD | `localhost` | — |
| Dossier du site | `/var/www/dashboard` | disque du serveur |
| Nom de domaine / URL | `www.dashboard.local` → `http://www.dashboard.local` | VirtualHost + `/etc/hosts` |
| Capteurs affichés | `temperature`, `humidite`, `co2` | dashboard |

### 1. Tout installer en une commande

```bash
sudo DB_NAME=supervision DB_APP_USER=iot_app DB_APP_PASS='Iot2026Lab!' \
     DOCROOT=/var/www/dashboard SERVER_NAME=www.dashboard.local \
     bash 03-install-bdd-php.sh --yes
```

### 2. Ce que ça crée côté base (équivalent SQL)

```sql
CREATE DATABASE supervision CHARACTER SET utf8mb4;
USE supervision;

CREATE TABLE capteurs (
  id INT AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(50) UNIQUE NOT NULL,
  emplacement VARCHAR(100)
);
CREATE TABLE mesures (
  id INT AUTO_INCREMENT PRIMARY KEY,
  capteur VARCHAR(50),
  type VARCHAR(30),
  valeur FLOAT,
  date_mesure DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE USER 'iot_app'@'localhost' IDENTIFIED BY 'Iot2026Lab!';
GRANT SELECT, INSERT ON supervision.* TO 'iot_app'@'localhost';
FLUSH PRIVILEGES;
```

### 3. Le `config.php` déposé dans le dashboard

```php
<?php
$DB_HOST = 'localhost';
$DB_NAME = 'supervision';
$DB_USER = 'iot_app';
$DB_PASS = 'Iot2026Lab!';
$pdo = new PDO("mysql:host=$DB_HOST;dbname=$DB_NAME;charset=utf8mb4",
               $DB_USER, $DB_PASS, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
```

### 4. Générer la page pour 3 capteurs

```bash
sudo SENSORS="temperature humidite co2" TITLE="Salle serveur" CHART=temperature \
     DOCROOT=/var/www/dashboard SERVER_NAME=www.dashboard.local \
     bash 07-dashboard-bdd-php.sh --yes
```

### 5. Insérer quelques mesures (sinon la page est vide)

```bash
sudo mysql supervision -e "INSERT INTO mesures (capteur,type,valeur) VALUES
 ('esp32-salle1','temperature',22.4),
 ('esp32-salle1','humidite',48),
 ('esp32-salle1','co2',780);"
```

### 6. Ouvrir le dashboard

- **Sur le serveur** : l'entrée est déjà dans `/etc/hosts` → ouvre `http://www.dashboard.local`.
- **Depuis un autre PC** : ajoute la ligne suivante dans le fichier `hosts` du PC (remplace par l'IP réelle du serveur), puis ouvre l'URL :

  ```
  192.168.1.50   www.dashboard.local
  ```

### 7. Vérifier que toute la chaîne fonctionne

```bash
# la base contient bien des mesures :
mysql -u iot_app -p'Iot2026Lab!' supervision -e "SELECT * FROM mesures ORDER BY id DESC LIMIT 5;"

# la page répond :
curl -s http://www.dashboard.local | head

# bilan automatique PASS / WARN / FAIL :
sudo bash 04-audit-bdd-php.sh
```

À ce stade : la base `supervision` existe, le compte `iot_app` y a accès en lecture/écriture, le dashboard est servi sur `http://www.dashboard.local` et affiche une carte par capteur + le tableau des dernières mesures. Le backend du binôme n'a plus qu'à se connecter avec `iot_app` / `Iot2026Lab!` et faire des `INSERT` dans `mesures`.

## Arborescence du repo

```
.
├── README.md
├── 03-install-bdd-php.sh      # installation depuis zéro (Apache + MySQL + PHP)
├── 04-audit-bdd-php.sh        # audit (lecture seule) de la pile BDD+PHP
├── 05-fix-bdd-php.sh          # remédiation (corrige les problèmes détectés), idempotent
├── 06-clean-bdd-php.sh        # nettoyage / réinitialisation (désinstalle, option --purge)
├── 07-dashboard-bdd-php.sh    # génère un dashboard PHP sur mesure (choix des capteurs)
├── sql/
│   └── schema.sql            # création base, tables et compte applicatif
└── dashboard/                # code du dashboard (docroot Apache)
    ├── config.php            # connexion PDO (NE PAS versionner les vrais mots de passe)
    ├── index.php             # page principale
    └── data.php              # endpoint JSON (pour graphiques)
```

> Adapte les noms si ton organisation diffère ; le script d'audit accepte des variables (`DB_NAME`, `DOCROOT`, …).

---

## Prérequis

- Ubuntu Server/Desktop (LTS — 24.04 conseillé) ou équivalent Debian.
- Pile installée :

```bash
sudo apt update
sudo apt install apache2 mysql-server php libapache2-mod-php php-mysql
```

---

## Installation

### Option A — script automatique (recommandé)

`03-install-bdd-php.sh` installe **toute la pile depuis zéro** (Apache + MySQL + PHP), crée la base/les tables/le compte, déploie un dashboard et configure le VirtualHost. Idempotent, à lancer avec `sudo`.

```bash
# 1) voir le plan sans rien installer :
sudo bash 03-install-bdd-php.sh --dry-run

# 2) installer (demande confirmation) :
sudo bash 03-install-bdd-php.sh

# variantes :
sudo bash 03-install-bdd-php.sh --yes        # sans confirmation
sudo bash 03-install-bdd-php.sh --no-seed    # sans données de test
```

Ce qu'il fait : paquets (`apache2`, `mysql-server`, `php`, `libapache2-mod-php`, `php-mysql`), fuseau horaire, services activés au démarrage, sécurisation minimale de MySQL, base `supervision` + tables + compte `iot_app` (droits `SELECT`/`INSERT`), dashboard + VirtualHost, et **quelques mesures de test** par défaut pour voir l'affichage tout de suite. Il termine en lançant l'audit.

- Si le repo contient `sql/schema.sql`, il l'**utilise** ; sinon il applique un schéma intégré.
- Si le repo contient un dossier `dashboard/`, c'est **le tien** qui est déployé ; sinon un dashboard minimal fonctionnel (page auto-rafraîchie + `data.php`) est généré.
- Le mot de passe applicatif : fourni via `DB_APP_PASS`, sinon **généré** et écrit dans `config.php` (affiché une fois). Un `config.php` existant n'est jamais écrasé.
- **En mode interactif** (sans `--yes`), le script **demande** le nom de la base, l'utilisateur applicatif et le mot de passe (saisie **masquée** avec confirmation). Laisser vide = valeur par défaut / mot de passe généré. `--ask` force la question même avec `--yes` ; à l'inverse, fournir les variables d'env + `--yes` installe sans aucune question.

À la fin, le script **n'efface pas l'écran** : il **écrit un rapport horodaté** (`rapport-install-*.txt`, sans codes couleur), **marque une pause** (« Appuie sur Entrée pour fermer… ») et affiche un **récapitulatif** — nom de la base, utilisateur BDD, mot de passe, dossier du site, URL, VirtualHost — suivi des **commandes `scp`** pour transférer le site depuis ton PC vers le serveur. Options : `--no-report`, `--no-pause`.

> Après installation, ouvre `http://www.dashboard.local/` (l'entrée `/etc/hosts` est ajoutée automatiquement) ou `http://localhost/`.

### Option B — manuelle (pour comprendre / personnaliser)

#### 1. Base de données

`sql/schema.sql` :

```sql
CREATE DATABASE IF NOT EXISTS supervision
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE supervision;

CREATE TABLE IF NOT EXISTS capteurs (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  code        VARCHAR(50) UNIQUE NOT NULL,
  emplacement VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS mesures (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  capteur     VARCHAR(50),
  type        VARCHAR(30),
  valeur      FLOAT,
  date_mesure DATETIME DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_date (date_mesure)
);

-- compte applicatif : droits volontairement limités (moindre privilège)
CREATE USER IF NOT EXISTS 'iot_app'@'localhost' IDENTIFIED BY 'ChangeMoi_MotDePasse';
GRANT SELECT, INSERT ON supervision.* TO 'iot_app'@'localhost';
FLUSH PRIVILEGES;
```

Import :

```bash
sudo mysql < sql/schema.sql
```

> Change `ChangeMoi_MotDePasse` par un vrai mot de passe et reporte-le dans `dashboard/config.php`.

#### 2. Dashboard PHP

`dashboard/config.php` (connexion centralisée, erreurs en exceptions) :

```php
<?php
$DB_HOST = 'localhost';
$DB_NAME = 'supervision';
$DB_USER = 'iot_app';
$DB_PASS = 'ChangeMoi_MotDePasse';

try {
    $pdo = new PDO(
        "mysql:host=$DB_HOST;dbname=$DB_NAME;charset=utf8mb4",
        $DB_USER, $DB_PASS,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
} catch (PDOException $e) {
    die('Connexion impossible : ' . $e->getMessage());
}
```

Déploiement dans le docroot Apache :

```bash
sudo cp -r dashboard/* /var/www/dashboard/
sudo chown -R www-data:www-data /var/www/dashboard
sudo chmod 640 /var/www/dashboard/config.php   # le mot de passe n'est pas lisible par tous
```

VirtualHost (extrait `/etc/apache2/sites-available/dashboard.conf`) :

```apache
<VirtualHost *:80>
    ServerName www.dashboard.local
    DocumentRoot /var/www/dashboard
</VirtualHost>
```

```bash
sudo a2ensite dashboard.conf
sudo systemctl reload apache2
# accès local : ajouter "127.0.0.1 www.dashboard.local" dans /etc/hosts
```

---

## Générer un dashboard sur mesure

`07-dashboard-bdd-php.sh` construit une page de supervision adaptée aux capteurs que tu choisis, puis la déploie dans Apache.

```bash
# interactif : il pose les questions (capteurs, titre, rafraîchissement, graphique) :
sudo bash 07-dashboard-bdd-php.sh

# prévisualiser sans rien écrire :
sudo bash 07-dashboard-bdd-php.sh --dry-run

# non interactif :
sudo SENSORS="temperature humidite co2" TITLE="Salle serveur" CHART=temperature \
     bash 07-dashboard-bdd-php.sh --yes
```

Il génère dans le `DOCROOT` :

- `sensors.php` — les capteurs et options choisis (modifiable à la main ensuite) ;
- `index.php` — la page : une carte « dernière valeur » par capteur + le tableau des mesures récentes + un graphique optionnel ; rendue côté serveur et auto-rafraîchie ;
- `data.php` — endpoint JSON (utilisé par le graphique) ;
- `config.php` — connexion PDO, créé **seulement s'il manque** (jamais écrasé).

Capteurs proposés : température, humidité, pression, CO₂, luminosité, présence — plus des types personnalisés. Le dashboard lit la table `mesures` en filtrant sur le `type` choisi ; il reste vide tant qu'aucune donnée de ce type n'est présente. VirtualHost mis en place automatiquement, plus rapport + pause comme les autres scripts.

> Le graphique utilise Chart.js via CDN : il faut un accès Internet **côté navigateur** pour l'afficher. Les cartes et le tableau, eux, fonctionnent hors-ligne.

## Vérifier que tout est en ordre — script d'audit

`04-audit-bdd-php.sh` **n'écrit rien** : il analyse l'installation, teste la connexion PDO de bout en bout et affiche un bilan `PASS / WARN / FAIL` avec les commandes de correction.

```bash
# audit standard (sudo recommandé pour les contrôles admin MySQL et les ports)
sudo bash 04-audit-bdd-php.sh

# audit complet : teste aussi le mot de passe applicatif et l'exécution réelle de la page
sudo DB_APP_PASS='ChangeMoi_MotDePasse' \
     PROBE_URL='http://localhost/index.php' \
     -E bash 04-audit-bdd-php.sh
```

Paramètres (variables d'environnement, sinon valeurs par défaut du script) :

| Variable        | Défaut               | Rôle                                    |
|-----------------|----------------------|-----------------------------------------|
| `DB_NAME`       | `supervision`        | base attendue                           |
| `DB_APP_USER`   | `iot_app`            | compte applicatif                       |
| `DB_APP_PASS`   | *(vide)*             | mot de passe applicatif (sinon test PDO sans mot de passe) |
| `DB_ROOT_PASS`  | *(vide)*             | mot de passe root MySQL (contrôles admin si pas de `sudo`) |
| `DOCROOT`       | `/var/www/dashboard` | dossier du dashboard                    |
| `PROBE_URL`     | *(vide)*             | URL à tester (vérifie que le PHP s'exécute) |

Ce que l'audit contrôle : PHP + extensions (`pdo_mysql`, `json`), Apache (actif, PHP exécuté et non téléchargé, ports), MySQL (actif, port 3306), base `supervision`, table `mesures` (présente et non vide), compte `iot_app` et ses droits, **connexion PDO réelle**, fichiers du dashboard et droits du `config.php`.

Le script renvoie le code de sortie `0` si aucun `FAIL`, `1` sinon. Comme l'installeur, il **écrit un rapport** (`rapport-audit-*.txt`), **fait une pause** à la fin et affiche le **récapitulatif** (base, utilisateur, dossier du site, URL) avec les **commandes `scp`**. Désactivables via `NO_REPORT=1` / `NO_PAUSE=1` (ou `--no-report` / `--no-pause` pour l'installeur et la remédiation).

---

## Corriger automatiquement — script de remédiation

`05-fix-bdd-php.sh` est le pendant « réparation » de l'audit : il **corrige** les problèmes courants (paquets manquants, services arrêtés/non activés, module PHP d'Apache, fuseau horaire, base/tables/compte manquants, droits du `config.php`, VirtualHost…). Il est **idempotent** : on peut le relancer, il ne refait que ce qui manque. Il **modifie** le système → lance-le avec `sudo`.

```bash
# 1) toujours commencer par une SIMULATION (n'applique rien, montre le plan) :
sudo bash 05-fix-bdd-php.sh --dry-run

# 2) appliquer les corrections (demande confirmation) :
sudo bash 05-fix-bdd-php.sh

# avec un mot de passe applicatif connu, et données de test si la base est vide :
sudo DB_APP_PASS='ChangeMoi_MotDePasse' bash 05-fix-bdd-php.sh --yes --seed
```

À la fin, le script relance automatiquement `04-audit-bdd-php.sh` (s'il est à côté) pour confirmer que tout est revenu au vert.

Options :

| Flag         | Variable        | Effet |
|--------------|-----------------|-------|
| `--dry-run`  | `DRY_RUN=1`     | n'applique rien, affiche seulement les actions prévues |
| `--yes`      | `ASSUME_YES=1`  | n'attend pas de confirmation |
| `--seed`     | `SEED=1`        | insère quelques mesures de **test** si la table est vide |
| `--tighten`  | `TIGHTEN=1`     | resserre un compte qui aurait `ALL PRIVILEGES` (→ `SELECT`/`INSERT`) |
| `--no-report`| `NO_REPORT=1`   | n'écrit pas le rapport `rapport-fix-*.txt` |
| `--no-pause` | `NO_PAUSE=1`    | ne marque pas la pause finale |

Gestion du mot de passe applicatif : si `DB_APP_PASS` n'est pas fourni, le script le **récupère depuis `config.php`** s'il existe ; sinon il en **génère un**, l'écrit dans un `config.php` neuf et l'affiche une fois. Un `config.php` existant n'est **jamais écrasé**.

> Cycle de vie : **mise en place** `03-install` (+ `07-dashboard` pour la page) → **contrôle** `04-audit` → **maintenance** `04-audit` (constat) → `05-fix --dry-run` (revue) → `05-fix` (application) → **nettoyage** `06-clean`.

## Nettoyer / réinitialiser

`06-clean-bdd-php.sh` défait ce que l'installeur a mis en place. **Destructif** : à lancer avec `sudo`, et toujours en `--dry-run` d'abord.

```bash
# voir ce qui serait supprimé, sans rien toucher :
sudo bash 06-clean-bdd-php.sh --dry-run

# nettoyage du projet (dashboard, VirtualHost, /etc/hosts, base + compte) :
sudo bash 06-clean-bdd-php.sh

# garder la base et le compte (utile si le backend les partage) :
sudo bash 06-clean-bdd-php.sh --keep-db

# remise à blanc : désinstalle Apache, PHP et MySQL en plus :
sudo bash 06-clean-bdd-php.sh --purge
```

Deux niveaux :

- **par défaut** : retire les artéfacts du projet (dossier `/var/www/dashboard`, `dashboard.conf`, entrée `/etc/hosts`, base `supervision` + compte `iot_app`) et **réactive le site Apache par défaut**. La pile LAMP reste installée.
- **`--purge`** : `apt purge` d'Apache/PHP/MySQL + `autoremove` + suppression des dossiers résiduels. **Attention** : cela touche **toute la machine** (toutes les bases, tous les sites), pas seulement le projet — une **double confirmation** (taper `SUPPRIMER`) est demandée.

Sécurités : garde-fou qui refuse un `DOCROOT` système (`/`, `/var/www`, `/etc`…), `--keep-db` pour préserver la base, et comme les autres scripts, **rapport** (`rapport-clean-*.txt`) + **pause** en fin d'exécution. Pour tout réinstaller ensuite : `sudo bash 03-install-bdd-php.sh`.

## Dépannage rapide

| Symptôme                                   | Cause probable                        | Correction |
|--------------------------------------------|---------------------------------------|------------|
| Le `.php` se **télécharge** au lieu de s'afficher | module PHP d'Apache absent       | `sudo apt install libapache2-mod-php && sudo systemctl restart apache2` |
| `PDOException: could not find driver`      | extension PDO MySQL manquante         | `sudo apt install php-mysql && sudo systemctl restart apache2` |
| `Access denied for user 'iot_app'`         | mot de passe faux / mauvais hôte      | vérifier `config.php` et `SHOW GRANTS FOR 'iot_app'@'localhost'` |
| `Unknown database 'supervision'`           | base non créée                        | `sudo mysql < sql/schema.sql` |
| Dashboard **vide**                         | table `mesures` vide                  | vérifier que le backend/simulateur insère bien les mesures |
| `403 Forbidden`                            | droits du dossier                     | `sudo chown -R www-data:www-data /var/www/dashboard` |
| `500 Internal Server Error`                | erreur PHP                            | `sudo tail -f /var/log/apache2/error.log` |
| Heure des mesures **décalée**              | fuseau non aligné                     | `date.timezone = Europe/Paris` (PHP) + `timedatectl set-timezone Europe/Paris` |

---

## Checklist de recette

- [ ] MySQL et Apache **actifs** et **activés au démarrage** (`systemctl enable`)
- [ ] Base `supervision` + table `mesures` présentes
- [ ] Compte `iot_app` limité à `SELECT`/`INSERT` (pas de `ALL PRIVILEGES`)
- [ ] `config.php` en `chmod 640`, propriété `www-data` (mot de passe non exposé)
- [ ] Le dashboard **affiche des données réelles**
- [ ] `sudo bash 04-audit-bdd-php.sh` → **aucun FAIL** (au besoin : `sudo bash 05-fix-bdd-php.sh`)
- [ ] La chaîne **survit à un redémarrage** de la machine

---

## Sécurité

- Ne versionne **jamais** les vrais mots de passe : garde un `config.php` d'exemple et ignore le vrai (`.gitignore`).
- Applique le **moindre privilège** au compte MySQL (`SELECT`/`INSERT` uniquement).
- En réseau non maîtrisé, ajoute **HTTPS** et restreins l'accès au dashboard (`Require ip` ou `htpasswd`).
