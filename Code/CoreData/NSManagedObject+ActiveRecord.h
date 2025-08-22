//
//  NSManagedObject+ActiveRecord.h
//
//  Adapted from https://github.com/magicalpanda/MagicalRecord
//  Created by Saul Mora on 11/15/09.
//  Copyright 2010 Magical Panda Software, LLC All rights reserved.
//
//  Created by Chad Podoski on 3/18/11.
//

#import <CoreData/CoreData.h>

/**
 Extensions to NSManagedObjectContext for RestKit's Active Record pattern implementation
 */
@interface NSManagedObjectContext (ActiveRecord)

+ (NSManagedObjectContext *)contextForMainThread;
+ (NSManagedObjectContext *)contextForBackgroundThread;

@end

/**
 Provides extensions to NSManagedObject implementing a low-ceremony querying
 interface.
 */
@interface NSManagedObject (ActiveRecord)

/**
 * Fetches all objects from the persistent store identified by the fetchRequest
 */
+ (NSArray*)objectsWithFetchRequest:(NSFetchRequest*)fetchRequest inContext:(NSManagedObjectContext*)context;

/**
 * Retrieves the number of objects that would be retrieved by the fetchRequest,
 * if executed
 */
+ (NSUInteger)countOfObjectsWithFetchRequest:(NSFetchRequest*)fetchRequest inContext:(NSManagedObjectContext*)context;

/**
 * Fetches the first object identified by the fetch request. A limit of one will be
 * applied to the fetch request before dispatching.
 */
+ (id)objectWithFetchRequest:(NSFetchRequest*)fetchRequest inContext:(NSManagedObjectContext*)context;

/**
 * Fetches all objects from the persistent store by constructing a fetch request and
 * applying the predicate supplied. A short-cut for doing filtered searches on the objects
 * of this class under management.
 */
+ (NSArray*)objectsWithPredicate:(NSPredicate*)predicate inContext:(NSManagedObjectContext*)context;

/**
 * Fetches the first object matching a predicate from the persistent store. A fetch request
 * will be constructed for you and a fetch limit of 1 will be applied.
 */
+ (id)objectWithPredicate:(NSPredicate*)predicate inContext:(NSManagedObjectContext*)context;

/**
 * Fetches all managed objects of this class from the persistent store as an array
 */
+ (NSArray*)allObjectsInContext:(NSManagedObjectContext*)context;

/**
 * Returns a count of all managed objects of this class in the persistent store. On
 * error, will populate the error argument
 */
+ (NSUInteger)countInContext:(NSManagedObjectContext*)context error:(NSError**)error;

/**
 * Creates a new managed object and inserts it into the managedObjectContext.
 */
+ (id)objectInContext:(NSManagedObjectContext *)context;

/**
 * Returns YES when an object has not been saved to the managed object context yet
 */
- (BOOL)isNew;

/**
 Finds the instance of the receiver's entity with the given value for the primary key attribute in
 the given managed object context.

 @param primaryKeyValue The value for the receiving entity's primary key attribute.
 @param context The managed object context to find the instance in.
 @return The object with the primary key attribute equal to the given value or nil.
 */
+ (id)findByPrimaryKey:(id)primaryKeyValue inContext:(NSManagedObjectContext *)context;

////////////////////////////////////////////////////////////////////////////////////////////////////

+ (void)handleErrors:(NSError *)error;

+ (NSArray *)executeFetchRequest:(NSFetchRequest *)request inContext:(NSManagedObjectContext *)context;
+ (NSFetchRequest *)createFetchRequestInContext:(NSManagedObjectContext *)context;
+ (NSEntityDescription *)entityDescriptionInContext:(NSManagedObjectContext *)context;

+ (id)createInContext:(NSManagedObjectContext *)context;
- (BOOL)deleteInContext:(NSManagedObjectContext *)context;

+ (BOOL)truncateAllInContext:(NSManagedObjectContext *)context;

+ (NSArray *)ascendingSortDescriptors:(id)attributesToSortBy, ...;
+ (NSArray *)descendingSortDescriptors:(id)attributesToSortyBy, ...;

+ (NSNumber *)numberOfEntitiesWithContext:(NSManagedObjectContext *)context;
+ (NSNumber *)numberOfEntitiesWithPredicate:(NSPredicate *)searchTerm inContext:(NSManagedObjectContext *)context;

+ (BOOL) hasAtLeastOneEntityInContext:(NSManagedObjectContext *)context;

+ (NSFetchRequest *)requestAllInContext:(NSManagedObjectContext *)context;
+ (NSFetchRequest *)requestAllWhere:(NSString *)property isEqualTo:(id)value inContext:(NSManagedObjectContext *)context;
+ (NSFetchRequest *)requestFirstWithPredicate:(NSPredicate *)searchTerm inContext:(NSManagedObjectContext *)context;
+ (NSFetchRequest *)requestFirstByAttribute:(NSString *)attribute withValue:(id)searchValue inContext:(NSManagedObjectContext *)context;
+ (NSFetchRequest *)requestAllSortedBy:(NSString *)sortTerm ascending:(BOOL)ascending inContext:(NSManagedObjectContext *)context;
+ (NSFetchRequest *)requestAllSortedBy:(NSString *)sortTerm ascending:(BOOL)ascending withPredicate:(NSPredicate *)searchTerm inContext:(NSManagedObjectContext *)context;

+ (NSArray *)findAllInContext:(NSManagedObjectContext *)context;
+ (NSArray *)findAllSortedBy:(NSString *)sortTerm ascending:(BOOL)ascending inContext:(NSManagedObjectContext *)context;
+ (NSArray *)findAllSortedBy:(NSString *)sortTerm ascending:(BOOL)ascending withPredicate:(NSPredicate *)searchTerm inContext:(NSManagedObjectContext *)context;
+ (NSArray *)findAllWithPredicate:(NSPredicate *)searchTerm inContext:(NSManagedObjectContext *)context;

+ (id)findFirstInContext:(NSManagedObjectContext *)context;
+ (id)findFirstWithPredicate:(NSPredicate *)searchTerm inContext:(NSManagedObjectContext *)context;
+ (id)findFirstWithPredicate:(NSPredicate *)searchterm sortedBy:(NSString *)property ascending:(BOOL)ascending inContext:(NSManagedObjectContext *)context;
+ (id)findFirstWithPredicate:(NSPredicate *)searchTerm andRetrieveAttributes:(NSArray *)attributes inContext:(NSManagedObjectContext *)context;
+ (id)findFirstWithPredicate:(NSPredicate *)searchTerm sortedBy:(NSString *)sortBy ascending:(BOOL)ascending inContext:(NSManagedObjectContext *)context andRetrieveAttributes:(id)attributes, ...;

+ (id)findFirstByAttribute:(NSString *)attribute withValue:(id)searchValue inContext:(NSManagedObjectContext *)context;
+ (NSArray *)findByAttribute:(NSString *)attribute withValue:(id)searchValue inContext:(NSManagedObjectContext *)context;
+ (NSArray *)findByAttribute:(NSString *)attribute withValue:(id)searchValue andOrderBy:(NSString *)sortTerm ascending:(BOOL)ascending inContext:(NSManagedObjectContext *)context;

#if TARGET_OS_IPHONE

+ (NSFetchedResultsController *)fetchAllSortedBy:(NSString *)sortTerm ascending:(BOOL)ascending withPredicate:(NSPredicate *)searchTerm groupBy:(NSString *)groupingKeyPath inContext:(NSManagedObjectContext *)context;

+ (NSFetchedResultsController *)fetchRequest:(NSFetchRequest *)request groupedBy:(NSString *)group inContext:(NSManagedObjectContext *)context;

+ (NSFetchedResultsController *)fetchRequestAllGroupedBy:(NSString *)group withPredicate:(NSPredicate *)searchTerm sortedBy:(NSString *)sortTerm ascending:(BOOL)ascending inContext:(NSManagedObjectContext *)context;

#endif

@end
