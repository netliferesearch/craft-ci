-- Minimal Craft 4-like tables the shared scrub.sql always touches.
CREATE TABLE users (
  id INT PRIMARY KEY, email VARCHAR(255), username VARCHAR(255),
  fullName VARCHAR(255), firstName VARCHAR(255), lastName VARCHAR(255),
  password VARCHAR(255), verificationCode VARCHAR(255), lastLoginAttemptIp VARCHAR(45),
  passwordResetRequired TINYINT NOT NULL DEFAULT 0
);
CREATE TABLE sessions (id INT PRIMARY KEY, token CHAR(100));
CREATE TABLE tokens (id INT PRIMARY KEY, token CHAR(32));
CREATE TABLE queue (id INT PRIMARY KEY, job BLOB);
CREATE TABLE announcements (id INT PRIMARY KEY, body TEXT);
INSERT INTO users VALUES (1, 'real@client.no', 'realname', 'Real Name', 'Real', 'Name', 'hash', 'code', '10.0.0.1', 1);
INSERT INTO sessions VALUES (1, 'secret');
INSERT INTO tokens VALUES (1, 'secret');
INSERT INTO queue VALUES (1, 'job');
INSERT INTO announcements VALUES (1, 'text');
