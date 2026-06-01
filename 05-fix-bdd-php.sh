#!/usr/bin/env bash
#
# 05-fix-bdd-php.sh
# -----------------------------------------------------------------------------
# Remédiation (le pendant "réparation" de 04-audit-bdd-php.sh).
# Corrige automatiquement les problèmes courants de la pile BDD + PHP + dashboard :
#   - PHP + extensions manquantes, fuseau horaire
#   - Apache : installation, service, exécution du PHP (mod_php)
#   - MySQL : installation, service
#   - base "supervision", tables, compte applicatif et droits
#   - dossier/dashboard : propriétaire, droits du config.php, VirtualHost
#
# IDEMPOTENT : on peut le relancer, il ne refait que ce qui manque.
# Il MODIFIE le système -> exécute-le avec sudo. Pense à essayer --dry-run d'abord.
#
#   Usage :
#     sudo bash 05-fix-bdd-php.sh --dry-run     # n'applique RIEN, montre le plan
#     sudo bash 05-fix-bdd-php.sh               # applique les corrections (demande confirmation)
#     sudo bash 05-fix-bdd-php.sh --yes         # applique sans confirmation
#
#   Options (flags ou variables d'env) :
#     --dry-run / DRY_RUN=1     ne rien modifier, afficher seulement
#     --yes     / ASSUME_YES=1  ne pas demander de confirmation
#     --seed    / SEED=1        insérer quelques mesures de TEST si la table est vide
#     --tighten / TIGHTEN=1     resserrer un compte qui aurait ALL PRIVILEGES
#
#   Paramètres (identiques à l'audit) :
#     DB_NAME, DB_APP_USER, DB_APP_PASS, DB_HOST, DB_ROOT_PASS, DOCROOT, TZ_WANTED
# -----------------------------------------------------------------------------
set -u

# ============================ PARAMÈTRES ====================================
DB_NAME="${DB_NAME:-supervision}"
DB_APP_USER="${DB_APP_USER:-iot_app}"
DB_APP_PASS="${DB_APP_PASS:-}"
DB_HOST="${DB_HOST:-localhost}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"
DOCROOT="${DOCROOT:-/var/www/dashboard}"
SERVER_NAME="${SERVER_NAME:-www.dashboard.local}"
TZ_WANTED="${TZ_WANTED:-Europe/Paris}"
TABLE_REQUIRED="${TABLE_REQUIRED:-mesures}"

DRY_RUN="${DRY_RUN:-0}"; ASSUME_YES="${ASSUME_YES:-0}"; SEED="${SEED:-0}"; TIGHTEN="${TIGHTEN:-0}"
# ============================================================================

# ---- options ----
for a in "$@"; do case "$a" in
  --dry-run) DRY_RUN=1 ;; --yes|-y) ASSUME_YES=1 ;; --seed) SEED=1 ;; --tighten) TIGHTEN=1 ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "Option inconnue : $a"; exit 2 ;;
esac; done

if [ -t 1 ]; then R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';B=$'\e[36m';BOLD=$'\e[1m';DIM=$'\e[2m';N=$'\e[0m';
else R="";G="";Y="";B="";BOLD="";DIM="";N=""; fi

FIXED=0; KEPT=0; ERRN=0
section(){ echo; echo "${BOLD}== $1 ==${N}"; }
change(){ echo "  ${G}[FIX ]${N} $1"; FIXED=$((FIXED+1)); }
keep()  { echo "  ${DIM}[ ok ] $1${N}"; KEPT=$((KEPT+1)); }
errm()  { echo "  ${R}[ERR ]${N} $1"; ERRN=$((ERRN+1)); }
note()  { echo "  ${Y}[note]${N} $1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
# helper : exécute une commande (ou la montre en dry-run)
maybe(){ if [ "$DRY_RUN" = 1 ]; then printf '       %s$ %s%s\n' "$DIM" "$*" "$N"; else "$@"; fi; }
# helper : applique du SQL lu sur stdin
apply_sql(){ if [ "$DRY_RUN" = 1 ]; then sed 's/^/       | /'; else $ADMIN_MYSQL 2>/dev/null; fi; }
# helper : écrit un fichier depuis stdin (avec sudo)
write_file(){ if [ "$DRY_RUN" = 1 ]; then echo "       (écrirait $1)"; cat >/dev/null; else $SUDO tee "$1" >/dev/null; fi; }

echo "${BOLD}Remédiation BDD + PHP + dashboard${N}"
[ "$DRY_RUN" = 1 ] && echo "${Y}MODE SIMULATION (--dry-run) : aucune modification ne sera appliquée.${N}"
echo "${DIM}base=$DB_NAME  user=$DB_APP_USER  docroot=$DOCROOT  fuseau=$TZ_WANTED${N}"

if [ "$DRY_RUN" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
  printf "Ce script va MODIFIER le système. Continuer ? [y/N] "
  read -r rep; case "$rep" in y|Y|o|O) ;; *) echo "Annulé."; exit 0 ;; esac
fi

PKG_REFRESHED=0
apt_install(){ # $@ = paquets
  if [ "$PKG_REFRESHED" = 0 ]; then maybe $SUDO apt-get update -qq; PKG_REFRESHED=1; fi
  maybe $SUDO apt-get install -y "$@"
}

# =====================================================================
section "1. PHP et extensions"
# =====================================================================
if ! have php; then
  change "installation de PHP + module Apache + PDO MySQL"
  apt_install php libapache2-mod-php php-mysql
else
  keep "PHP présent ($(php -r 'echo PHP_VERSION;' 2>/dev/null))"
fi
# extension pdo_mysql
if have php && ! php -m 2>/dev/null | grep -qi '^pdo_mysql$'; then
  change "installation de php-mysql (pilote PDO manquant)"; apt_install php-mysql
elif have php; then keep "extension pdo_mysql présente"; fi
# fuseau horaire dans tous les php.ini
if have php; then
  set_tz=0
  for ini in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini /etc/php.ini; do
    [ -f "$ini" ] || continue
    cur="$(grep -E '^[[:space:]]*date.timezone' "$ini" 2>/dev/null | head -1)"
    if echo "$cur" | grep -q "$TZ_WANTED"; then continue; fi
    set_tz=1
    if grep -qE '^[[:space:]]*;?[[:space:]]*date.timezone' "$ini"; then
      maybe $SUDO sed -i "s#^[[:space:]]*;\?[[:space:]]*date.timezone.*#date.timezone = ${TZ_WANTED}#" "$ini"
    else
      maybe $SUDO sh -c "printf '\n[Date]\ndate.timezone = %s\n' '$TZ_WANTED' >> '$ini'"
    fi
  done
  [ "$set_tz" = 1 ] && change "date.timezone réglé sur $TZ_WANTED (php.ini)" || keep "date.timezone déjà conforme"
fi

# =====================================================================
section "2. Apache (et exécution du PHP)"
# =====================================================================
if ! have apache2 && ! systemctl list-unit-files 2>/dev/null | grep -q '^apache2'; then
  change "installation d'Apache"; apt_install apache2 libapache2-mod-php
else keep "Apache présent"; fi

# activer le module PHP (sinon les .php sont téléchargés)
if have php && have a2enmod; then
  PHP_MM="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
  if apache2ctl -M 2>/dev/null | grep -qiE 'php[0-9_]*_module|proxy_fcgi'; then
    keep "PHP déjà exécuté par Apache (mod_php / php-fpm)"
  elif [ -f "/etc/apache2/mods-available/php${PHP_MM}.load" ]; then
    change "activation du module Apache php${PHP_MM}"; maybe $SUDO a2enmod "php${PHP_MM}"
  else
    note "module mod_php introuvable pour PHP ${PHP_MM} : utilise php-fpm si c'est ton choix"
  fi
fi

# service actif + activé au démarrage
if systemctl list-unit-files 2>/dev/null | grep -q '^apache2'; then
  systemctl is-enabled --quiet apache2 2>/dev/null && keep "apache2 activé au boot" \
    || { change "activation d'apache2 au démarrage"; maybe $SUDO systemctl enable apache2; }
  systemctl is-active --quiet apache2 && { change "redémarrage d'apache2 (prise en compte config)"; maybe $SUDO systemctl restart apache2; } \
    || { change "démarrage d'apache2"; maybe $SUDO systemctl start apache2; }
fi

# =====================================================================
section "3. MySQL / MariaDB"
# =====================================================================
if ! have mysql && ! systemctl list-unit-files 2>/dev/null | grep -qE '^(mysql|mariadb)'; then
  change "installation de MySQL Server"; apt_install mysql-server
else keep "MySQL/MariaDB présent"; fi

DB_SVC=""
for svc in mysql mariadb; do systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" && DB_SVC="$svc" && break; done
if [ -n "$DB_SVC" ]; then
  systemctl is-enabled --quiet "$DB_SVC" 2>/dev/null && keep "$DB_SVC activé au boot" \
    || { change "activation de $DB_SVC au démarrage"; maybe $SUDO systemctl enable "$DB_SVC"; }
  systemctl is-active --quiet "$DB_SVC" && keep "$DB_SVC actif" \
    || { change "démarrage de $DB_SVC"; maybe $SUDO systemctl start "$DB_SVC"; }
fi

# ---- accès admin MySQL (pour créer base/tables/compte) ----
ADMIN_MYSQL=""
if have mysql; then
  if mysql -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="mysql"
  elif $SUDO mysql -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="$SUDO mysql"
  elif [ -n "$DB_ROOT_PASS" ] && mysql -u root -p"$DB_ROOT_PASS" -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="mysql -u root -p$DB_ROOT_PASS"
  fi
fi
if [ -z "$ADMIN_MYSQL" ] && [ "$DRY_RUN" != 1 ]; then
  errm "pas d'accès admin MySQL : étapes base/tables/compte sautées."
  note "relance avec sudo, ou passe DB_ROOT_PASS=..."
fi

# ---- déterminer le mot de passe applicatif ----
CFG=""; for f in "$DOCROOT/config.php" "$DOCROOT/inc/config.php" "$DOCROOT/includes/config.php"; do [ -r "$f" ] && CFG="$f" && break; done
if [ -z "$DB_APP_PASS" ] && [ -n "$CFG" ]; then
  DB_APP_PASS="$($SUDO grep -oE "DB_PASS[[:space:]]*=[[:space:]]*['\"][^'\"]+" "$CFG" 2>/dev/null | sed -E "s/.*['\"]//" | head -1)"
  [ -n "$DB_APP_PASS" ] && note "mot de passe applicatif récupéré depuis $CFG"
fi
if [ -z "$DB_APP_PASS" ]; then
  if have openssl; then DB_APP_PASS="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)"; else DB_APP_PASS="Iot$(date +%s | tail -c6)!"; fi
  GEN_PASS=1; note "aucun mot de passe fourni : un mot de passe a été généré et sera écrit dans config.php"
else GEN_PASS=0; fi

# =====================================================================
section "4. Base « $DB_NAME », tables et compte « $DB_APP_USER »"
# =====================================================================
if [ -n "$ADMIN_MYSQL" ] || [ "$DRY_RUN" = 1 ]; then
  [ -z "$ADMIN_MYSQL" ] && ADMIN_MYSQL="mysql"   # juste pour l'affichage en dry-run
  change "création (si absente) de la base, des tables et du compte applicatif"
  cat <<SQL | apply_sql
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE \`$DB_NAME\`;
CREATE TABLE IF NOT EXISTS capteurs (
  id INT AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(50) UNIQUE NOT NULL,
  emplacement VARCHAR(100)
);
CREATE TABLE IF NOT EXISTS mesures (
  id INT AUTO_INCREMENT PRIMARY KEY,
  capteur VARCHAR(50),
  type VARCHAR(30),
  valeur FLOAT,
  date_mesure DATETIME DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_date (date_mesure)
);
CREATE USER IF NOT EXISTS '$DB_APP_USER'@'localhost' IDENTIFIED BY '$DB_APP_PASS';
ALTER USER '$DB_APP_USER'@'localhost' IDENTIFIED BY '$DB_APP_PASS';
GRANT SELECT, INSERT ON \`$DB_NAME\`.* TO '$DB_APP_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  # resserrer si ALL PRIVILEGES (opt-in)
  if [ "$TIGHTEN" = 1 ]; then
    change "resserrage des droits de $DB_APP_USER (SELECT/INSERT seulement)"
    cat <<SQL | apply_sql
REVOKE ALL PRIVILEGES ON *.* FROM '$DB_APP_USER'@'localhost';
GRANT SELECT, INSERT ON \`$DB_NAME\`.* TO '$DB_APP_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  fi
  # seed de test si demandé et table vide
  if [ "$SEED" = 1 ]; then
    ROWS="0"; [ "$DRY_RUN" != 1 ] && ROWS="$($ADMIN_MYSQL -N -e "SELECT COUNT(*) FROM \`$TABLE_REQUIRED\`" "$DB_NAME" 2>/dev/null)"
    if [ "$DRY_RUN" = 1 ] || [ "${ROWS:-0}" = "0" ]; then
      change "insertion de quelques mesures de TEST (table vide)"
      cat <<SQL | apply_sql
USE \`$DB_NAME\`;
INSERT IGNORE INTO capteurs (code,emplacement) VALUES ('m5-01','Salle serveur');
INSERT INTO mesures (capteur,type,valeur) VALUES
 ('m5-01','temperature',23.5),
 ('m5-01','humidite',48),
 ('m5-01','co2',640);
SQL
    else keep "table $TABLE_REQUIRED non vide : pas de données de test"; fi
  fi
fi

# =====================================================================
section "5. Dashboard (dossier, config.php, droits, VirtualHost)"
# =====================================================================
# dossier
if [ -d "$DOCROOT" ]; then keep "dossier $DOCROOT présent"
else change "création de $DOCROOT"; maybe $SUDO mkdir -p "$DOCROOT"; fi

# config.php si absent
if [ -z "$CFG" ]; then
  change "création de $DOCROOT/config.php (connexion PDO)"
  write_file "$DOCROOT/config.php" <<PHP
<?php
\$DB_HOST = '$DB_HOST';
\$DB_NAME = '$DB_NAME';
\$DB_USER = '$DB_APP_USER';
\$DB_PASS = '$DB_APP_PASS';

try {
    \$pdo = new PDO(
        "mysql:host=\$DB_HOST;dbname=\$DB_NAME;charset=utf8mb4",
        \$DB_USER, \$DB_PASS,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
} catch (PDOException \$e) {
    die('Connexion impossible : ' . \$e->getMessage());
}
PHP
  CFG="$DOCROOT/config.php"
  [ "$GEN_PASS" = 1 ] && note "mot de passe applicatif généré : ${BOLD}$DB_APP_PASS${N}  (noté dans $CFG)"
else keep "config.php déjà présent ($CFG) — non écrasé"; fi

# propriétaire www-data
OWNER="$(stat -c '%U' "$DOCROOT" 2>/dev/null)"
if [ "$OWNER" != "www-data" ]; then
  change "attribution de $DOCROOT à www-data"; maybe $SUDO chown -R www-data:www-data "$DOCROOT"
else keep "$DOCROOT appartient à www-data"; fi

# droits du config.php
if [ -n "$CFG" ]; then
  PERM="$(stat -c '%a' "$CFG" 2>/dev/null)"
  if [ "$PERM" != "640" ]; then
    change "restriction des droits de config.php (640, root:www-data)"
    maybe $SUDO chown root:www-data "$CFG"; maybe $SUDO chmod 640 "$CFG"
  else keep "config.php déjà en 640"; fi
fi

# VirtualHost si absent
VHOST="/etc/apache2/sites-available/dashboard.conf"
if have apache2 || [ -d /etc/apache2/sites-available ]; then
  if [ ! -f "$VHOST" ]; then
    change "création du VirtualHost $VHOST ($SERVER_NAME)"
    write_file "$VHOST" <<APACHE
<VirtualHost *:80>
    ServerName $SERVER_NAME
    DocumentRoot $DOCROOT
    <Directory $DOCROOT>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
APACHE
    maybe $SUDO a2ensite dashboard.conf
    maybe $SUDO systemctl reload apache2
  else keep "VirtualHost dashboard.conf déjà présent"; fi
  # /etc/hosts
  if ! grep -q "$SERVER_NAME" /etc/hosts 2>/dev/null; then
    change "ajout de $SERVER_NAME dans /etc/hosts"
    maybe $SUDO sh -c "echo '127.0.0.1   $SERVER_NAME' >> /etc/hosts"
  else keep "$SERVER_NAME déjà dans /etc/hosts"; fi
fi

# =====================================================================
section "Bilan"
# =====================================================================
echo "  ${G}corrigés : $FIXED${N}    ${DIM}déjà ok : $KEPT${N}    ${R}erreurs : $ERRN${N}"
if [ "$DRY_RUN" = 1 ]; then
  echo "  ${Y}Simulation terminée — relance sans --dry-run pour appliquer.${N}"
else
  echo "  ${B}Vérification finale recommandée :${N}"
  AUD="$(dirname "$0")/04-audit-bdd-php.sh"
  if [ -f "$AUD" ]; then
    echo "  -> exécution de l'audit…"; echo
    DB_APP_PASS="$DB_APP_PASS" bash "$AUD" || true
  else
    echo "  -> lance  sudo bash 04-audit-bdd-php.sh  pour confirmer."
  fi
fi
echo
exit $([ "$ERRN" -eq 0 ] && echo 0 || echo 1)
