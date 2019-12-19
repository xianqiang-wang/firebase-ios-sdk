/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "GDTCORLibrary/Public/GDTCORDatabase.h"
#import "GDTCORLibrary/Private/GDTCORDatabase_Private.h"

#import "GDTCORLibrary/Public/GDTCORConsoleLogger.h"

#pragma mark - Helper functions and statics

/** Executes a block as the callback for sqlite3_exec.
 *
 * @param blockCallback A void* declared block that is a GDTCORExecuteSQLRowResultCallbackBlock;
 * @param columns The number of columns in the result set.
 * @param values An array of string-formatted result set values.
 * @param names An array of column names corresponding to the result set values.
 * @return A SQLITE result code. Should be SQLITE_OK if everything was ok.
 */
static int GDTCORExecuteSQLCallback(void *blockCallback, int columns, char **values, char **names) {
  if (!blockCallback || columns == 0) {
    return SQLITE_OK;
  }
  NSMutableDictionary<NSString *, NSString *> *row = [[NSMutableDictionary alloc] init];
  for (int i = 0; i < columns; i++) {
    NSString *name = [NSString stringWithUTF8String:names[i]];
    id value = values[i] ? [NSString stringWithUTF8String:values[i]] : [NSNull null];
    value = value ? value : [NSNull null];
    row[name] = value;
  }

  return ((__bridge GDTCORExecuteSQLRowResultCallbackBlock)blockCallback)(row);
}

/** Executes a string of sql using sqlite3_exec. This string can contain multiple statements.
 *
 * @param db The sqlite3 db to operate on.
 * @param sql The SQL string to run.
 * @param block The block to process the result set, or nil if no results are needed.
 * @return YES if running the SQL succeeded, NO otherwise.
 */
static BOOL ExecuteSQL(sqlite3 *db, NSString *sql, GDTCORExecuteSQLRowResultCallbackBlock block) {
  if (sql == nil || sql.length == 0) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"SQL string was empty");
    return NO;
  }
  char *errMsg;
  void *callback = block != nil ? GDTCORExecuteSQLCallback : NULL;
  void *firstArgToCallback = block != nil ? (__bridge void *)block : NULL;
  if (sqlite3_exec(db, [sql UTF8String], callback, firstArgToCallback, &errMsg) != SQLITE_OK) {
    if (errMsg) {
      GDTCORLogError(GDTCORMCEDatabaseError, @"sqlite3_exec failed: %s", errMsg);
      sqlite3_free(errMsg);
    } else {
      GDTCORLogError(GDTCORMCEDatabaseError, @"sqlite3_exec failed without an error message: %@",
                     sql);
    }
    return NO;
  }
  return YES;
}

/** Sets the user_version PRAGMA of the sqlite db.
 *
 * @note -1 is a reserved value to signify an error fetching the user_version value.
 *
 * @param db The db to alter.
 * @param userVersion The user_version value to set.
 */
static void SetUserVersion(sqlite3 *db, int userVersion) {
  if (!db) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"The database is closed");
    return;
  }
  if (!ExecuteSQL(db, [NSString stringWithFormat:@"PRAGMA user_version = %d;", userVersion], nil)) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"Setting user_version pragma failed.");
    return;
  }
}

/** Gets the user_version PRAGMA of the sqlite db.
 *
 * @param db The db to check.
 * @return the int value of the user_version PRAGMA, or -1 if there was an error.
 */
static int GetUserVersion(sqlite3 *db) {
  if (!db) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"The database is closed");
    return -1;
  }
  __block int userVersion = -1;
  BOOL result = ExecuteSQL(db, @"PRAGMA user_version;",
                           ^int(NSDictionary<NSString *, NSString *> *_Nonnull row) {
                             userVersion = [row[@"user_version"] intValue];
                             return SQLITE_OK;
                           });
  if (!result) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"Unable to retrieve user_version.");
    return -1;
  }
  return userVersion;
}

/** Gets the schema_version PRAGMA of the sqlite db.
 *
 * @param db The db to check.
 * @return the int value of the user_version PRAGMA, or -1 if there was an error.
 */
static int GetSchemaVersion(sqlite3 *db) {
  if (!db) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"The database is closed");
    return -1;
  }
  __block int schemaVersion = -1;
  BOOL result = ExecuteSQL(db, @"PRAGMA schema_version;",
                           ^int(NSDictionary<NSString *, NSString *> *_Nonnull row) {
                             schemaVersion = [row[@"schema_version"] intValue];
                             return SQLITE_OK;
                           });
  if (!result) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"Unable to retrieve user_version.");
    return -1;
  }
  return schemaVersion;
}

/** Executes a non-query SQL statement. Non-queries have no result set.
 *
 * @param db The db to operate on.
 * @param bindings The objects to bind to the params of the statement. Bindings to a statement are
 * 1-based.
 * @param sql The SQL string to execute. This should only be a single statement.
 * @param stmtCache The statement cache.
 * @param cacheStmt YES if the resulting stmt should be stored in the stmtCache.
 * @return YES if running the non-query was successful.
 */
static BOOL RunNonQuery(sqlite3 *db,
                        NSDictionary<NSNumber *, NSString *> *_Nullable bindings,
                        NSString *sql,
                        CFMutableDictionaryRef stmtCache,
                        BOOL cacheStmt) {
  if (!db) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"The database is closed");
    return NO;
  }
  if (sql == nil || sql.length == 0) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"SQL string was empty");
    return NO;
  }
  if (stmtCache == nil) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"Statement cache needs to be non-nil");
    return NO;
  }
  sqlite3_stmt *stmt =
      (sqlite3_stmt *)CFDictionaryGetValue(stmtCache, (__bridge const void *)(sql));
  if (stmt == NULL) {
    if (GDTCORSQLCompileSQL(&stmt, db, sql)) {
      if (stmtCache != nil && cacheStmt) {
        CFDictionaryAddValue(stmtCache, (__bridge const void *)(sql), stmt);
      }
    } else {
      GDTCORLogError(GDTCORMCEDatabaseError, @"SQL did not compile: %@", sql);
      return NO;
    }
  }
  [bindings enumerateKeysAndObjectsUsingBlock:^(NSNumber *_Nonnull key, NSString *_Nonnull obj,
                                                BOOL *_Nonnull stop) {
    GDTCORSQLBindObjectToParam(stmt, key.intValue, obj);
  }];
  BOOL result = GDTCORSQLRunNonQuery(db, stmt);
  if (cacheStmt) {
    GDTCORSQLReset(stmt);
  } else {
    GDTCORSQLFinalize(stmt);
  }
  return result;
}

/** Executes a query SQL statement. Queries possibly have a result set.
 *
 * @param db The db to operate on.
 * @param bindings The objects to bind to the params of the statement. Bindings to a statement are
 * 1-based.
 * @param eachRow A blcok that is ran on each row of the result set.
 * @param sql The SQL string to execute.
 * @param stmtCache The statement cache.
 * @param cacheStmt YES if the resulting stmt should be stored in the stmtCache.
 * @return YES if running the non-query was successful.
 */
static BOOL RunQuery(sqlite3 *db,
                     NSDictionary<NSNumber *, NSString *> *_Nullable bindings,
                     GDTCORSqliteRowResultBlock eachRow,
                     NSString *sql,
                     CFMutableDictionaryRef stmtCache,
                     BOOL cacheStmt) {
  if (!db) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"The database is closed");
    return NO;
  }
  if (sql == nil || sql.length == 0) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"SQL string was empty");
    return NO;
  }
  if (stmtCache == nil) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"Statement cache needs to be non-nil");
    return NO;
  }
  sqlite3_stmt *stmt =
      (sqlite3_stmt *)CFDictionaryGetValue(stmtCache, (__bridge const void *)(sql));
  if (stmt == NULL) {
    if (GDTCORSQLCompileSQL(&stmt, db, sql)) {
      if (stmtCache != nil && cacheStmt) {
        CFDictionaryAddValue(stmtCache, (__bridge const void *)(sql), stmt);
      }
    } else {
      GDTCORLogError(GDTCORMCEDatabaseError, @"SQL did not compile: %@", sql);
      return NO;
    }
  }
  [bindings enumerateKeysAndObjectsUsingBlock:^(NSNumber *_Nonnull key, NSString *_Nonnull obj,
                                                BOOL *_Nonnull stop) {
    GDTCORSQLBindObjectToParam(stmt, key.intValue, obj);
  }];
  BOOL result = GDTCORSQLRunQuery(db, stmt, eachRow);
  if (cacheStmt) {
    GDTCORSQLReset(stmt);
  } else {
    GDTCORSQLFinalize(stmt);
  }
  return result;
}

/** Runs a series of migrations, setting the user_version PRAGMA to the highest version number.
 *
 * @param db The db to operate on.
 * @param migrations The map of user_version numbers to the SQL statement needed to update to that
 *   version.
 * @param stmtCache The statement cache.
 */
static void RunMigrations(sqlite3 *db,
                          NSDictionary<NSNumber *, NSString *> *migrations,
                          CFMutableDictionaryRef stmtCache) {
  if (!db) {
    GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"The database is closed");
    return;
  }
  int userVersion = GetUserVersion(db);
  __block int newUserVersion = userVersion;
  [migrations enumerateKeysAndObjectsUsingBlock:^(NSNumber *_Nonnull key, NSString *_Nonnull obj,
                                                  BOOL *_Nonnull stop) {
    if (key.intValue > newUserVersion) {
      if (ExecuteSQL(db, obj, nil)) {
        newUserVersion = key.intValue;
      } else {
        GDTCORLogError(GDTCORMCEDatabaseError, @"%@", @"Migration failed: version:%@ statement:%@",
                       key, obj);
      }
    }
  }];

  if (newUserVersion != userVersion) {
    SetUserVersion(db, newUserVersion);
  }
}

/** Creates and/or returns a static queue shared across the GDTCORDatabase class.
 *
 * @return The class-shared queue.
 */
static dispatch_queue_t SharedQueue() {
  static dispatch_queue_t sharedQueue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedQueue = dispatch_queue_create("com.google.GDTCORDatabase.shared", DISPATCH_QUEUE_SERIAL);
  });
  return sharedQueue;
}

/** A dispatch_once token to manage the instantiation of the dbPathToInstance map. */
static dispatch_once_t cacheToken;

/** A shared cache of sqlite paths db instances. */
static NSMutableDictionary<NSString *, GDTCORDatabase *> *dbPathToInstance;

/** Maps db paths to instances, or deletes the mapping.
 *
 * @param instance The instance to map.
 * @param path The path to map the instance to.
 * @param delete If YES, deletes the mapping.
 */
static void SetInstanceToFileMap(GDTCORDatabase *instance, NSString *path, BOOL delete) {
  dispatch_once(&cacheToken, ^{
    dbPathToInstance = [[NSMutableDictionary alloc] init];
  });
  // Don't map anything if it's a special sqlite path.
  if ([path hasPrefix:@":"] && [path hasSuffix:@":"]) {
    return;
  }
  dispatch_async(SharedQueue(), ^{
    if (delete) {
      [dbPathToInstance removeObjectForKey:path];
    } else {
      dbPathToInstance[path] = instance;
    }
  });
}

/** Returns YES if there's an instance in existence for the given sqlite path.
 *
 * @param path The path to check.
 * @return YES, if there's a db in memory operating on that path already.
 */
static BOOL InstanceExistsForPath(NSString *path) {
  // Only 1 instance per file is allowed. Return nil if one is already open (including :memory:).
  dispatch_once(&cacheToken, ^{
    dbPathToInstance = [[NSMutableDictionary alloc] init];
  });

  // Check if this is a special type of path. If it begins and ends with :, it's ok to create.
  if ([path hasPrefix:@":"]) {
    return NO;
  }

  __block GDTCORDatabase *extantDB;
  dispatch_sync(SharedQueue(), ^{
    extantDB = dbPathToInstance[path];
  });
  return extantDB != nil;
}

#pragma mark - GDTCORDatabase

@implementation GDTCORDatabase {
  /** The sqlite database. */
  sqlite3 *_db;
}

- (nullable instancetype)initWithURL:(nullable NSURL *)dbFileURL
                         creationSQL:(NSString *)sql
                 migrationStatements:
                     (nullable NSDictionary<NSNumber *, NSString *> *)migrationStatements {
  NSString *dbPath = dbFileURL ? dbFileURL.path : @":memory:";
  // Return nil if there's already an instance for the given path, or if the DB fails to open.
  if (InstanceExistsForPath(dbPath) || !GDTCORSQLOpenDB(&_db, dbPath)) {
    return nil;
  }
  self = [super init];
  if (self) {
    _dbQueue = dispatch_queue_create("com.google.GDTCORDatabase", DISPATCH_QUEUE_SERIAL);
    _path = dbPath;
    _stmtCache =
        CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, NULL);
    dispatch_async(_dbQueue, ^{
      if (GetSchemaVersion(self->_db) == 0) {
        // Run the creation statements only if this is a brand-new DB.
        ExecuteSQL(self->_db, sql, nil);
      }
      RunMigrations(self->_db, [migrationStatements copy], self -> _stmtCache);
    });
    SetInstanceToFileMap(self, _path, NO);
  }
  return self;
}

- (void)dealloc {
  [self close];
}

- (BOOL)open {
  if (_db == NULL && _dbQueue != nil) {
    __block BOOL openedSuccessfully = NO;
    dispatch_sync(_dbQueue, ^{
      openedSuccessfully = GDTCORSQLOpenDB(&self->_db, self->_path ? self->_path : @":memory:");
      if (openedSuccessfully) {
        SetInstanceToFileMap(self, self->_path, NO);
      }
    });
    return openedSuccessfully;
  }
  GDTCORLogWarning(GDTCORMCWDatabaseWarning, @"Database already open: %@", _path);
  return NO;
}

- (BOOL)close {
  if (_dbQueue != nil && _db != NULL) {
    __block BOOL closedSuccessfully = NO;
    dispatch_sync(_dbQueue, ^{
      closedSuccessfully = GDTCORSQLCloseDB(self->_db);
      self->_db = NULL;
      if (closedSuccessfully) {
        SetInstanceToFileMap(self, self->_path, YES);
      }
    });
    return closedSuccessfully;
  }
  return NO;
}

- (void)setUserVersion:(int)userVersion {
  dispatch_async(_dbQueue, ^{
    SetUserVersion(self->_db, userVersion);
  });
}

- (int)userVersion {
  __block int userVersion = -1;
  dispatch_sync(_dbQueue, ^{
    userVersion = GetUserVersion(self->_db);
  });
  return userVersion;
}

- (int)schemaVersion {
  __block int schemaVersion = -1;
  dispatch_sync(_dbQueue, ^{
    schemaVersion = GetSchemaVersion(self->_db);
  });
  return schemaVersion;
}

- (BOOL)runNonQuery:(NSString *)sql
           bindings:(nullable NSDictionary<NSNumber *, NSString *> *)bindings
          cacheStmt:(BOOL)cacheStmt {
  __block BOOL returnStatus = NO;
  dispatch_sync(_dbQueue, ^{
    returnStatus = RunNonQuery(self->_db, bindings, sql, self->_stmtCache, cacheStmt);
  });
  return returnStatus;
}

- (BOOL)runQuery:(NSString *)sql
        bindings:(nullable NSDictionary<NSNumber *, NSString *> *)bindings
         eachRow:(GDTCORSqliteRowResultBlock)eachRow
       cacheStmt:(BOOL)cacheStmt {
  __block BOOL returnStatus = NO;
  dispatch_sync(_dbQueue, ^{
    returnStatus = RunQuery(self->_db, bindings, eachRow, sql, self->_stmtCache, cacheStmt);
  });
  return returnStatus;
}

- (BOOL)executeSQL:(NSString *)sql
          callback:(nullable GDTCORExecuteSQLRowResultCallbackBlock)callback {
  __block BOOL returnStatus = NO;
  dispatch_sync(_dbQueue, ^{
    returnStatus = ExecuteSQL(self->_db, sql, callback);
  });
  return returnStatus;
}

@end