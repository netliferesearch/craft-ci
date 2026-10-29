-- Small versions of the Craft 5 tables that scrub.sql guards, one or two rows each.
CREATE TABLE webauthn (id INT PRIMARY KEY, userId INT);
CREATE TABLE authenticator (id INT PRIMARY KEY, userId INT);
CREATE TABLE recoverycodes (id INT PRIMARY KEY, userId INT);
CREATE TABLE sso_identities (id INT PRIMARY KEY, userId INT);
CREATE TABLE elementactivity (id INT PRIMARY KEY, userId INT);
CREATE TABLE craftidtokens (id INT PRIMARY KEY, userId INT);
CREATE TABLE cache (id CHAR(128) PRIMARY KEY, expire INT, data LONGBLOB);
INSERT INTO webauthn VALUES (1, 1);
INSERT INTO authenticator VALUES (1, 1);
INSERT INTO recoverycodes VALUES (1, 1);
INSERT INTO sso_identities VALUES (1, 1);
INSERT INTO elementactivity VALUES (1, 1);
INSERT INTO craftidtokens VALUES (1, 1);
INSERT INTO cache VALUES ('k', 0, 'user@example.com');

CREATE TABLE gqltokens (id INT PRIMARY KEY, accessToken VARCHAR(255));
INSERT INTO gqltokens VALUES (1, '__PUBLIC__'), (2, 'real-token');

CREATE TABLE drafts (id INT PRIMARY KEY, notes TEXT);
INSERT INTO drafts VALUES (1, 'a personal note');

CREATE TABLE searchindex (elementId INT, keywords TEXT);
INSERT INTO searchindex VALUES (1, 'real name'), (50, 'entry keywords');

-- Craft 5 shape: primaryOwnerId. Element 1 is a user, element 50 an entry.
CREATE TABLE addresses (
  id INT PRIMARY KEY, primaryOwnerId INT, fullName VARCHAR(255), addressLine1 VARCHAR(255),
  postalCode VARCHAR(20), locality VARCHAR(255), latitude DOUBLE, longitude DOUBLE, countryCode CHAR(2)
);
INSERT INTO addresses VALUES (10, 1, 'Real Name', 'Street 1', '0150', 'Oslo', 59.9, 10.7, 'NO');
INSERT INTO addresses VALUES (11, 50, 'Office', 'Street 2', '0151', 'Oslo', 59.9, 10.7, 'NO');
