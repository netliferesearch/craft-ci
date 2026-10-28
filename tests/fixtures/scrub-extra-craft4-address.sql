-- Craft 4 shape of addresses (no such table before Craft 4.0; owner column is ownerId).
CREATE TABLE addresses (
  id INT PRIMARY KEY, ownerId INT, firstName VARCHAR(255), lastName VARCHAR(255), addressLine1 VARCHAR(255), countryCode CHAR(2)
);
INSERT INTO addresses VALUES (10, 1, 'Real', 'Name', 'Street 1', 'NO'), (11, 50, 'Office', 'Co', 'Street 2', 'NO');
