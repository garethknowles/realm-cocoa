////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMMigration_Private.h"

#import "RLMAccessor.h"
#import "RLMObject.h"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMProperty_Private.h"
#import "RLMRealm_Dynamic.h"
#import "RLMRealm_Private.hpp"
#import "RLMResults_Private.h"
#import "RLMSchema_Private.h"

#import "object_store.hpp"

using namespace realm;

// The source realm for a migration has to use a SharedGroup to be able to share
// the file with the destination realm, but we don't want to let the user call
// beginWriteTransaction on it as that would make no sense.
@interface RLMMigrationRealm : RLMRealm
@end

@implementation RLMMigrationRealm
- (BOOL)readonly {
    return YES;
}

- (void)beginWriteTransaction {
    @throw RLMException(@"Cannot modify the source Realm in a migration");
}
@end

@implementation RLMMigration

- (instancetype)initWithRealm:(RLMRealm *)realm key:(NSData *)key error:(NSError **)error {
    self = [super init];
    if (self) {
        // create rw realm to migrate with current on disk table
        _realm = realm;

        // create read only realm used during migration with current on disk schema
        _oldRealm = [[RLMMigrationRealm alloc] initWithPath:realm.path key:key readOnly:NO inMemory:NO dynamic:YES error:error];
        if (_oldRealm) {
            RLMRealmSetSchema(_oldRealm, [RLMSchema dynamicSchemaFromRealm:_oldRealm], true);
        }
        if (error && *error) {
            return nil;
        }
    }
    return self;
}

- (RLMSchema *)oldSchema {
    return self.oldRealm.schema;
}

- (RLMSchema *)newSchema {
    return self.realm.schema;
}

- (void)enumerateObjects:(NSString *)className block:(RLMObjectMigrationBlock)block {
    // get all objects
    RLMResults *objects = [_realm.schema schemaForClassName:className] ? [_realm allObjects:className] : nil;
    RLMResults *oldObjects = [_oldRealm.schema schemaForClassName:className] ? [_oldRealm allObjects:className] : nil;

    if (objects && oldObjects) {
        for (long i = oldObjects.count - 1; i >= 0; i--) {
            block(oldObjects[i], objects[i]);
        }
    }
    else if (objects) {
        for (long i = objects.count - 1; i >= 0; i--) {
            block(nil, objects[i]);
        }
    }
    else if (oldObjects) {
        for (long i = oldObjects.count - 1; i >= 0; i--) {
            block(oldObjects[i], nil);
        }
    }
}

- (void)execute:(RLMMigrationBlock)block {
    @autoreleasepool {
        // copy old schema and reset after migration
        RLMSchema *savedSchema = [_realm.schema copy];

        // disable all primary keys for migration
        for (RLMObjectSchema *objectSchema in _realm.schema.objectSchema) {
            objectSchema.primaryKeyProperty.isPrimary = NO;
        }

        // apply block and set new schema version
        uint64_t oldVersion = realm::ObjectStore::get_schema_version(_realm.group);
        block(self, oldVersion);

        // reset schema to saved schema since it has been altered
        RLMRealmSetSchema(_realm, savedSchema, true);
    }
}

-(RLMObject *)createObject:(NSString *)className withValue:(id)value {
    return [_realm createObject:className withValue:value];
}

- (RLMObject *)createObject:(NSString *)className withObject:(id)object {
    return [self createObject:className withValue:object];
}

- (void)deleteObject:(RLMObject *)object {
    [_realm deleteObject:object];
}

- (BOOL)deleteDataForClassName:(NSString *)name {
    if (!name) {
        return false;
    }

    TableRef table = ObjectStore::table_for_object_type(_realm.group, name.UTF8String);
    if (!table) {
        return false;
    }

    if ([_realm.schema schemaForClassName:name]) {
        table->clear();
    }
    else {
        realm::ObjectStore::delete_data_for_object(_realm.group, name.UTF8String);
    }

    return true;
}

@end
