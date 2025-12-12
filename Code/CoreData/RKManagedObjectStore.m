//
//  RKManagedObjectStore.m
//  RestKit
//
//  Created by Blake Watters on 9/22/09.
//  Copyright (c) 2009-2012 RestKit. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "RKManagedObjectStore.h"
#import "NSManagedObject+ActiveRecord.h"
#import "RKLog.h"
#import "RKSearchWordObserver.h"
#import "RKObjectPropertyInspector.h"
#import "RKObjectPropertyInspector+CoreData.h"
#import "RKAlert.h"
#import "RKDirectory.h"
#import "RKFetchRequestManagedObjectCache.h"
#import "NSBundle+RKAdditions.h"
#import "NSManagedObjectContext+RKAdditions.h"

// Set Logging Component
#undef RKLogComponent
#define RKLogComponent lcl_cRestKitCoreData

NSString* const RKManagedObjectStoreDidFailSaveNotification = @"RKManagedObjectStoreDidFailSaveNotification";
static NSString* const RKManagedObjectStoreThreadDictionaryContextKey = @"RKManagedObjectStoreThreadDictionaryContextKey";
static NSString* const RKManagedObjectStoreThreadDictionaryEntityCacheKey = @"RKManagedObjectStoreThreadDictionaryEntityCacheKey";

static RKManagedObjectStore *defaultObjectStore = nil;

@interface RKManagedObjectStore ()
@property (nonatomic, retain, readwrite) NSManagedObjectContext *primaryManagedObjectContext;
@property (nonatomic, retain, readwrite) NSManagedObjectContext *backgroundManagedObjectContext;
@property (nonatomic, retain, readwrite) NSPersistentContainer *persistentContainer;

- (id)initWithStoreFilename:(NSString *)storeFilename inDirectory:(NSString *)nilOrDirectoryPath usingSeedDatabaseName:(NSString *)nilOrNameOfSeedDatabaseInMainBundle managedObjectModel:(NSManagedObjectModel*)nilOrManagedObjectModel delegate:(id)delegate;
- (void)createStoreIfNecessaryUsingSeedDatabase:(NSString*)seedDatabase;
@end

@implementation RKManagedObjectStore

@synthesize delegate = _delegate;
@synthesize storeFilename = _storeFilename;
@synthesize pathToStoreFile = _pathToStoreFile;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize persistentContainer = _persistentContainer;
@synthesize cacheStrategy = _cacheStrategy;
@synthesize primaryManagedObjectContext;
@synthesize backgroundManagedObjectContext;

+ (RKManagedObjectStore *)defaultObjectStore {
    return defaultObjectStore;
}

+ (void)setDefaultObjectStore:(RKManagedObjectStore *)objectStore {
    [objectStore retain];
    [defaultObjectStore release];
    defaultObjectStore = objectStore;
}

+ (void)deleteStoreAtPath:(NSString *)path
{
    NSURL* storeURL = [NSURL fileURLWithPath:path];
    NSError* error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:storeURL.path]) {
        if (! [[NSFileManager defaultManager] removeItemAtPath:storeURL.path error:&error]) {
            NSAssert(NO, @"Managed object store failed to delete persistent store : %@", error);
        }
    } else {
        RKLogWarning(@"Asked to delete persistent store but no store file exists at path: %@", storeURL.path);
    }
}

+ (void)deleteStoreInApplicationDataDirectoryWithFilename:(NSString *)filename
{
    NSString *path = [[RKDirectory applicationDataDirectory] stringByAppendingPathComponent:filename];
    [self deleteStoreAtPath:path];
}

+ (RKManagedObjectStore*)objectStoreWithStoreFilename:(NSString*)storeFilename {
    return [self objectStoreWithStoreFilename:storeFilename usingSeedDatabaseName:nil managedObjectModel:nil delegate:nil];
}

+ (RKManagedObjectStore*)objectStoreWithStoreFilename:(NSString *)storeFilename usingSeedDatabaseName:(NSString *)nilOrNameOfSeedDatabaseInMainBundle managedObjectModel:(NSManagedObjectModel*)nilOrManagedObjectModel delegate:(id)delegate {
    return [[[self alloc] initWithStoreFilename:storeFilename inDirectory:nil usingSeedDatabaseName:nilOrNameOfSeedDatabaseInMainBundle managedObjectModel:nilOrManagedObjectModel delegate:delegate] autorelease];
}

+ (RKManagedObjectStore*)objectStoreWithStoreFilename:(NSString *)storeFilename inDirectory:(NSString *)directory usingSeedDatabaseName:(NSString *)nilOrNameOfSeedDatabaseInMainBundle managedObjectModel:(NSManagedObjectModel*)nilOrManagedObjectModel delegate:(id)delegate {
    return [[[self alloc] initWithStoreFilename:storeFilename inDirectory:directory usingSeedDatabaseName:nilOrNameOfSeedDatabaseInMainBundle managedObjectModel:nilOrManagedObjectModel delegate:delegate] autorelease];
}

- (id)initWithStoreFilename:(NSString*)storeFilename {
    return [self initWithStoreFilename:storeFilename inDirectory:nil usingSeedDatabaseName:nil managedObjectModel:nil delegate:nil];
}

- (id)initWithStoreFilename:(NSString *)storeFilename inDirectory:(NSString *)nilOrDirectoryPath usingSeedDatabaseName:(NSString *)nilOrNameOfSeedDatabaseInMainBundle managedObjectModel:(NSManagedObjectModel*)nilOrManagedObjectModel delegate:(id)delegate {
    self = [self init];
    if (self) {
        _storeFilename = [storeFilename retain];

        if (nilOrDirectoryPath == nil) {
            // If initializing into Application Data directory, ensure the directory exists
            nilOrDirectoryPath = [RKDirectory applicationDataDirectory];
            [RKDirectory ensureDirectoryExistsAtPath:nilOrDirectoryPath error:nil];
        } else {
            // If path given, caller is responsible for directory's existence
            BOOL isDir;
            NSAssert1([[NSFileManager defaultManager] fileExistsAtPath:nilOrDirectoryPath isDirectory:&isDir] && isDir == YES, @"Specified storage directory exists", nilOrDirectoryPath);
        }
        _pathToStoreFile = [[nilOrDirectoryPath stringByAppendingPathComponent:_storeFilename] retain];

        if (nilOrManagedObjectModel == nil) {
            nilOrManagedObjectModel = [NSManagedObjectModel mergedModelFromBundles:@[[NSBundle mainBundle]]];
        }
        _managedObjectModel = [nilOrManagedObjectModel retain];
        _delegate = delegate;

        if (nilOrNameOfSeedDatabaseInMainBundle) {
            [self createStoreIfNecessaryUsingSeedDatabase:nilOrNameOfSeedDatabaseInMainBundle];
        }

        [self createPersistentContainerWithName:storeFilename model:_managedObjectModel];

        _cacheStrategy = [RKFetchRequestManagedObjectCache new];

        // Ensure there is a search word observer
        [RKSearchWordObserver sharedObserver];

        // Hydrate the defaultObjectStore
        if (! defaultObjectStore) {
            [RKManagedObjectStore setDefaultObjectStore:self];
        }
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_storeFilename release];
    _storeFilename = nil;
    [_pathToStoreFile release];
    _pathToStoreFile = nil;

    [_managedObjectModel release];
    _managedObjectModel = nil;
    [_persistentContainer release];
    _persistentContainer = nil;
    [_cacheStrategy release];
    _cacheStrategy = nil;
    [primaryManagedObjectContext release];
    primaryManagedObjectContext = nil;
    [backgroundManagedObjectContext release];
    backgroundManagedObjectContext = nil;

    [super dealloc];
}

/**
 Performs the save action for the application, which is to send the save:
 message to the application's managed object context.
 */
- (BOOL)saveContext:(NSManagedObjectContext*)context withError:(NSError **)error {
    __block NSError *localError = nil;
    __block BOOL success = YES;

    [context performBlockAndWait:^{
        @try {
            if (![context save:&localError]) {
                if (self.delegate != nil && [self.delegate respondsToSelector:@selector(managedObjectStore:didFailToSaveContext:error:exception:)]) {
                    [self.delegate managedObjectStore:self didFailToSaveContext:context error:localError exception:nil];
                }

                NSDictionary* userInfo = [NSDictionary dictionaryWithObject:localError forKey:@"error"];
                [[NSNotificationCenter defaultCenter] postNotificationName:RKManagedObjectStoreDidFailSaveNotification object:self userInfo:userInfo];

                if ([[localError domain] isEqualToString:@"NSCocoaErrorDomain"]) {
                    NSDictionary *userInfo = [localError userInfo];
                    NSArray *errors = [userInfo valueForKey:@"NSDetailedErrors"];
                    if (errors) {
                        for (NSError *detailedError in errors) {
                            NSDictionary *subUserInfo = [detailedError userInfo];
                            RKLogError(@"Core Data Save Error\n \
                              NSLocalizedDescription:\t\t%@\n \
                              NSValidationErrorKey:\t\t\t%@\n \
                              NSValidationErrorPredicate:\t%@\n \
                              NSValidationErrorObject:\n%@\n",
                                       [subUserInfo valueForKey:@"NSLocalizedDescription"],
                                       [subUserInfo valueForKey:@"NSValidationErrorKey"],
                                       [subUserInfo valueForKey:@"NSValidationErrorPredicate"],
                                       [subUserInfo valueForKey:@"NSValidationErrorObject"]);
                        }
                    }
                    else {
                        RKLogError(@"Core Data Save Error\n \
                               NSLocalizedDescription:\t\t%@\n \
                               NSValidationErrorKey:\t\t\t%@\n \
                               NSValidationErrorPredicate:\t%@\n \
                               NSValidationErrorObject:\n%@\n",
                                   [userInfo valueForKey:@"NSLocalizedDescription"],
                                   [userInfo valueForKey:@"NSValidationErrorKey"],
                                   [userInfo valueForKey:@"NSValidationErrorPredicate"],
                                   [userInfo valueForKey:@"NSValidationErrorObject"]);
                    }
                }

                success = NO;
            }
        }
        @catch (NSException* e) {
            if (self.delegate != nil && [self.delegate respondsToSelector:@selector(managedObjectStore:didFailToSaveContext:error:exception:)]) {
                [self.delegate managedObjectStore:self didFailToSaveContext:context error:nil exception:e];
            }
            else {
                @throw;
            }
            success = NO;
        }

    }];

    // If this context has a parent, cascade the save to persist to disk.
    // The parent is a main queue context, so we need to save on the main queue.
    NSManagedObjectContext *parentContext = context.parentContext;
    if (parentContext != nil && success) {
        if ([NSThread isMainThread]) {
            // Already on main thread, save directly (but async via performBlock to avoid re-entrancy)
            [parentContext performBlock:^{
                NSError *parentError = nil;
                if (![parentContext save:&parentError]) {
                    if (self.delegate != nil && [self.delegate respondsToSelector:@selector(managedObjectStore:didFailToSaveContext:error:exception:)]) {
                        [self.delegate managedObjectStore:self didFailToSaveContext:parentContext error:parentError exception:nil];
                    }
                    RKLogError(@"Core Data Parent Context Save Error: %@", [parentError localizedDescription]);
                }
            }];
        } else {
            // On background thread - safe to wait for main thread synchronously
            [parentContext performBlockAndWait:^{
                NSError *parentError = nil;
                if (![parentContext save:&parentError]) {
                    if (self.delegate != nil && [self.delegate respondsToSelector:@selector(managedObjectStore:didFailToSaveContext:error:exception:)]) {
                        [self.delegate managedObjectStore:self didFailToSaveContext:parentContext error:parentError exception:nil];
                    }
                    RKLogError(@"Core Data Parent Context Save Error: %@", [parentError localizedDescription]);
                    success = NO;
                }
            }];
        }
    }

    if (!success) {
        if (error) {
            *error = localError;
        }
        return NO;
    }

    return YES;
}

- (void)createStoreIfNecessaryUsingSeedDatabase:(NSString*)seedDatabase {
    if (NO == [[NSFileManager defaultManager] fileExistsAtPath:self.pathToStoreFile]) {
        NSString* seedDatabasePath = [[NSBundle mainBundle] pathForResource:seedDatabase ofType:nil];
        NSAssert1(seedDatabasePath, @"Unable to find seed database file '%@' in the Main Bundle, aborting...", seedDatabase);
        RKLogInfo(@"No existing database found, copying from seed path '%@'", seedDatabasePath);

        NSError* error;
        if (![[NSFileManager defaultManager] copyItemAtPath:seedDatabasePath toPath:self.pathToStoreFile error:&error]) {
            if (self.delegate != nil && [self.delegate respondsToSelector:@selector(managedObjectStore:didFailToCopySeedDatabase:error:)]) {
                [self.delegate managedObjectStore:self didFailToCopySeedDatabase:seedDatabase error:error];
            } else {
                RKLogError(@"Encountered an error during seed database copy: %@", [error localizedDescription]);
            }
        }
        NSAssert1([[NSFileManager defaultManager] fileExistsAtPath:seedDatabasePath], @"Seed database not found at path '%@'!", seedDatabasePath);
    }
}

- (void)createPersistentContainerWithName:(NSString*)name model:(NSManagedObjectModel*)model {
    NSAssert(_managedObjectModel, @"Cannot create persistent container without a managed object model");
    NSAssert(!_persistentContainer, @"Cannot create persistent container: one already exists.");
    
    _persistentContainer = [[NSPersistentContainer alloc] initWithName:name managedObjectModel:self.managedObjectModel];
    
    NSPersistentStoreDescription *storeDescription = self.persistentContainer.persistentStoreDescriptions.firstObject;
    storeDescription.URL = [NSURL fileURLWithPath:self.pathToStoreFile];
    storeDescription.shouldMigrateStoreAutomatically = YES;
    storeDescription.shouldInferMappingModelAutomatically = YES;
    
    [self.persistentContainer loadPersistentStoresWithCompletionHandler:
     ^(NSPersistentStoreDescription *desc, NSError *error) {
        NSAssert(!error, @"Failed to load store: %@", error);

        // Configure the primary (main thread) context
        self.primaryManagedObjectContext = [self.persistentContainer viewContext];
        self.primaryManagedObjectContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;
        self.primaryManagedObjectContext.automaticallyMergesChangesFromParent = YES;

        // Create background context as CHILD of primary context
        NSManagedObjectContext *bgContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        bgContext.parentContext = self.primaryManagedObjectContext;
        bgContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;
        // Enable auto-merge so background context sees changes from sibling contexts via parent
        bgContext.automaticallyMergesChangesFromParent = YES;
        self.backgroundManagedObjectContext = [bgContext autorelease];
    }];
}

- (NSManagedObjectContext *)newBackgroundContext {
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = self.persistentContainer.persistentStoreCoordinator;
    context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;
    return context;  // Caller owns - must release (MRC)
}

@end
