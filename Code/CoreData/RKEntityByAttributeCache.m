//
//  RKEntityByAttributeCache.m
//  RestKit
//
//  Created by Blake Watters on 5/1/12.
//  Copyright (c) 2012 RestKit. All rights reserved.
//

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#import "RKEntityByAttributeCache.h"
#import "RKLog.h"
#import "RKObjectPropertyInspector.h"
#import "RKObjectPropertyInspector+CoreData.h"

// Set Logging Component
#undef RKLogComponent
#define RKLogComponent lcl_cRestKitCoreDataCache

@interface RKEntityByAttributeCache ()
@property (nonatomic, retain) NSMutableDictionary *attributeValuesToObjectIDs;
@end

@implementation RKEntityByAttributeCache

@synthesize entity = _entity;
@synthesize attribute = _attribute;
@synthesize managedObjectContext = _managedObjectContext;
@synthesize attributeValuesToObjectIDs = _attributeValuesToObjectIDs;
@synthesize monitorsContextForChanges = _monitorsContextForChanges;
@synthesize monitorsMemoryWarnings = _monitorsMemoryWarnings;

- (id)initWithEntity:(NSEntityDescription *)entity attribute:(NSString *)attributeName managedObjectContext:(NSManagedObjectContext *)context
{
    self = [self init];
    if (self) {
        _entity = [entity retain];
        _attribute = [attributeName retain];
        _managedObjectContext = [context retain];
        _monitorsContextForChanges = YES;
        _monitorsMemoryWarnings = NO;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managedObjectContextDidChange:)
                                                     name:NSManagedObjectContextObjectsDidChangeNotification
                                                   object:context];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managedObjectContextDidSave:)
                                                     name:NSManagedObjectContextDidSaveNotification
                                                   object:context];
#if TARGET_OS_IPHONE
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_entity release];
    [_attribute release];
    [_managedObjectContext release];
    [_attributeValuesToObjectIDs release];

    [super dealloc];
}

- (NSUInteger)count
{
    return [[[self.attributeValuesToObjectIDs allValues] valueForKeyPath:@"@sum.@count"] integerValue];
}

- (NSUInteger)countOfAttributeValues
{
    return [self.attributeValuesToObjectIDs count];
}

- (NSUInteger)countWithAttributeValue:(id)attributeValue
{
    return [[self objectsWithAttributeValue:attributeValue] count];
}

- (BOOL)shouldCoerceAttributeToString:(NSString *)attributeValue
{
    if ([attributeValue isKindOfClass:[NSString class]] || [attributeValue isEqual:[NSNull null]]) {
        return NO;
    }

    Class attributeType = [[RKObjectPropertyInspector sharedInspector] typeForProperty:self.attribute ofEntity:self.entity];
    return [attributeType instancesRespondToSelector:@selector(stringValue)];
}

- (void)load
{
    [self.managedObjectContext performBlockAndWait:^{
        RKLogDebug(@"Loading entity cache for Entity '%@' by attribute '%@'", self.entity.name, self.attribute);
        NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
        [fetchRequest setEntity:self.entity];
        [fetchRequest setResultType:NSManagedObjectIDResultType];
        
        NSError *error = nil;
        NSArray *objectIDs = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];
        [fetchRequest release];
        if (error) {
            RKLogError(@"Failed to load entity cache: %@", error);
            return;
        }
        
        self.attributeValuesToObjectIDs = [NSMutableDictionary dictionaryWithCapacity:[objectIDs count]];
        for (NSManagedObjectID *objectID in objectIDs) {
            NSError *error = nil;
            NSManagedObject *object = [self.managedObjectContext existingObjectWithID:objectID error:&error];
            if (! object && error) {
                RKLogError(@"Failed to retrieve managed object with ID %@: %@", objectID, error);
            }
            
            [self addObject:object];
        }
    }];
}

- (void)flush
{
    RKLogDebug(@"Flushing entity cache for Entity '%@' by attribute '%@'", self.entity.name, self.attribute);
    self.attributeValuesToObjectIDs = nil;
}

- (void)reload
{
    [self flush];
    [self load];
}

- (BOOL)isLoaded
{
    return (self.attributeValuesToObjectIDs != nil);
}

- (NSManagedObject *)objectWithAttributeValue:(id)attributeValue
{
    NSArray *objects = [self objectsWithAttributeValue:attributeValue];
    return ([objects count] > 0) ? [objects objectAtIndex:0] : nil;
}

- (NSManagedObject *)objectWithID:(NSManagedObjectID *)objectID {
    /*
     NOTE:
     We use existingObjectWithID: as opposed to objectWithID: as objectWithID: can return us a fault
     that will raise an exception when fired. existingObjectWithID:error: will return nil if the ID has been
     deleted. objectRegisteredForID: is also an acceptable approach.
     */
    __block NSManagedObject *object = nil;
    [self.managedObjectContext performBlockAndWait:^{
        NSError *error = nil;
        object = [[self.managedObjectContext existingObjectWithID:objectID error:&error] retain];
        if (! object && error) {
            RKLogError(@"Failed to retrieve managed object with ID %@. Error %@\n%@", objectID, [error localizedDescription], [error userInfo]);
        }
    }];

    return [object autorelease];
}

- (NSArray *)objectsWithAttributeValue:(id)attributeValue
{
    attributeValue = [self shouldCoerceAttributeToString:attributeValue] ? [attributeValue stringValue] : attributeValue;

    // Perform the entire lookup within performBlockAndWait to ensure thread safety
    // and proper memory management with the context's queue.
    __block NSArray *result = nil;
    [self.managedObjectContext performBlockAndWait:^{
        // Copy the objectIDs array to protect against concurrent modification during flush.
        // Under MRC, the array returned by objectForKey: is unretained. If flush is called
        // (via NSManagedObjectContextDidSaveNotification) while we're iterating, the dictionary
        // is released which releases the array, leaving us with a dangling pointer.
        NSMutableArray *objectIDs = [self.attributeValuesToObjectIDs objectForKey:attributeValue];
        if (objectIDs) {
            NSArray *objectIDsCopy = [[objectIDs copy] autorelease];
            NSMutableArray *objects = [NSMutableArray arrayWithCapacity:[objectIDsCopy count]];
            for (NSManagedObjectID *objectID in objectIDsCopy) {
                NSError *error = nil;
                NSManagedObject *object = [self.managedObjectContext existingObjectWithID:objectID error:&error];
                if (object) {
                    [objects addObject:object];
                }
            }
            result = [objects retain];
        }
    }];

    return result ? [result autorelease] : [NSArray array];
}

- (void)addObject:(NSManagedObject *)object
{
    [self.managedObjectContext performBlockAndWait:^{
        NSAssert([object.entity isEqual:self.entity], @"Cannot add object with entity '%@' to cache with entity of '%@'", [[object entity] name], [self.entity name]);
        id attributeValue = [object valueForKey:self.attribute];
        // Coerce to a string if possible
        attributeValue = [self shouldCoerceAttributeToString:attributeValue] ? [attributeValue stringValue] : attributeValue;
        if (attributeValue) {
            NSManagedObjectID *objectID = [object objectID];
            NSMutableArray *objectIDs = [self.attributeValuesToObjectIDs objectForKey:attributeValue];
            if (objectIDs) {
                if (! [objectIDs containsObject:objectID]) {
                    [objectIDs addObject:objectID];
                }
            } else {
                objectIDs = [NSMutableArray arrayWithObject:objectID];
            }

            if (nil == self.attributeValuesToObjectIDs) self.attributeValuesToObjectIDs = [NSMutableDictionary dictionary];
            [self.attributeValuesToObjectIDs setValue:objectIDs forKey:attributeValue];
        } else {
            RKLogWarning(@"Unable to add object with nil value for attribute '%@': %@", self.attribute, object);
        }
    }];
}

- (void)removeObject:(NSManagedObject *)object
{
    [self.managedObjectContext performBlockAndWait:^{
        NSAssert([object.entity isEqual:self.entity], @"Cannot remove object with entity '%@' from cache with entity of '%@'", [[object entity] name], [self.entity name]);
        id attributeValue = [object valueForKey:self.attribute];
        // Coerce to a string if possible
        attributeValue = [self shouldCoerceAttributeToString:attributeValue] ? [attributeValue stringValue] : attributeValue;
        if (attributeValue) {
            NSManagedObjectID *objectID = [object objectID];
            NSMutableArray *objectIDs = [self.attributeValuesToObjectIDs objectForKey:attributeValue];
            if (objectIDs && [objectIDs containsObject:objectID]) {
                [objectIDs removeObject:objectID];
            }
        } else {
            RKLogWarning(@"Unable to remove object with nil value for attribute '%@': %@", self.attribute, object);
        }
    }];
}

- (BOOL)containsObjectWithAttributeValue:(id)attributeValue
{
    // Coerce to a string if possible
    attributeValue = [self shouldCoerceAttributeToString:attributeValue] ? [attributeValue stringValue] : attributeValue;
    return [[self objectsWithAttributeValue:attributeValue] count] > 0;
}

- (BOOL)containsObject:(NSManagedObject *)object
{
    __block BOOL result = NO;
    [self.managedObjectContext performBlockAndWait:^{
        if (! [object.entity isEqual:self.entity]) {
            result = NO;
            return;
        }
        id attributeValue = [object valueForKey:self.attribute];
        // Coerce to a string if possible
        attributeValue = [self shouldCoerceAttributeToString:attributeValue] ? [attributeValue stringValue] : attributeValue;
        result = [[self objectsWithAttributeValue:attributeValue] containsObject:object];
    }];
    return result;
}

- (void)managedObjectContextDidChange:(NSNotification *)notification
{
    if (self.monitorsContextForChanges == NO) return;

    NSDictionary *userInfo = notification.userInfo;
    NSSet *insertedObjects = [userInfo objectForKey:NSInsertedObjectsKey];
    NSSet *updatedObjects = [userInfo objectForKey:NSUpdatedObjectsKey];
    NSSet *deletedObjects = [userInfo objectForKey:NSDeletedObjectsKey];
    RKLogTrace(@"insertedObjects=%@, updatedObjects=%@, deletedObjects=%@", insertedObjects, updatedObjects, deletedObjects);

    NSMutableSet *objectsToAdd = [NSMutableSet setWithSet:insertedObjects];
    [objectsToAdd unionSet:updatedObjects];

    for (NSManagedObject *object in objectsToAdd) {
        if ([object.entity isEqual:self.entity]) {
            [self addObject:object];
        }
    }

    for (NSManagedObject *object in deletedObjects) {
        if ([object.entity isEqual:self.entity]) {
            [self removeObject:object];
        }
    }
}

- (void)managedObjectContextDidSave:(NSNotification *)notification
{
    // After the MOC has been saved, we flush to ensure any temporary
    // objectID references are converted into permanent ID's on the next load.
    [self flush];
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification
{
    if (self.monitorsMemoryWarnings)
        [self flush];
}

@end
