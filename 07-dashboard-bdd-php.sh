#!/usr/bin/env bash
#
# 07-dashboard-bdd-php.sh
# -----------------------------------------------------------------------------
# Générateur de DASHBOARD PHP sur mesure.
# Demande quelles valeurs (capteurs) afficher, quelques options, puis GÉNÈRE
# les fichiers PHP (config.php, sensors.php, index.php, data.php) et les met
# EN PLACE dans Apache (dossier + VirtualHost) — prêt à l'emploi.
#
# Le dashboard lit la table `mesures` (colonnes : capteur, type, valeur, date_mesure)
# et affiche, pour chaque type choisi, la dernière valeur + un historique récent,
# avec un graphique optionnel.
#
# À lancer avec sudo. Essaie --dry-run pour prévisualiser sans rien écrire.
#
#   Usage :
#     sudo bash 07-dashboard-bdd-php.sh                 # mode interactif (questions)
#     sudo bash 07-dashboard-bdd-php.sh --dry-run       # montre la config, n'écrit rien
#     # non interactif :
#     sudo SENSORS="temperature humidite co2" TITLE="Salle serveur" CHART=temperature \
#          bash 07-dashboard-bdd-php.sh --yes
#
#   Options : --yes  --dry-run  --no-report  --no-pause
#   Paramètres (env) : SENSORS, TITLE, REFRESH, ROWS, CHART,
#                      DOCROOT, SERVER_NAME, DB_NAME, DB_APP_USER, DB_APP_PASS, DB_HOST
# -----------------------------------------------------------------------------
set -u

# ============================ PARAMÈTRES ====================================
DB_NAME="${DB_NAME:-supervision}"
DB_APP_USER="${DB_APP_USER:-iot_app}"
DB_APP_PASS="${DB_APP_PASS:-}"
DB_HOST="${DB_HOST:-localhost}"
DOCROOT="${DOCROOT:-/var/www/dashboard}"
SERVER_NAME="${SERVER_NAME:-www.dashboard.local}"

TITLE="${TITLE:-Supervision IoT}"
REFRESH="${REFRESH:-5}"
ROWS="${ROWS:-20}"
CHART="${CHART:-}"
SENSORS="${SENSORS:-}"           # liste de types pré-sélectionnés (sinon questions)

DRY_RUN="${DRY_RUN:-0}"; ASSUME_YES="${ASSUME_YES:-0}"; NO_REPORT="${NO_REPORT:-0}"; NO_PAUSE="${NO_PAUSE:-0}"
# ============================================================================

for a in "$@"; do case "$a" in
  --dry-run) DRY_RUN=1 ;; --yes|-y) ASSUME_YES=1 ;; --no-report) NO_REPORT=1 ;; --no-pause) NO_PAUSE=1 ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
  *) echo "Option inconnue : $a"; exit 2 ;;
esac; done

REPORT="${REPORT:-rapport-dashboard-$(date +%Y%m%d-%H%M%S).txt}"
[ -t 1 ] && _TTY=1 || _TTY=0
if [ "$NO_REPORT" != 1 ]; then exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$REPORT")) 2>&1; fi
if [ "$_TTY" = 1 ]; then R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';B=$'\e[36m';BOLD=$'\e[1m';DIM=$'\e[2m';N=$'\e[0m';
else R="";G="";Y="";B="";BOLD="";DIM="";N=""; fi

ERRN=0
section(){ echo; echo "${BOLD}== $1 ==${N}"; }
act(){ echo "  ${G}->${N} $1"; }
note(){ echo "  ${Y}[note]${N} $1"; }
have(){ command -v "$1" >/dev/null 2>&1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
maybe(){ if [ "$DRY_RUN" = 1 ]; then printf '       %s$ %s%s\n' "$DIM" "$*" "$N"; else "$@"; fi; }
write_file(){ if [ "$DRY_RUN" = 1 ]; then echo "       (écrirait $1)"; cat >/dev/null; else $SUDO tee "$1" >/dev/null; fi; }

# catalogue des capteurs connus :  clé -> "Libellé|unité"
catalog(){ case "$1" in
  temperature) echo "Température|°C";;
  humidite)    echo "Humidité|%";;
  pression)    echo "Pression|hPa";;
  co2)         echo "CO2|ppm";;
  luminosite)  echo "Luminosité|lux";;
  presence)    echo "Présence|bool";;
  *)           echo "$1|";;
esac; }

SENSORS_PHP=""; SENSEL=""
add_sensor(){ # clé libellé unité
  SENSORS_PHP+="  '$1' => ['label' => '$2', 'unit' => '$3'],"$'\n'
  SENSEL="$SENSEL $1"
}

echo "${BOLD}Générateur de dashboard PHP${N}"
[ "$DRY_RUN" = 1 ] && echo "${Y}MODE SIMULATION (--dry-run) : rien ne sera écrit.${N}"

# ---------- sélection des capteurs ----------
if [ -n "$SENSORS" ]; then
  for k in $SENSORS; do ci="$(catalog "$k")"; add_sensor "$k" "${ci%%|*}" "${ci#*|}"; done
elif [ "$ASSUME_YES" = 1 ]; then
  add_sensor temperature "Température" "°C"; add_sensor humidite "Humidité" "%"
else
  section "1. Quels capteurs afficher ?"
  for k in temperature humidite pression co2 luminosite presence; do
    ci="$(catalog "$k")"; lbl="${ci%%|*}"; unit="${ci#*|}"
    printf "  Afficher %s (%s) ? [o/N] " "$lbl" "$unit"; read -r r
    case "$r" in o|O|y|Y) add_sensor "$k" "$lbl" "$unit" ;; esac
  done
  while :; do
    printf "  Ajouter un type personnalisé ? (nom EXACT en base, vide = terminer) : "; read -r ck
    [ -z "$ck" ] && break
    printf "    Libellé affiché : "; read -r cl
    printf "    Unité : "; read -r cu
    add_sensor "$ck" "${cl:-$ck}" "$cu"
  done
fi
# au moins un capteur
[ -z "${SENSEL// /}" ] && { add_sensor temperature "Température" "°C"; add_sensor humidite "Humidité" "%"; }

# ---------- options ----------
if [ "$ASSUME_YES" != 1 ] && [ -z "$SENSORS" ]; then
  section "2. Options d'affichage"
  printf "  Titre de la page [%s] : " "$TITLE"; read -r r; TITLE="${r:-$TITLE}"
  printf "  Rafraîchissement en secondes [%s] : " "$REFRESH"; read -r r; REFRESH="${r:-$REFRESH}"
  printf "  Nombre de lignes récentes [%s] : " "$ROWS"; read -r r; ROWS="${r:-$ROWS}"
  printf "  Graphique d'un type ? (ex: temperature ; vide = aucun) : "; read -r r; CHART="${r:-$CHART}"
fi
# validations / nettoyage
TITLE="${TITLE//\'/}"
case "$REFRESH" in ""|*[!0-9]*) REFRESH=5;; esac
case "$ROWS" in ""|*[!0-9]*) ROWS=20;; esac

# ---------- mot de passe applicatif (pour config.php si absent) ----------
CFG="$DOCROOT/config.php"
if [ -z "$DB_APP_PASS" ] && [ -r "$CFG" ]; then
  DB_APP_PASS="$($SUDO grep -oE "DB_PASS[[:space:]]*=[[:space:]]*['\"][^'\"]+" "$CFG" 2>/dev/null | sed -E "s/.*['\"]//" | head -1)"
fi
GEN_PASS=0
if [ ! -f "$CFG" ] && [ -z "$DB_APP_PASS" ]; then
  if have openssl; then DB_APP_PASS="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)"; else DB_APP_PASS="Iot$(date +%s | tail -c6)!"; fi
  GEN_PASS=1
fi

# ---------- récapitulatif de la config ----------
section "Configuration retenue"
echo "  Titre            : $TITLE"
echo "  Capteurs         :$SENSEL"
echo "  Rafraîchissement : ${REFRESH}s   |   Lignes récentes : $ROWS"
echo "  Graphique        : ${CHART:-aucun}"
echo "  Dossier          : $DOCROOT"
echo "  Fichiers générés : index.php, data.php, sensors.php$( [ -f "$CFG" ] && echo " (config.php conservé)" || echo ", config.php" )"

if [ "$DRY_RUN" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
  printf "Générer et déployer ce dashboard ? [y/N] "; read -r rep
  case "$rep" in y|Y|o|O) ;; *) echo "Annulé."; exit 0 ;; esac
fi

# =====================================================================
section "Génération des fichiers"
# =====================================================================
act "préparation de $DOCROOT"
maybe $SUDO mkdir -p "$DOCROOT"

# --- config.php : créé seulement s'il manque ---
if [ ! -f "$CFG" ] || [ "$DRY_RUN" = 1 ]; then
  act "écriture de config.php (connexion PDO)"
  write_file "$CFG" <<PHP
<?php
\$DB_HOST = '$DB_HOST';
\$DB_NAME = '$DB_NAME';
\$DB_USER = '$DB_APP_USER';
\$DB_PASS = '$DB_APP_PASS';
try {
    \$pdo = new PDO("mysql:host=\$DB_HOST;dbname=\$DB_NAME;charset=utf8mb4",
                   \$DB_USER, \$DB_PASS, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
} catch (PDOException \$e) {
    die('Connexion impossible : ' . \$e->getMessage());
}
PHP
  [ "$GEN_PASS" = 1 ] && note "mot de passe applicatif généré : ${BOLD}$DB_APP_PASS${N} (dans $CFG) — le compte MySQL doit utiliser ce mot de passe."
else
  act "config.php déjà présent — conservé"
fi

# --- sensors.php : la configuration choisie (partie dynamique) ---
act "écriture de sensors.php (capteurs et options choisis)"
write_file "$DOCROOT/sensors.php" <<PHP
<?php
// Généré par 07-dashboard-bdd-php.sh — modifiable à la main si besoin.
\$PAGE_TITLE = '$TITLE';
\$REFRESH    = $REFRESH;
\$ROWS       = $ROWS;
\$CHART_TYPE = '$CHART';
\$SENSORS = [
$SENSORS_PHP];
PHP

# --- data.php : endpoint JSON (statique) ---
act "écriture de data.php (endpoint JSON)"
write_file "$DOCROOT/data.php" <<'PHP'
<?php
require __DIR__ . '/config.php';
header('Content-Type: application/json');
$type  = $_GET['type'] ?? '';
$limit = (int)($_GET['limit'] ?? 50);
if ($limit < 1 || $limit > 500) { $limit = 50; }
if ($type !== '') {
    $st = $pdo->prepare("SELECT date_mesure, valeur FROM mesures WHERE type = ? ORDER BY id DESC LIMIT $limit");
    $st->execute([$type]);
} else {
    $st = $pdo->query("SELECT date_mesure, type, valeur FROM mesures ORDER BY id DESC LIMIT $limit");
}
echo json_encode($st->fetchAll(PDO::FETCH_ASSOC));
PHP

# --- index.php : la page (statique, pilotée par sensors.php) ---
act "écriture de index.php (page du dashboard)"
write_file "$DOCROOT/index.php" <<'PHP'
<?php
require __DIR__ . '/config.php';
require __DIR__ . '/sensors.php';

$types = array_keys($SENSORS);
if (!$types) { $types = ['temperature']; }

function latest($pdo, $type) {
    $st = $pdo->prepare("SELECT valeur, date_mesure FROM mesures WHERE type = ? ORDER BY date_mesure DESC LIMIT 1");
    $st->execute([$type]);
    return $st->fetch(PDO::FETCH_ASSOC);
}

$ph = implode(',', array_fill(0, count($types), '?'));
$st = $pdo->prepare("SELECT capteur, type, valeur, date_mesure FROM mesures WHERE type IN ($ph) ORDER BY id DESC LIMIT " . (int)$ROWS);
$st->execute($types);
$recent = $st->fetchAll(PDO::FETCH_ASSOC);
?>
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="<?= (int)$REFRESH ?>">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?= htmlspecialchars($PAGE_TITLE) ?></title>
  <style>
    body{font-family:system-ui,Segoe UI,Roboto,sans-serif;margin:0;background:#0d1117;color:#e6edf3}
    header{padding:1.4rem 2rem;border-bottom:1px solid #21262d}
    h1{margin:0;font-size:1.4rem} .muted{color:#8b949e;font-size:.9rem}
    main{padding:1.5rem 2rem;max-width:1100px;margin:auto}
    .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:1rem;margin-bottom:1.5rem}
    .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:1rem 1.2rem}
    .card .lbl{color:#8b949e;font-size:.85rem}
    .card .val{font-size:2rem;font-weight:600;margin:.2rem 0}
    .card .unit{font-size:1rem;color:#7ee787}
    .card .ts{color:#5f6975;font-size:.75rem}
    table{border-collapse:collapse;width:100%;font-size:.9rem}
    th,td{border:1px solid #30363d;padding:.45rem .7rem;text-align:left}
    th{background:#161b22} tr:hover td{background:#161b22}
    canvas{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:.5rem;margin-bottom:1.5rem}
  </style>
</head>
<body>
  <header>
    <h1><?= htmlspecialchars($PAGE_TITLE) ?></h1>
    <div class="muted">Actualisation automatique toutes les <?= (int)$REFRESH ?> s · <?= count($recent) ?> mesure(s) affichée(s)</div>
  </header>
  <main>
    <div class="cards">
    <?php foreach ($SENSORS as $key => $s): $row = latest($pdo, $key); ?>
      <div class="card">
        <div class="lbl"><?= htmlspecialchars($s['label']) ?></div>
        <div class="val"><?= $row ? htmlspecialchars($row['valeur']) : '—' ?> <span class="unit"><?= htmlspecialchars($s['unit']) ?></span></div>
        <div class="ts"><?= $row ? htmlspecialchars($row['date_mesure']) : 'aucune donnée' ?></div>
      </div>
    <?php endforeach; ?>
    </div>

    <?php if ($CHART_TYPE !== ''): ?>
    <canvas id="chart" height="110"></canvas>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script>
      fetch('data.php?type=<?= urlencode($CHART_TYPE) ?>&limit=50')
        .then(r => r.json())
        .then(d => {
          d.reverse();
          new Chart(document.getElementById('chart'), {
            type: 'line',
            data: { labels: d.map(x => x.date_mesure),
                    datasets: [{ label: '<?= htmlspecialchars($CHART_TYPE) ?>',
                                 data: d.map(x => x.valeur),
                                 borderColor: '#7ee787', backgroundColor: 'rgba(126,231,135,.15)', tension: .3 }] },
            options: { plugins:{legend:{labels:{color:'#e6edf3'}}},
                       scales:{ x:{ticks:{color:'#8b949e'}}, y:{ticks:{color:'#8b949e'}} } }
          });
        });
    </script>
    <?php endif; ?>

    <h2>Dernières mesures</h2>
    <table>
      <tr><th>Capteur</th><th>Type</th><th>Valeur</th><th>Horodatage</th></tr>
      <?php foreach ($recent as $r): ?>
      <tr>
        <td><?= htmlspecialchars($r['capteur']) ?></td>
        <td><?= htmlspecialchars($r['type']) ?></td>
        <td><?= htmlspecialchars($r['valeur']) ?></td>
        <td><?= htmlspecialchars($r['date_mesure']) ?></td>
      </tr>
      <?php endforeach; ?>
    </table>
  </main>
</body>
</html>
PHP

# --- droits ---
act "droits : propriétaire www-data, config.php en 640"
maybe $SUDO chown -R www-data:www-data "$DOCROOT" 2>/dev/null || true
[ -f "$CFG" ] && { maybe $SUDO chown root:www-data "$CFG"; maybe $SUDO chmod 640 "$CFG"; }

# =====================================================================
section "Mise en place dans Apache"
# =====================================================================
VHOST="/etc/apache2/sites-available/dashboard.conf"
if have apache2 || [ -d /etc/apache2/sites-available ]; then
  if [ ! -f "$VHOST" ]; then
    act "création du VirtualHost ($SERVER_NAME)"
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
  else
    act "VirtualHost déjà présent"
  fi
  grep -q "$SERVER_NAME" /etc/hosts 2>/dev/null || maybe $SUDO sh -c "echo '127.0.0.1   $SERVER_NAME' >> /etc/hosts"
  have apache2 && maybe $SUDO systemctl reload apache2
else
  note "Apache absent : fichiers générés mais non servis (installe d'abord : sudo bash 03-install-bdd-php.sh)"
fi

# =====================================================================
section "Terminé"
# =====================================================================
SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; SRV_IP="${SRV_IP:-IP_DU_SERVEUR}"
if [ "$DRY_RUN" = 1 ]; then
  echo "  ${Y}Simulation terminée — relance sans --dry-run pour générer.${N}"
else
  echo "  ${G}Dashboard généré et déployé.${N}"
  echo "  URL : ${B}http://$SERVER_NAME/${N}  (ou http://$SRV_IP/)"
  echo "  Capteurs affichés :$SENSEL"
  echo "  Pour le modifier : édite ${DOCROOT}/sensors.php (ou relance ce script)."
  echo "  ${DIM}Le dashboard reste vide tant que la table 'mesures' n'a pas de données de ces types.${N}"
fi
echo
[ "$NO_REPORT" != 1 ] && echo "  ${DIM}Rapport enregistré dans : $REPORT${N}"
if [ "$NO_PAUSE" != 1 ] && [ "$_TTY" = 1 ]; then
  printf "  Appuie sur Entrée pour fermer… "; read -r _
fi
[ "$NO_REPORT" != 1 ] && sleep 0.2
exit $([ "$ERRN" -eq 0 ] && echo 0 || echo 1)
