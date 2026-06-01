#!/usr/bin/env bash
#
# 04-audit-bdd-php.sh
# -----------------------------------------------------------------------------
# Audit (LECTURE SEULE) de la partie BASE DE DONNÉES + PHP + DASHBOARD
# de la chaîne IoT (serveur Linux : MySQL/MariaDB, PHP, Apache, PDO).
#
# Le script NE MODIFIE RIEN : il analyse l'installation et la configuration
# actuelles, teste la connexion de bout en bout et affiche un bilan
# PASS / WARN / FAIL avec des pistes de correction.
#
#   Usage :
#     bash 04-audit-bdd-php.sh
#     sudo bash 04-audit-bdd-php.sh           # recommandé (accès admin MySQL + ports)
#
#   Paramètres par variables d'environnement (sinon valeurs par défaut ci-dessous) :
#     DB_NAME, DB_APP_USER, DB_APP_PASS, DB_HOST, DB_ROOT_PASS,
#     DOCROOT, PROBE_URL
#   Exemple :
#     sudo DB_APP_PASS='MonMotDePasse' PROBE_URL='http://localhost/index.php' \
#          bash 04-audit-bdd-php.sh
# -----------------------------------------------------------------------------

# ============================ PARAMÈTRES ====================================
DB_NAME="${DB_NAME:-supervision}"          # base attendue
DB_APP_USER="${DB_APP_USER:-iot_app}"      # compte applicatif (celui du dashboard)
DB_APP_PASS="${DB_APP_PASS:-}"             # mot de passe du compte applicatif (sinon auto-détecté)
DB_HOST="${DB_HOST:-localhost}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"           # mot de passe root MySQL (optionnel, pour les contrôles admin)

TABLE_REQUIRED="${TABLE_REQUIRED:-mesures}"      # table indispensable
TABLE_OPTIONAL="${TABLE_OPTIONAL:-capteurs}"     # table conseillée (peut ne pas exister)

DOCROOT="${DOCROOT:-/var/www/dashboard}"   # dossier du dashboard
PROBE_URL="${PROBE_URL:-}"                 # ex : http://localhost/index.php (test exécution PHP, optionnel)
# ============================================================================

# ---- couleurs (désactivées si pas un terminal) ----
if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; BOLD=""; DIM=""; N=""
fi

PASS=0; WARN=0; FAILN=0
ok()   { echo "  ${G}[ OK ]${N} $1"; PASS=$((PASS+1)); }
warn() { echo "  ${Y}[WARN]${N} $1"; WARN=$((WARN+1)); }
fail() { echo "  ${R}[FAIL]${N} $1"; FAILN=$((FAILN+1)); }
info() { echo "  ${DIM}     $1${N}"; }
hint() { echo "       ${B}-> $1${N}"; }
section(){ echo; echo "${BOLD}== $1 ==${N}"; }

have(){ command -v "$1" >/dev/null 2>&1; }

echo "${BOLD}Audit BDD + PHP + dashboard${N}  ${DIM}(lecture seule)${N}"
echo "${DIM}Base attendue : $DB_NAME   |   compte applicatif : $DB_APP_USER   |   docroot : $DOCROOT${N}"
[ "$(id -u)" -ne 0 ] && echo "${Y}Astuce : relance avec sudo pour les contrôles admin MySQL et les ports.${N}"

# =====================================================================
section "1. Contexte système"
# =====================================================================
if [ -r /etc/os-release ]; then . /etc/os-release; info "OS : ${PRETTY_NAME:-inconnu}"; fi
info "Hôte : $(hostname)   |   Date : $(date '+%Y-%m-%d %H:%M:%S %Z')"
for t in php mysql ss curl; do have "$t" && info "présent : $t"; done

# =====================================================================
section "2. PHP (interpréteur et extensions)"
# =====================================================================
if have php; then
  PHPVER="$(php -r 'echo PHP_VERSION;' 2>/dev/null)"
  ok "PHP installé (version $PHPVER)"
  # extensions critiques pour un dashboard MySQL
  for ext in pdo_mysql mysqli json; do
    if php -m 2>/dev/null | grep -qi "^${ext}$"; then
      ok "extension PHP présente : $ext"
    else
      if [ "$ext" = "mysqli" ]; then
        warn "extension PHP absente : $ext (facultative si tu utilises PDO)"
      else
        fail "extension PHP absente : $ext"
        hint "sudo apt install php-mysql  puis  sudo systemctl restart apache2"
      fi
    fi
  done
  # fuseau horaire PHP (impacte l'affichage des dates)
  TZPHP="$(php -r 'echo ini_get("date.timezone");' 2>/dev/null)"
  if [ -n "$TZPHP" ]; then ok "fuseau PHP (date.timezone) : $TZPHP"
  else warn "date.timezone non défini dans php.ini (dates possiblement décalées)"
       hint "définir date.timezone = Europe/Paris dans php.ini"
  fi
else
  fail "PHP n'est pas installé"
  hint "sudo apt install php libapache2-mod-php php-mysql"
fi

# =====================================================================
section "3. Serveur web Apache (le dashboard est servi par lui)"
# =====================================================================
if have apache2 || have apachectl || systemctl list-unit-files 2>/dev/null | grep -q '^apache2'; then
  ok "Apache installé"
  if systemctl is-active --quiet apache2; then ok "service apache2 actif"
  else fail "service apache2 inactif"; hint "sudo systemctl start apache2"; fi
  if systemctl is-enabled --quiet apache2 2>/dev/null; then ok "apache2 activé au démarrage"
  else warn "apache2 non activé au démarrage (ne repartira pas après reboot)"; hint "sudo systemctl enable apache2"; fi

  # comment PHP est exécuté sous Apache ?
  if have apache2ctl && apache2ctl -M 2>/dev/null | grep -qiE 'php[0-9_]*_module'; then
    ok "module PHP chargé dans Apache (mod_php)"
  elif apache2ctl -M 2>/dev/null | grep -qi 'proxy_fcgi'; then
    ok "Apache configuré avec php-fpm (proxy_fcgi)"
  else
    warn "aucun module PHP visible dans Apache (mod_php / php-fpm)"
    hint "sinon les .php seront TÉLÉCHARGÉS au lieu d'être exécutés"
    hint "sudo a2enmod php8.*  (ou activer php-fpm)  puis restart apache2"
  fi

  # écoute des ports web
  if have ss; then
    ss -tlnp 2>/dev/null | grep -q ':80 '  && ok "Apache écoute sur le port 80"  || warn "rien n'écoute sur le port 80"
    ss -tlnp 2>/dev/null | grep -q ':443 ' && info "HTTPS actif (port 443)"        || info "port 443 (HTTPS) non actif (facultatif en local)"
  fi
else
  warn "Apache ne semble pas installé (le dashboard a besoin d'un serveur web)"
  hint "sudo apt install apache2 libapache2-mod-php"
fi

# =====================================================================
section "4. Serveur MySQL / MariaDB"
# =====================================================================
DB_PRESENT=0
if systemctl list-unit-files 2>/dev/null | grep -qE '^(mysql|mariadb)\.service'; then DB_PRESENT=1; fi
have mysql && DB_PRESENT=1

if [ "$DB_PRESENT" -eq 1 ]; then
  ok "client/serveur MySQL présent"
  DB_SVC=""
  for svc in mysql mariadb; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then DB_SVC="$svc"; break; fi
  done
  if [ -n "$DB_SVC" ]; then
    if systemctl is-active --quiet "$DB_SVC"; then ok "service $DB_SVC actif"
    else fail "service $DB_SVC inactif"; hint "sudo systemctl start $DB_SVC"; fi
    if systemctl is-enabled --quiet "$DB_SVC" 2>/dev/null; then ok "$DB_SVC activé au démarrage"
    else warn "$DB_SVC non activé au démarrage"; hint "sudo systemctl enable $DB_SVC"; fi
  else
    warn "service mysql/mariadb introuvable via systemd"
  fi
  if have ss; then
    ss -tlnp 2>/dev/null | grep -q ':3306 ' && ok "MySQL écoute sur le port 3306" \
      || warn "rien n'écoute sur 3306 (normal si bind sur socket local uniquement)"
  fi
  if have mysql; then
    MV="$(mysql --version 2>/dev/null | sed 's/^mysql *//')"
    [ -n "$MV" ] && info "version : $MV"
  fi
else
  fail "MySQL/MariaDB introuvable"
  hint "sudo apt install mysql-server"
fi

# ---- établir un accès admin (lecture seule) pour les contrôles fins ----
ADMIN_MYSQL=""        # commande qui marche, ou vide
if have mysql; then
  if mysql -e 'SELECT 1' >/dev/null 2>&1; then
    ADMIN_MYSQL="mysql"
  elif sudo -n mysql -e 'SELECT 1' >/dev/null 2>&1; then
    ADMIN_MYSQL="sudo mysql"
  elif sudo mysql -e 'SELECT 1' >/dev/null 2>&1; then
    ADMIN_MYSQL="sudo mysql"
  elif [ -n "$DB_ROOT_PASS" ] && mysql -u root -p"$DB_ROOT_PASS" -e 'SELECT 1' >/dev/null 2>&1; then
    ADMIN_MYSQL="mysql -u root -p$DB_ROOT_PASS"
  fi
fi

# =====================================================================
section "5. Base de données « $DB_NAME » et tables"
# =====================================================================
if [ -n "$ADMIN_MYSQL" ]; then
  if $ADMIN_MYSQL -N -e "SHOW DATABASES LIKE '$DB_NAME'" 2>/dev/null | grep -q "$DB_NAME"; then
    ok "la base « $DB_NAME » existe"
    # tables
    TABLES="$($ADMIN_MYSQL -N -e "SHOW TABLES" "$DB_NAME" 2>/dev/null)"
    if echo "$TABLES" | grep -qx "$TABLE_REQUIRED"; then
      ok "table requise présente : $TABLE_REQUIRED"
      ROWS="$($ADMIN_MYSQL -N -e "SELECT COUNT(*) FROM \`$TABLE_REQUIRED\`" "$DB_NAME" 2>/dev/null)"
      if [ -n "$ROWS" ] && [ "$ROWS" -gt 0 ] 2>/dev/null; then ok "données présentes dans $TABLE_REQUIRED : $ROWS ligne(s)"
      else warn "la table $TABLE_REQUIRED est VIDE (le dashboard n'affichera rien)"
           hint "vérifie le backend/simulateur qui doit insérer les mesures"; fi
      info "colonnes : $($ADMIN_MYSQL -N -e "SHOW COLUMNS FROM \`$TABLE_REQUIRED\`" "$DB_NAME" 2>/dev/null | awk '{printf "%s ",$1}')"
    else
      fail "table requise ABSENTE : $TABLE_REQUIRED"
      hint "crée la table (CREATE TABLE) ou importe le script SQL du projet"
    fi
    if echo "$TABLES" | grep -qx "$TABLE_OPTIONAL"; then ok "table présente : $TABLE_OPTIONAL"
    else info "table optionnelle absente : $TABLE_OPTIONAL (ok si non utilisée)"; fi
  else
    fail "la base « $DB_NAME » n'existe pas"
    hint "CREATE DATABASE $DB_NAME;  puis importer/créer les tables"
  fi
else
  warn "contrôles admin MySQL ignorés (pas d'accès root)."
  hint "relance avec sudo, ou passe DB_ROOT_PASS=... pour vérifier base, tables et droits"
fi

# =====================================================================
section "6. Compte applicatif « $DB_APP_USER »"
# =====================================================================
if [ -n "$ADMIN_MYSQL" ]; then
  UEXIST="$($ADMIN_MYSQL -N -e "SELECT COUNT(*) FROM mysql.user WHERE user='$DB_APP_USER'" 2>/dev/null)"
  if [ "$UEXIST" = "0" ] || [ -z "$UEXIST" ]; then
    fail "le compte MySQL « $DB_APP_USER » n'existe pas"
    hint "CREATE USER '$DB_APP_USER'@'localhost' IDENTIFIED BY '...';"
  else
    ok "le compte « $DB_APP_USER » existe"
    GRANTS="$($ADMIN_MYSQL -N -e "SHOW GRANTS FOR '$DB_APP_USER'@'localhost'" 2>/dev/null)"
    if [ -z "$GRANTS" ]; then
      info "compte présent mais pas en @localhost (ou hôte différent) ; vérifie l'hôte"
    else
      echo "$GRANTS" | grep -qiE 'SELECT|ALL PRIVILEGES' && ok "droit SELECT sur la base : présent" \
        || { fail "le compte n'a pas le droit SELECT sur $DB_NAME"; hint "GRANT SELECT ON $DB_NAME.* TO '$DB_APP_USER'@'localhost';"; }
      echo "$GRANTS" | grep -qiE 'INSERT|ALL PRIVILEGES' && ok "droit INSERT : présent (utile si PHP écrit aussi)" \
        || info "pas de droit INSERT (ok si le dashboard ne fait que lire)"
      echo "$GRANTS" | grep -qi 'ALL PRIVILEGES' && warn "le compte a ALL PRIVILEGES (trop large : préfère SELECT/INSERT — moindre privilège)"
    fi
  fi
else
  info "vérification des droits ignorée (pas d'accès admin)."
fi

# =====================================================================
section "7. Connexion PDO de bout en bout (le vrai chemin du dashboard)"
# =====================================================================
# Tente de récupérer les identifiants réellement utilisés par le dashboard,
# si le mot de passe applicatif n'a pas été fourni.
CFG=""
for f in "$DOCROOT/config.php" "$DOCROOT/inc/config.php" "$DOCROOT/includes/config.php"; do
  [ -r "$f" ] && CFG="$f" && break
done
if [ -z "$DB_APP_PASS" ] && [ -n "$CFG" ]; then
  info "lecture des identifiants depuis $CFG"
  P="$(grep -oE "new[[:space:]]+PDO\([^)]*" "$CFG" 2>/dev/null | head -1)"
  # extraction best-effort des chaînes entre quotes après le DSN
  CREDS="$(grep -oE "['\"][^'\"]+['\"]" "$CFG" 2>/dev/null | sed "s/['\"]//g")"
  GUESS_USER="$(echo "$CREDS" | grep -i -m1 -E '^iot|app|user' )"
  [ -n "$GUESS_USER" ] && DB_APP_USER="$GUESS_USER"
fi

if have php; then
  PROBE=/tmp/_pdo_probe_$$.php
  cat > "$PROBE" <<PHP
<?php
\$host = getenv('DB_HOST'); \$db = getenv('DB_NAME');
\$u = getenv('DB_APP_USER'); \$p = getenv('DB_APP_PASS'); \$t = getenv('TABLE_REQUIRED');
try {
  \$pdo = new PDO("mysql:host=\$host;dbname=\$db", \$u, \$p,
                 [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
  \$n = \$pdo->query("SELECT COUNT(*) FROM \`\$t\`")->fetchColumn();
  echo "OK rows=\$n";
} catch (Throwable \$e) {
  echo "ERR ".\$e->getMessage();
  exit(1);
}
PHP
  if [ -z "$DB_APP_PASS" ]; then
    warn "mot de passe applicatif inconnu : test PDO lancé sans mot de passe (échouera si un mot de passe est requis)"
    hint "relance avec  DB_APP_PASS='...'  (ou renseigne-le dans config.php)"
  fi
  OUT="$(DB_HOST="$DB_HOST" DB_NAME="$DB_NAME" DB_APP_USER="$DB_APP_USER" DB_APP_PASS="$DB_APP_PASS" TABLE_REQUIRED="$TABLE_REQUIRED" php "$PROBE" 2>&1)"
  RC=$?
  rm -f "$PROBE"
  if [ $RC -eq 0 ] && echo "$OUT" | grep -q '^OK'; then
    ok "connexion PDO réussie + lecture de $TABLE_REQUIRED ($(echo "$OUT" | sed 's/OK //'))"
  else
    fail "connexion PDO échouée"
    info "message : $(echo "$OUT" | sed 's/^ERR //' | cut -c1-160)"
    case "$OUT" in
      *"could not find driver"*) hint "extension manquante : sudo apt install php-mysql ; restart apache2" ;;
      *"Access denied"*)         hint "identifiants faux ou droits insuffisants pour $DB_APP_USER" ;;
      *"Unknown database"*)      hint "la base $DB_NAME n'existe pas" ;;
      *"Connection refused"*)    hint "MySQL n'écoute pas / mauvais host ; vérifie le service et le port" ;;
      *"Base table"*|*"doesn't exist"*) hint "la table $TABLE_REQUIRED est absente" ;;
    esac
  fi
else
  warn "PHP absent : test PDO impossible"
fi

# =====================================================================
section "8. Fichiers du dashboard"
# =====================================================================
if [ -d "$DOCROOT" ]; then
  ok "dossier du dashboard présent : $DOCROOT"
  NPHP="$(find "$DOCROOT" -maxdepth 2 -name '*.php' 2>/dev/null | wc -l)"
  [ "$NPHP" -gt 0 ] && ok "fichiers PHP trouvés : $NPHP" || warn "aucun fichier .php dans $DOCROOT"
  [ -n "$CFG" ] && ok "fichier de configuration trouvé : $CFG" || info "pas de config.php repéré (identifiants peut-être en dur dans les pages)"
  OWNER="$(stat -c '%U:%G' "$DOCROOT" 2>/dev/null)"
  info "propriétaire de $DOCROOT : $OWNER"
  echo "$OWNER" | grep -q 'www-data' || warn "le dossier n'appartient pas à www-data (risque d'erreur 403)"
  # secrets en clair lisibles par tous ?
  if [ -n "$CFG" ]; then
    PERM="$(stat -c '%a' "$CFG" 2>/dev/null)"
    case "$PERM" in
      *[0-9][4-7][4-7]|*[0-9][0-9][1-7]) warn "config.php ($PERM) lisible largement : contient peut-être un mot de passe"; hint "sudo chmod 640 $CFG ; chown root:www-data $CFG" ;;
    esac
  fi
else
  warn "dossier du dashboard introuvable : $DOCROOT"
  hint "ajuste la variable DOCROOT au début du script si besoin"
fi

# ---- test optionnel : la page PHP s'exécute-t-elle (pas téléchargée) ? ----
if [ -n "$PROBE_URL" ]; then
  if have curl; then
    CT="$(curl -s -o /dev/null -D - "$PROBE_URL" 2>/dev/null | grep -i '^content-type:' | tr -d '\r')"
    CODE="$(curl -s -o /dev/null -w '%{http_code}' "$PROBE_URL" 2>/dev/null)"
    info "GET $PROBE_URL -> HTTP $CODE   $CT"
    if echo "$CT" | grep -qi 'x-httpd-php\|application/octet-stream'; then
      fail "la page est renvoyée comme un fichier (PHP non exécuté !)"
      hint "active le module PHP d'Apache (mod_php / php-fpm) puis restart"
    elif [ "$CODE" = "200" ]; then ok "la page répond en HTTP 200 (PHP exécuté)"
    elif [ "$CODE" = "403" ]; then fail "HTTP 403 : droits du dossier ou directive Require trop restrictive"
    elif [ "$CODE" = "500" ]; then fail "HTTP 500 : erreur PHP — regarde /var/log/apache2/error.log"
    else warn "code HTTP inattendu : $CODE"; fi
  else
    info "curl absent : test d'exécution de la page ignoré"
  fi
else
  info "PROBE_URL non défini : test d'exécution de la page web ignoré (optionnel)"
  hint "pour le faire : PROBE_URL='http://localhost/index.php' sudo -E bash $0"
fi

# =====================================================================
section "Bilan"
# =====================================================================
echo "  ${G}PASS : $PASS${N}    ${Y}WARN : $WARN${N}    ${R}FAIL : $FAILN${N}"
if [ "$FAILN" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo "  ${G}${BOLD}Tout est en ordre côté BDD + PHP.${N}"
elif [ "$FAILN" -eq 0 ]; then
  echo "  ${Y}${BOLD}Fonctionnel, mais quelques points à surveiller (voir WARN).${N}"
else
  echo "  ${R}${BOLD}Des problèmes bloquants restent à corriger (voir FAIL).${N}"
fi
echo
exit $([ "$FAILN" -eq 0 ] && echo 0 || echo 1)
