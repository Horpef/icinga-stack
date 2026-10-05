-- ---------------------------------------------------------------------------
-- Extra databases for the Icinga stack.
-- `icinga2` itself is created from MYSQL_DATABASE by the MySQL entrypoint.
-- Executed from /docker-entrypoint-initdb.d (only on a fresh volume).
-- ---------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS `icingadb`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

CREATE DATABASE IF NOT EXISTS `director`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS 'icinga'@'%' IDENTIFIED BY 'icinga_pass';

GRANT ALL PRIVILEGES ON `icinga2`.*  TO 'icinga'@'%';
GRANT ALL PRIVILEGES ON `icingadb`.* TO 'icinga'@'%';
GRANT ALL PRIVILEGES ON `director`.* TO 'icinga'@'%';

-- The icingadb daemon runs `--database-auto-import`, which issues
-- `SET SESSION innodb_strict_mode = 1` and therefore needs these
-- dynamic privileges on MySQL 8.
GRANT SESSION_VARIABLES_ADMIN, SYSTEM_VARIABLES_ADMIN ON *.* TO 'icinga'@'%';

FLUSH PRIVILEGES;
