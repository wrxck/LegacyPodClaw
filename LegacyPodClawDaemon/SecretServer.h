/*
 * SecretServer.h
 * clawpodd - keychain-backed secret service
 */

#import <Foundation/Foundation.h>

/* call while still root, because bootstrap_check_in needs the launchd-owned port */
BOOL CPSecretServerStart(void);

void CPSecretServerMigrate(void);

/* deletes every secret from the keychain; dpkg --purge runs it, so nothing stays after a complete removal */
BOOL CPSecretServerDeleteAll(void);
