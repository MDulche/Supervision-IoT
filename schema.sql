-- =============================================================
--  supervision — schéma de la base de données (partie BDD + PHP)
-- -------------------------------------------------------------
--  À exécuter en administrateur MySQL :
--      sudo mysql < sql/schema.sql
--  (le script 03-install-bdd-php.sh fait tout ceci automatiquement
--   et remplace 'CHANGE_MOI' par le mot de passe que tu choisis.)
-- =============================================================

-- 1) La base ---------------------------------------------------
CREATE DATABASE IF NOT EXISTS supervision
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE supervision;

-- 2) Les tables ------------------------------------------------

-- Catalogue des capteurs physiques (décrit les appareils).
CREATE TABLE IF NOT EXISTS capteurs (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  code        VARCHAR(50) UNIQUE NOT NULL,   -- identifiant unique, ex: 'esp32-salle1'
  emplacement VARCHAR(100)                   -- ex: 'Salle serveur'
);

-- Les mesures : une ligne = une valeur relevée à un instant donné.
CREATE TABLE IF NOT EXISTS mesures (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  capteur     VARCHAR(50),                   -- code du capteur émetteur (= capteurs.code)
  type        VARCHAR(30),                   -- grandeur: 'temperature','humidite','co2',...
  valeur      FLOAT,                          -- la valeur mesurée
  date_mesure DATETIME DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_date (date_mesure)
);

-- 3) Le compte applicatif -------------------------------------
--    Utilisé par le dashboard (lecture) ET le backend (écriture).
--    Droits volontairement limités : SELECT + INSERT uniquement.
CREATE USER IF NOT EXISTS 'iot_app'@'localhost' IDENTIFIED BY 'CHANGE_MOI';
ALTER USER 'iot_app'@'localhost' IDENTIFIED BY 'CHANGE_MOI';
GRANT SELECT, INSERT ON supervision.* TO 'iot_app'@'localhost';
FLUSH PRIVILEGES;

-- 4) Données d'exemple (pour voir le dashboard s'afficher) -----
INSERT INTO capteurs (code, emplacement) VALUES
  ('esp32-salle1', 'Salle serveur'),
  ('esp32-bureau', 'Bureau');

INSERT INTO mesures (capteur, type, valeur) VALUES
  ('esp32-salle1', 'temperature', 22.4),
  ('esp32-salle1', 'humidite',    48.0),
  ('esp32-salle1', 'co2',        780),
  ('esp32-bureau', 'temperature', 23.1),
  ('esp32-bureau', 'luminosite', 320);

-- Vérifier rapidement :
--   SELECT * FROM mesures ORDER BY date_mesure DESC LIMIT 10;
