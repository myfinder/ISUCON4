CREATE TABLE IF NOT EXISTS `users` (
  `id` int NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `login` varchar(255) NOT NULL UNIQUE,
  `password_hash` varchar(255) NOT NULL,
  `salt` varchar(255) NOT NULL,
  `fail_count` int unsigned NOT NULL,
  `last_login_at` datetime,
  `last_login_ip` varchar(255)
) DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `login_log` (
  `id` bigint NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `created_at` datetime NOT NULL,
  `user_id` int,
  `login` varchar(255) NOT NULL,
  `ip` varchar(255) NOT NULL,
  `succeeded` tinyint NOT NULL
) DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `fail_ips` (
  `ip` varchar(255) NOT NULL PRIMARY KEY,
  `fail_count` int unsigned NOT NULL
) DEFAULT CHARSET=utf8;
