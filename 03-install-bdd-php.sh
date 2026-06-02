#!/usr/bin/env bash
#
# 03-install-bdd-php.sh
# -----------------------------------------------------------------------------
# Installation DEPUIS ZÉRO de la partie BASE DE DONNÉES + PHP + DASHBOARD
# (uniquement Apache, MySQL et PHP — pas de MQTT ni de backend C++).
#
# Sur une machine fraîche Debian/Ubuntu, ce script :
#   1. installe Apache, MySQL et PHP (+ pilote PDO MySQL) ;
#   2. règle le fuseau horaire et active les services au démarrage ;
#   3. sécurise MySQL a minima (anonymes, base test) ;
#   4. crée la base "supervision", les tables et le compte applicatif ;
#   5. déploie un dashboard (le dossier ./dashboard du repo s'il existe,
#      sinon un dashboard minimal fonctionnel) + VirtualHost Apache ;
#   6. (par défaut) insère quelques mesures de TEST pour voir l'affichage ;
#   7. lance l'audit final pour confirmer.
#
# IDEMPOTENT et MODIFIE le système -> à exécuter avec sudo.
#
#   Usage :
#     sudo bash 03-install-bdd-php.sh --dry-run     # montre le plan, n'installe rien
#     sudo bash 03-install-bdd-php.sh               # installe (demande confirmation)
#     sudo bash 03-install-bdd-php.sh --yes         # installe sans confirmation
#     sudo bash 03-install-bdd-php.sh --no-seed     # sans données de test
#     sudo bash 03-install-bdd-php.sh --ask         # force la demande des identifiants
#
#   En mode interactif (sans --yes), le script DEMANDE le nom de la base,
#   l'utilisateur applicatif et le mot de passe (saisie masquée, confirmation).
#   Laisser vide = valeur par défaut / mot de passe généré. Tout reste
#   pilotable sans question via les variables d'env ci-dessous + --yes.
#
#   Paramètres (variables d'env) :
#     DB_NAME, DB_APP_USER, DB_APP_PASS, DB_ROOT_PASS, DB_HOST,
#     DOCROOT, SERVER_NAME, TZ_WANTED
# -----------------------------------------------------------------------------
set -u

# ============================ PARAMÈTRES ====================================
DB_NAME="${DB_NAME:-supervision}"
DB_APP_USER="${DB_APP_USER:-iot_app}"
DB_APP_PASS="${DB_APP_PASS:-}"            # vide -> généré et écrit dans config.php
DB_ROOT_PASS="${DB_ROOT_PASS:-}"          # vide -> root garde l'auth socket (défaut Ubuntu)
DB_HOST="${DB_HOST:-localhost}"
DOCROOT="${DOCROOT:-/var/www/dashboard}"
SERVER_NAME="${SERVER_NAME:-www.dashboard.local}"
TZ_WANTED="${TZ_WANTED:-Europe/Paris}"

DRY_RUN="${DRY_RUN:-0}"; ASSUME_YES="${ASSUME_YES:-0}"; SEED="${SEED:-1}"; NO_REPORT="${NO_REPORT:-0}"; NO_PAUSE="${NO_PAUSE:-0}"; ASK="${ASK:-0}"
PWD_SET=0; [ -n "$DB_APP_PASS" ] && PWD_SET=1   # mot de passe fourni explicitement (env) ?
# ============================================================================

for a in "$@"; do case "$a" in
  --dry-run) DRY_RUN=1 ;; --yes|-y) ASSUME_YES=1 ;; --no-seed) SEED=0 ;; --seed) SEED=1 ;;
  --no-report) NO_REPORT=1 ;; --no-pause) NO_PAUSE=1 ;; --ask) ASK=1 ;;
  -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
  *) echo "Option inconnue : $a"; exit 2 ;;
esac; done

REPORT="${REPORT:-rapport-install-$(date +%Y%m%d-%H%M%S).txt}"
[ -t 1 ] && _TTY=1 || _TTY=0
if [ "$NO_REPORT" != 1 ]; then exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$REPORT")) 2>&1; fi
if [ "$_TTY" = 1 ]; then R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';B=$'\e[36m';BOLD=$'\e[1m';DIM=$'\e[2m';N=$'\e[0m';
else R="";G="";Y="";B="";BOLD="";DIM="";N=""; fi
STEP=0; ERRN=0
section(){ STEP=$((STEP+1)); echo; echo "${BOLD}== Étape $STEP : $1 ==${N}"; }
act(){ echo "  ${G}->${N} $1"; }
keep(){ echo "  ${DIM}   $1${N}"; }
errm(){ echo "  ${R}[ERR]${N} $1"; ERRN=$((ERRN+1)); }
note(){ echo "  ${Y}[note]${N} $1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
maybe(){ if [ "$DRY_RUN" = 1 ]; then printf '       %s$ %s%s\n' "$DIM" "$*" "$N"; else "$@"; fi; }
apply_sql(){ if [ "$DRY_RUN" = 1 ]; then sed 's/^/       | /'; else $ADMIN_MYSQL 2>/dev/null; fi; }
write_file(){ if [ "$DRY_RUN" = 1 ]; then echo "       (écrirait $1)"; cat >/dev/null; else $SUDO tee "$1" >/dev/null; fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "${BOLD}Installation BDD + PHP + dashboard (depuis zéro)${N}"
[ "$DRY_RUN" = 1 ] && echo "${Y}MODE SIMULATION (--dry-run) : rien ne sera installé.${N}"
echo "${DIM}base=$DB_NAME  user=$DB_APP_USER  docroot=$DOCROOT  vhost=$SERVER_NAME  seed=$SEED${N}"
ask_credentials(){
  echo
  echo "${BOLD}Identifiants de la base de données${N} ${DIM}(Entrée = valeur par défaut)${N}"
  printf "  Nom de la base [%s] : " "$DB_NAME"; read -r _r; DB_NAME="${_r:-$DB_NAME}"
  printf "  Utilisateur applicatif [%s] : " "$DB_APP_USER"; read -r _r; DB_APP_USER="${_r:-$DB_APP_USER}"
  local _pdef; if [ -f "$DOCROOT/config.php" ]; then _pdef="garder celui de config.php"; else _pdef="généré automatiquement"; fi
  while :; do
    printf "  Mot de passe de %s [Entrée = %s] : " "$DB_APP_USER" "$_pdef"; read -rs _p1; echo
    [ -z "$_p1" ] && break
    printf "  Confirme le mot de passe : "; read -rs _p2; echo
    if [ "$_p1" = "$_p2" ]; then DB_APP_PASS="$_p1"; PWD_SET=1; break
    else echo "  ${Y}Les deux saisies diffèrent, recommence.${N}"; fi
  done
}
if [ "$_TTY" = 1 ] && { [ "$ASK" = 1 ] || [ "$ASSUME_YES" != 1 ]; }; then ask_credentials; fi

if [ "$DRY_RUN" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
  printf "Installer la pile Apache + MySQL + PHP sur cette machine ? [y/N] "
  read -r rep; case "$rep" in y|Y|o|O) ;; *) echo "Annulé."; exit 0 ;; esac
fi

# =====================================================================
section "Paquets (Apache, MySQL, PHP, PDO MySQL)"
# =====================================================================
act "apt update puis installation des paquets"
maybe $SUDO apt-get update -qq
maybe env DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y \
  apache2 mysql-server php libapache2-mod-php php-mysql php-cli

# =====================================================================
section "Fuseau horaire et services"
# =====================================================================
act "fuseau système : $TZ_WANTED"
maybe $SUDO timedatectl set-timezone "$TZ_WANTED"
# date.timezone dans les php.ini
for ini in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini; do
  [ -f "$ini" ] || continue
  if grep -qE '^[[:space:]]*;?[[:space:]]*date.timezone' "$ini"; then
    maybe $SUDO sed -i "s#^[[:space:]]*;\?[[:space:]]*date.timezone.*#date.timezone = ${TZ_WANTED}#" "$ini"
  else
    maybe $SUDO sh -c "printf '\n[Date]\ndate.timezone = %s\n' '$TZ_WANTED' >> '$ini'"
  fi
done
act "activation du module PHP d'Apache + services au démarrage"
if have php && have a2enmod; then
  PHP_MM="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
  [ -f "/etc/apache2/mods-available/php${PHP_MM}.load" ] && maybe $SUDO a2enmod "php${PHP_MM}"
fi
maybe $SUDO systemctl enable --now apache2
for svc in mysql mariadb; do
  systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" && { maybe $SUDO systemctl enable --now "$svc"; DB_SVC="$svc"; break; }
done

# ---- accès admin MySQL ----
ADMIN_MYSQL=""
if have mysql; then
  if $SUDO mysql -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="$SUDO mysql"
  elif mysql -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="mysql"
  elif [ -n "$DB_ROOT_PASS" ] && mysql -u root -p"$DB_ROOT_PASS" -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="mysql -u root -p$DB_ROOT_PASS"
  fi
fi
[ "$DRY_RUN" = 1 ] && ADMIN_MYSQL="${ADMIN_MYSQL:-mysql}"
[ -z "$ADMIN_MYSQL" ] && { errm "pas d'accès admin MySQL — relance avec sudo ou DB_ROOT_PASS=…"; }

# =====================================================================
section "Sécurisation minimale de MySQL"
# =====================================================================
if [ -n "$ADMIN_MYSQL" ]; then
  act "suppression des comptes anonymes et de la base de test"
  cat <<'SQL' | apply_sql
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db LIKE 'test\\_%';
FLUSH PRIVILEGES;
SQL
  if [ -n "$DB_ROOT_PASS" ]; then
    act "définition du mot de passe root"
    printf "ALTER USER 'root'@'localhost' IDENTIFIED BY '%s';\nFLUSH PRIVILEGES;\n" "$DB_ROOT_PASS" | apply_sql
  else
    keep "root laissé en authentification socket (défaut Ubuntu) — ok en local"
  fi
fi

# ---- mot de passe applicatif ----
if [ -z "$DB_APP_PASS" ] && [ -r "$DOCROOT/config.php" ]; then
  DB_APP_PASS="$($SUDO grep -oE "DB_PASS[[:space:]]*=[[:space:]]*['\"][^'\"]+" "$DOCROOT/config.php" 2>/dev/null | sed -E "s/.*['\"]//" | head -1)"
fi
if [ -z "$DB_APP_PASS" ]; then
  if have openssl; then DB_APP_PASS="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)"; else DB_APP_PASS="Iot$(date +%s | tail -c6)!"; fi
  GEN_PASS=1
else GEN_PASS=0; fi

# =====================================================================
section "Base « $DB_NAME », tables et compte « $DB_APP_USER »"
# =====================================================================
if [ -n "$ADMIN_MYSQL" ]; then
  act "création de la base, des tables et du compte applicatif (SELECT/INSERT)"
  # si le repo fournit sql/schema.sql, on l'utilise ; sinon schéma intégré
  if [ -f "$SCRIPT_DIR/sql/schema.sql" ] && [ "$DRY_RUN" != 1 ]; then
    keep "import de sql/schema.sql"
    $ADMIN_MYSQL < "$SCRIPT_DIR/sql/schema.sql" 2>/dev/null
  else
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
SQL
  fi
  # compte applicatif (toujours, avec le mot de passe retenu)
  cat <<SQL | apply_sql
CREATE USER IF NOT EXISTS '$DB_APP_USER'@'localhost' IDENTIFIED BY '$DB_APP_PASS';
ALTER USER '$DB_APP_USER'@'localhost' IDENTIFIED BY '$DB_APP_PASS';
GRANT SELECT, INSERT ON \`$DB_NAME\`.* TO '$DB_APP_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  # données de test
  if [ "$SEED" = 1 ]; then
    act "insertion de quelques mesures de TEST"
    cat <<SQL | apply_sql
USE \`$DB_NAME\`;
INSERT IGNORE INTO capteurs (code,emplacement) VALUES ('m5-01','Salle serveur');
INSERT INTO mesures (capteur,type,valeur) VALUES
 ('m5-01','temperature',23.5),
 ('m5-01','humidite',48),
 ('m5-01','co2',640);
SQL
  fi
fi

# =====================================================================
section "Dashboard et VirtualHost Apache"
# =====================================================================
act "préparation de $DOCROOT"
maybe $SUDO mkdir -p "$DOCROOT"

if [ -d "$SCRIPT_DIR/dashboard" ]; then
  keep "déploiement du dossier dashboard/ du repo"
  maybe $SUDO cp -r "$SCRIPT_DIR/dashboard/." "$DOCROOT/"
else
  keep "génération d'un dashboard minimal fonctionnel"
  # data.php : endpoint JSON (pas de variable shell -> heredoc protégé)
  write_file "$DOCROOT/data.php" <<'PHP'
<?php
require __DIR__ . '/config.php';
header('Content-Type: application/json');
echo json_encode(
  $pdo->query("SELECT date_mesure, capteur, type, valeur
               FROM mesures ORDER BY id DESC LIMIT 50")
      ->fetchAll(PDO::FETCH_ASSOC)
);
PHP
  # index.php : page auto-rafraîchie, rendue côté serveur (aucune dépendance externe)
  write_file "$DOCROOT/index.php" <<'PHP'
<?php require __DIR__ . '/config.php';
$rows = $pdo->query("SELECT capteur,type,valeur,date_mesure
                     FROM mesures ORDER BY id DESC LIMIT 50")
            ->fetchAll(PDO::FETCH_ASSOC); ?>
<!doctype html><html lang="fr"><head>
<meta charset="utf-8"><meta http-equiv="refresh" content="5">
<title>Supervision IoT</title>
<style>
 body{font-family:system-ui,sans-serif;margin:2rem;background:#0d1117;color:#e6edf3}
 h1{font-weight:600} .muted{color:#8b949e}
 table{border-collapse:collapse;width:100%;margin-top:1rem}
 th,td{border:1px solid #30363d;padding:.45rem .7rem;text-align:left}
 th{background:#161b22} tr:hover td{background:#161b22}
</style></head><body>
<h1>Supervision IoT <span class="muted">— dernières mesures</span></h1>
<p class="muted">Actualisation automatique toutes les 5 s · <?= count($rows) ?> ligne(s)</p>
<table>
 <tr><th>Capteur</th><th>Type</th><th>Valeur</th><th>Horodatage</th></tr>
 <?php foreach ($rows as $r): ?>
 <tr>
   <td><?= htmlspecialchars($r['capteur']) ?></td>
   <td><?= htmlspecialchars($r['type']) ?></td>
   <td><?= htmlspecialchars($r['valeur']) ?></td>
   <td><?= htmlspecialchars($r['date_mesure']) ?></td>
 </tr>
 <?php endforeach; ?>
</table>
</body></html>
PHP
fi

# config.php : créé s'il manque, ou réécrit si un mot de passe a été fourni explicitement
if [ ! -f "$DOCROOT/config.php" ] || [ "$PWD_SET" = 1 ] || [ "$DRY_RUN" = 1 ]; then
  act "écriture de config.php (connexion PDO)"
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
  [ "$GEN_PASS" = 1 ] && note "mot de passe applicatif généré : ${BOLD}$DB_APP_PASS${N}  (enregistré dans $DOCROOT/config.php)"
else
  keep "config.php déjà présent — conservé"
fi

act "droits : propriétaire www-data, config.php en 640"
maybe $SUDO chown -R www-data:www-data "$DOCROOT"
[ -f "$DOCROOT/config.php" ] && { maybe $SUDO chown root:www-data "$DOCROOT/config.php"; maybe $SUDO chmod 640 "$DOCROOT/config.php"; }

act "VirtualHost Apache ($SERVER_NAME)"
write_file "/etc/apache2/sites-available/dashboard.conf" <<APACHE
<VirtualHost *:80>
    ServerName $SERVER_NAME
    DocumentRoot $DOCROOT
    <Directory $DOCROOT>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/dashboard_error.log
</VirtualHost>
APACHE
maybe $SUDO a2ensite dashboard.conf
grep -q "$SERVER_NAME" /etc/hosts 2>/dev/null || maybe $SUDO sh -c "echo '127.0.0.1   $SERVER_NAME' >> /etc/hosts"
maybe $SUDO systemctl reload apache2

# =====================================================================
section "Vérification finale"
# =====================================================================
if [ "$ERRN" -ne 0 ]; then echo "  ${R}Des erreurs sont survenues (voir ci-dessus).${N}"; fi
if [ "$DRY_RUN" = 1 ]; then
  echo "  ${Y}Simulation terminée — relance sans --dry-run pour installer.${N}"
else
  echo "  ${G}Installation terminée.${N}"
  echo "  Accès dashboard :  ${B}http://$SERVER_NAME/${N}  (ou http://localhost/ selon la conf)"
  AUD="$SCRIPT_DIR/04-audit-bdd-php.sh"
  if [ -f "$AUD" ]; then
    echo "  -> audit de contrôle :"; echo
    NO_REPORT=1 NO_PAUSE=1 NO_RECAP=1 DB_APP_PASS="$DB_APP_PASS" PROBE_URL="http://localhost/index.php" bash "$AUD" || true
  else
    echo "  -> lance  sudo bash 04-audit-bdd-php.sh  pour confirmer."
  fi
fi
# =====================================================================
section "Récapitulatif (à noter / pour la suite)"
# =====================================================================
SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; SRV_IP="${SRV_IP:-IP_DU_SERVEUR}"
SRV_USER="${SUDO_USER:-${USER:-utilisateur}}"
echo "  Base de données   : $DB_NAME"
echo "  Utilisateur BDD   : $DB_APP_USER"
echo "  Mot de passe BDD  : ${DB_APP_PASS:-<voir $DOCROOT/config.php>}"
echo "  Dossier du site   : $DOCROOT"
echo "  Fichier de conf   : $DOCROOT/config.php"
echo "  VirtualHost       : /etc/apache2/sites-available/dashboard.conf"
echo "  Logs Apache       : /var/log/apache2/error.log"
echo "  URL du dashboard  : http://$SERVER_NAME/   (ou http://$SRV_IP/)"
echo
echo "  ${BOLD}Transférer le site depuis TON PC (commandes scp) :${N}"
echo "    # 1) sur ton PC, dans le dossier qui contient 'dashboard/' :"
echo "    scp -r dashboard ${SRV_USER}@${SRV_IP}:/tmp/"
echo "    # 2) puis ICI, sur le serveur, déposer au bon endroit :"
echo "    sudo cp -r /tmp/dashboard/* $DOCROOT/ && sudo chown -R www-data:www-data $DOCROOT"
echo "    # un seul fichier (ex. index.php) :"
echo "    scp index.php ${SRV_USER}@${SRV_IP}:/tmp/ && sudo mv /tmp/index.php $DOCROOT/"
echo "    # envoyer tout le repo (scripts) :"
echo "    scp -r Supervision-IoT ${SRV_USER}@${SRV_IP}:~/"

echo
[ "$NO_REPORT" != 1 ] && echo "  ${DIM}Rapport enregistré dans : $REPORT${N}"
if [ "$NO_PAUSE" != 1 ] && [ "$_TTY" = 1 ]; then
  printf "  Appuie sur Entrée pour fermer… "; read -r _
fi
[ "$NO_REPORT" != 1 ] && sleep 0.2
exit $([ "$ERRN" -eq 0 ] && echo 0 || echo 1)
