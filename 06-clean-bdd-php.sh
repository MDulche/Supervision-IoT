#!/usr/bin/env bash
#
# 06-clean-bdd-php.sh
# -----------------------------------------------------------------------------
# Nettoyage / réinitialisation de la partie BASE DE DONNÉES + PHP + DASHBOARD
# (Apache, MySQL, PHP). C'est le pendant "désinstallation" de 03-install-bdd-php.sh.
#
# DEUX NIVEAUX :
#   - par défaut : retire les ARTÉFACTS DU PROJET
#       dashboard (/var/www/dashboard), VirtualHost, entrée /etc/hosts,
#       base "supervision" + compte applicatif "iot_app".
#       => Apache / MySQL / PHP restent installés.
#   - --purge   : DÉSINSTALLE en plus Apache, PHP et MySQL et SUPPRIME
#       toutes leurs données/configs. /!\ touche TOUTE la machine
#       (toutes les bases, tous les sites), pas seulement le projet.
#
# DESTRUCTIF -> à lancer avec sudo. Essaie --dry-run d'abord.
#
#   Usage :
#     sudo bash 06-clean-bdd-php.sh --dry-run     # montre ce qui serait fait
#     sudo bash 06-clean-bdd-php.sh               # nettoyage projet (confirmation)
#     sudo bash 06-clean-bdd-php.sh --keep-db     # garde la base et le compte
#     sudo bash 06-clean-bdd-php.sh --purge       # + désinstalle Apache/PHP/MySQL
#
#   Options : --dry-run  --yes  --keep-db  --purge  --no-report  --no-pause
#   Paramètres (env) : DB_NAME, DB_APP_USER, DB_HOST, DB_ROOT_PASS, DOCROOT, SERVER_NAME
# -----------------------------------------------------------------------------
set -u

# ============================ PARAMÈTRES ====================================
DB_NAME="${DB_NAME:-supervision}"
DB_APP_USER="${DB_APP_USER:-iot_app}"
DB_HOST="${DB_HOST:-localhost}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"
DOCROOT="${DOCROOT:-/var/www/dashboard}"
SERVER_NAME="${SERVER_NAME:-www.dashboard.local}"

DRY_RUN="${DRY_RUN:-0}"; ASSUME_YES="${ASSUME_YES:-0}"; PURGE="${PURGE:-0}"
KEEP_DB="${KEEP_DB:-0}"; NO_REPORT="${NO_REPORT:-0}"; NO_PAUSE="${NO_PAUSE:-0}"
# ============================================================================

for a in "$@"; do case "$a" in
  --dry-run) DRY_RUN=1 ;; --yes|-y) ASSUME_YES=1 ;; --purge) PURGE=1 ;;
  --keep-db) KEEP_DB=1 ;; --no-report) NO_REPORT=1 ;; --no-pause) NO_PAUSE=1 ;;
  -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
  *) echo "Option inconnue : $a"; exit 2 ;;
esac; done

# ---- rapport + couleurs ----
REPORT="${REPORT:-rapport-clean-$(date +%Y%m%d-%H%M%S).txt}"
[ -t 1 ] && _TTY=1 || _TTY=0
if [ "$NO_REPORT" != 1 ]; then exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$REPORT")) 2>&1; fi
if [ "$_TTY" = 1 ]; then R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';B=$'\e[36m';BOLD=$'\e[1m';DIM=$'\e[2m';N=$'\e[0m';
else R="";G="";Y="";B="";BOLD="";DIM="";N=""; fi

DONE=0; KEPT=0; ERRN=0
section(){ echo; echo "${BOLD}== $1 ==${N}"; }
act(){ echo "  ${G}->${N} $1"; DONE=$((DONE+1)); }
keep(){ echo "  ${DIM}   $1${N}"; KEPT=$((KEPT+1)); }
errm(){ echo "  ${R}[ERR]${N} $1"; ERRN=$((ERRN+1)); }
note(){ echo "  ${Y}[note]${N} $1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
maybe(){ if [ "$DRY_RUN" = 1 ]; then printf '       %s$ %s%s\n' "$DIM" "$*" "$N"; else "$@"; fi; }
apply_sql(){ if [ "$DRY_RUN" = 1 ]; then sed 's/^/       | /'; else $ADMIN_MYSQL 2>/dev/null; fi; }

# ---- GARDE-FOU sur DOCROOT (ne jamais supprimer un dossier système) ----
case "$DOCROOT" in
  ""|"/"|"/var"|"/var/www"|"/etc"|"/home"|"/root"|"/usr"|"/boot")
    echo "${R}STOP : DOCROOT='$DOCROOT' est un emplacement dangereux. Abandon.${N}"; exit 2 ;;
esac

echo "${BOLD}Nettoyage BDD + PHP + dashboard${N}"
[ "$DRY_RUN" = 1 ] && echo "${Y}MODE SIMULATION (--dry-run) : rien ne sera supprimé.${N}"
echo "${DIM}base=$DB_NAME  user=$DB_APP_USER  docroot=$DOCROOT  purge=$PURGE  keep-db=$KEEP_DB${N}"
echo
echo "  Sera supprimé : dashboard ($DOCROOT), VirtualHost, entrée /etc/hosts"
[ "$KEEP_DB" = 1 ] && echo "  Base & compte : CONSERVÉS (--keep-db)" || echo "  Base & compte : base '$DB_NAME' + user '$DB_APP_USER' SUPPRIMÉS"
[ "$PURGE" = 1 ] && echo "  ${R}PURGE : Apache, PHP et MySQL DÉSINSTALLÉS (toutes bases/sites de la machine !)${N}"

if [ "$DRY_RUN" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
  printf "Continuer le nettoyage ? [y/N] "; read -r rep
  case "$rep" in y|Y|o|O) ;; *) echo "Annulé."; exit 0 ;; esac
  if [ "$PURGE" = 1 ]; then
    echo "${R}${BOLD}/!\\ --purge va DESINSTALLER Apache/PHP/MySQL et EFFACER TOUTES les bases de la machine.${N}"
    printf "Pour confirmer, tape exactement  SUPPRIMER  : "; read -r conf
    [ "$conf" = "SUPPRIMER" ] || { echo "Confirmation incorrecte. Abandon."; exit 0; }
  fi
fi

# ---- accès admin MySQL ----
ADMIN_MYSQL=""
if have mysql; then
  if mysql -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="mysql"
  elif $SUDO mysql -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="$SUDO mysql"
  elif [ -n "$DB_ROOT_PASS" ] && mysql -u root -p"$DB_ROOT_PASS" -e 'SELECT 1' >/dev/null 2>&1; then ADMIN_MYSQL="mysql -u root -p$DB_ROOT_PASS"
  fi
fi
[ "$DRY_RUN" = 1 ] && ADMIN_MYSQL="${ADMIN_MYSQL:-mysql}"

# =====================================================================
section "1. Site web (VirtualHost et fichiers)"
# =====================================================================
VHOST="/etc/apache2/sites-available/dashboard.conf"
if [ -f "$VHOST" ] || [ "$DRY_RUN" = 1 ]; then
  act "désactivation et suppression du VirtualHost dashboard.conf"
  have a2dissite && maybe $SUDO a2dissite dashboard.conf
  maybe $SUDO rm -f "$VHOST"
  if [ "$PURGE" != 1 ] && [ -f /etc/apache2/sites-available/000-default.conf ]; then
    maybe $SUDO a2ensite 000-default.conf
  fi
else keep "aucun VirtualHost dashboard.conf"; fi

if [ -d "$DOCROOT" ] || [ "$DRY_RUN" = 1 ]; then
  act "suppression du dossier du site : $DOCROOT"
  maybe $SUDO rm -rf "$DOCROOT"
else keep "dossier $DOCROOT déjà absent"; fi

if [ -f /etc/apache2/ssl/site.crt ] || [ -f /etc/apache2/ssl/site.key ]; then
  act "suppression du certificat auto-signé /etc/apache2/ssl/site.*"
  maybe $SUDO rm -f /etc/apache2/ssl/site.crt /etc/apache2/ssl/site.key
fi

if have apache2 && [ "$PURGE" != 1 ]; then
  act "rechargement d'Apache"
  maybe $SUDO systemctl reload apache2
fi

# =====================================================================
section "2. Entrée /etc/hosts"
# =====================================================================
if grep -q "$SERVER_NAME" /etc/hosts 2>/dev/null || [ "$DRY_RUN" = 1 ]; then
  act "retrait de la ligne « $SERVER_NAME » dans /etc/hosts"
  maybe $SUDO sed -i "/[[:space:]]$SERVER_NAME\$/d;/[[:space:]]$SERVER_NAME[[:space:]]/d" /etc/hosts
else keep "aucune entrée $SERVER_NAME dans /etc/hosts"; fi

# =====================================================================
section "3. Base de données et compte applicatif"
# =====================================================================
if [ "$KEEP_DB" = 1 ]; then
  keep "base « $DB_NAME » et compte « $DB_APP_USER » conservés (--keep-db)"
elif [ -n "$ADMIN_MYSQL" ]; then
  act "suppression de la base « $DB_NAME » et du compte « $DB_APP_USER »"
  cat <<SQL | apply_sql
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_APP_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
else
  errm "pas d'accès admin MySQL : base/compte non supprimés."
  note "relance avec sudo, ou DB_ROOT_PASS=…, ou ajoute --keep-db"
fi

# =====================================================================
section "4. Désinstallation des paquets (option --purge)"
# =====================================================================
if [ "$PURGE" = 1 ]; then
  act "arrêt des services"
  for svc in apache2 mysql mariadb; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" && maybe $SUDO systemctl stop "$svc"
  done
  act "purge d'Apache, PHP et MySQL/MariaDB"
  maybe env DEBIAN_FRONTEND=noninteractive $SUDO apt-get purge -y \
    'apache2*' 'libapache2-mod-php*' 'php*' 'mysql-server*' 'mysql-client*' 'mysql-common' 'mariadb-server*' 2>/dev/null
  act "autoremove + nettoyage du cache apt"
  maybe $SUDO apt-get autoremove --purge -y
  maybe $SUDO apt-get clean
  act "suppression des dossiers résiduels (configs, données, logs)"
  for d in /etc/apache2 /var/log/apache2 /etc/php /etc/mysql /var/lib/mysql /var/log/mysql; do
    maybe $SUDO rm -rf "$d"
  done
  note "le dossier /var/www/html n'est PAS supprimé (laissé tel quel)."
else
  keep "paquets Apache/PHP/MySQL conservés (utilise --purge pour les désinstaller)"
fi

# =====================================================================
section "Bilan"
# =====================================================================
echo "  ${G}supprimés : $DONE${N}    ${DIM}déjà absents/conservés : $KEPT${N}    ${R}erreurs : $ERRN${N}"
if [ "$DRY_RUN" = 1 ]; then
  echo "  ${Y}Simulation terminée — relance sans --dry-run pour nettoyer.${N}"
else
  echo "  ${G}Nettoyage terminé.${N}"
  if [ "$PURGE" = 1 ]; then
    echo "  Apache/PHP/MySQL désinstallés. Pour tout réinstaller : ${B}sudo bash 03-install-bdd-php.sh${N}"
  else
    echo "  La pile LAMP est toujours là. Pour repartir d'une base propre : ${B}sudo bash 03-install-bdd-php.sh${N}"
  fi
fi
echo
[ "$NO_REPORT" != 1 ] && echo "  ${DIM}Rapport enregistré dans : $REPORT${N}"
if [ "$NO_PAUSE" != 1 ] && [ "$_TTY" = 1 ]; then
  printf "  Appuie sur Entrée pour fermer… "; read -r _
fi
[ "$NO_REPORT" != 1 ] && sleep 0.2
exit $([ "$ERRN" -eq 0 ] && echo 0 || echo 1)
