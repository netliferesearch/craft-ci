-- Applied to a throwaway copy of the source database (production by default), never to the source itself.
-- Craft table names without prefix. Add site-specific tables via SCRUB_TRUNCATE or .netlife/scrub.sql.
-- Tables that exist only in some Craft versions are guarded with information_schema and a prepared
-- statement, because the snapshot script aborts on any SQL error.

UPDATE users
SET email = CONCAT('user', id, '@example.test'),
    username = CONCAT('user', id),
    fullName = NULL, firstName = NULL, lastName = NULL,
    password = NULL, verificationCode = NULL, lastLoginAttemptIp = NULL,
    passwordResetRequired = 0;

DELETE FROM sessions;
DELETE FROM tokens;
DELETE FROM queue;
DELETE FROM announcements;

-- Credentials and activity of users, where the table exists.
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'webauthn') > 0, 'DELETE FROM webauthn', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'authenticator') > 0, 'DELETE FROM authenticator', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'recoverycodes') > 0, 'DELETE FROM recoverycodes', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'sso_identities') > 0, 'DELETE FROM sso_identities', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'elementactivity') > 0, 'DELETE FROM elementactivity', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'craftidtokens') > 0, 'DELETE FROM craftidtokens', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
-- Craft's database cache (DbCache): stale entries and cached fragments, regenerated on demand. Can hold anything
-- a plugin cached, and on nfi it was 2.4 GB of a 3 GB dump.
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'cache') > 0, 'DELETE FROM cache', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Element search keywords of users (names, emails).
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'searchindex') > 0, 'DELETE FROM searchindex WHERE elementId IN (SELECT id FROM users)', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- GraphQL tokens: keep the public schema's row, which public GraphQL needs.
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'gqltokens') > 0, 'UPDATE gqltokens SET accessToken = CONCAT(''scrubbed-'', id) WHERE accessToken <> ''__PUBLIC__''', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Draft notes may hold personal text.
SET @s = IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'drafts') > 0, 'UPDATE drafts SET notes = NULL', 'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Addresses owned by users (Craft 5: primaryOwnerId, Craft 4: ownerId). Addresses owned by entries are
-- content and stay. Only the personal columns that exist are set to NULL.
SET @owner = (SELECT MIN(column_name) FROM information_schema.columns
              WHERE table_schema = DATABASE() AND table_name = 'addresses' AND column_name IN ('primaryOwnerId', 'ownerId'));
SET @cols = (SELECT GROUP_CONCAT(CONCAT('`', column_name, '` = NULL'))
             FROM information_schema.columns
             WHERE table_schema = DATABASE() AND table_name = 'addresses'
               AND column_name IN ('fullName', 'firstName', 'lastName', 'addressLine1', 'addressLine2', 'addressLine3',
                                   'organization', 'organizationTaxId', 'postalCode', 'sortingCode', 'dependentLocality',
                                   'locality', 'latitude', 'longitude'));
SET @s = IF(@owner IS NOT NULL AND @cols IS NOT NULL,
            CONCAT('UPDATE addresses SET ', @cols, ' WHERE `', @owner, '` IN (SELECT id FROM users)'),
            'DO 0');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
