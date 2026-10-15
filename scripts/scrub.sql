-- Applied to a throwaway copy of the staging database, never to staging itself.
-- Craft 5 table names without prefix. Add site-specific tables via SCRUB_TRUNCATE.

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
