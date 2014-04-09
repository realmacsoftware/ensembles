//
//  CDEBaselineConsolidator.m
//  Ensembles
//
//  Created by Drew McCormack on 27/11/13.
//  Copyright (c) 2013 Drew McCormack. All rights reserved.
//

#import "CDEBaselineConsolidator.h"
#import "CDEFoundationAdditions.h"
#import "NSManagedObjectModel+CDEAdditions.h"
#import "NSMapTable+CDEAdditions.h"
#import "CDEPersistentStoreEnsemble.h"
#import "CDERevisionManager.h"
#import "CDEEventStore.h"
#import "CDEStoreModificationEvent.h"
#import "CDERevisionSet.h"
#import "CDEEventRevision.h"
#import "CDERevision.h"
#import "CDEObjectChange.h"
#import "CDEGlobalIdentifier.h"
#import "CDEPropertyChangeValue.h"

@implementation CDEBaselineConsolidator {
}

@synthesize eventStore = eventStore;
@synthesize ensemble = ensemble;

- (instancetype)initWithEventStore:(CDEEventStore *)newEventStore
{
    self = [super init];
    if (self) {
        eventStore = newEventStore;
    }
    return self;
}

+ (NSFetchRequest *)baselineFetchRequest
{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDEStoreModificationEvent"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"type = %d", CDEStoreModificationEventTypeBaseline];
    return fetch;
}

- (BOOL)persistentStoreHasBeenAbandoned
{
    // If there are multiple baselines with the unique identifier of the local store,
    // see if the revision number is unchanged between them. If so, consider this store
    // abandoned, as it did not commit any new changes before the rebase.
    __block BOOL result = NO;
    NSManagedObjectContext *context = self.eventStore.managedObjectContext;
    [context performBlockAndWait:^{
        NSError *error;
        NSString *baselineId = self.eventStore.identifierOfBaselineUsedToConstructStore;
        if (nil == baselineId) return;
        
        NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDEStoreModificationEvent"];
        fetch.predicate = [NSPredicate predicateWithFormat:@"type = %d AND uniqueIdentifier = %@", CDEStoreModificationEventTypeBaseline, baselineId];
        NSArray *baselines = [context executeFetchRequest:fetch error:&error];
        if (!baselines) CDELog(CDELoggingLevelError, @"Failed to fetch baselines: %@", error);
        if (baselines.count <= 1) return;
        
        NSString *storeId = self.eventStore.persistentStoreIdentifier;
        NSMutableSet *baselineRevisions = [NSMutableSet set];
        for (CDEStoreModificationEvent *baseline in baselines) {
            CDERevisionSet *revSet = baseline.revisionSet;
            CDERevision *storeRevision = [revSet revisionForPersistentStoreIdentifier:storeId];
            [baselineRevisions addObject:@(storeRevision.revisionNumber)];
        }
        
        // If revisions are not unique, should get different count to baselines
        result = baselineRevisions.count != baselines.count;
    }];
    return result;
}

- (BOOL)baselineNeedsConsolidation
{
    __block BOOL result = NO;
    [self.eventStore.managedObjectContext performBlockAndWait:^{
        NSError *error = nil;
        NSFetchRequest *fetch = [self.class baselineFetchRequest];
        NSUInteger count = [self.eventStore.managedObjectContext countForFetchRequest:fetch error:&error];
        if (error) {
            CDELog(CDELoggingLevelError, @"Failed to get baseline count: %@", error);
        }
        else {
            result = count > 1;
        }
    }];
    return result;
}

- (void)consolidateBaselineWithCompletion:(CDECompletionBlock)completion
{
    CDELog(CDELoggingLevelVerbose, @"Consolidating baselines");

    NSManagedObjectContext *context = self.eventStore.managedObjectContext;
    [context performBlock:^{
        // Fetch existing baselines, ordered beginning with most recent
        NSError *error = nil;
        NSArray *baselineEvents = [self baselinesDecreasingInRecencyInManagedObjectContext:context error:&error];
        if (!baselineEvents) {
            [self failWithCompletion:completion error:error];
            return;
        }
        
        // Check that all baseline model versions are known
        CDERevisionManager *revisionManager = [[CDERevisionManager alloc] initWithEventStore:self.eventStore];
        revisionManager.managedObjectModelURL = self.ensemble.managedObjectModelURL;
        BOOL hasAllModelVersions = [revisionManager checkModelVersionsOfStoreModificationEvents:baselineEvents];
        if (!hasAllModelVersions) {
            NSError *error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeUnknownModelVersion userInfo:nil];
            [self failWithCompletion:completion error:error];
            return;
        }
        
        // Determine which baselines should be eliminated
        NSSet *baselinesToEliminate = [self redundantBaselinesInBaselines:baselineEvents];
        
        // Delete redundant baselines
        [CDEStoreModificationEvent prefetchRelatedObjectsForStoreModificationEvents:baselinesToEliminate.allObjects];
        for (CDEStoreModificationEvent *baseline in baselinesToEliminate) {
            CDELog(CDELoggingLevelVerbose, @"Deleting redundant baseline with unique id: %@", baseline.uniqueIdentifier);
            [context deleteObject:baseline];
        }
        
        // Save
        BOOL success = [context save:&error];
        if (!success) {
            [self failWithCompletion:completion error:error];
            return;
        }
        
        // Merge surviving baselines
        NSMutableArray *survivingBaselines = [NSMutableArray arrayWithArray:baselineEvents];
        [survivingBaselines removeObjectsInArray:baselinesToEliminate.allObjects];
        CDELog(CDELoggingLevelVerbose, @"Merging baselines with unique ids: %@", [survivingBaselines valueForKeyPath:@"uniqueIdentifier"]);
        CDEStoreModificationEvent *newBaseline = [self mergedBaselineFromOrderedBaselineEvents:survivingBaselines error:&error];
        if (!newBaseline) {
            [self failWithCompletion:completion error:error];
            return;
        }
        
        // Delete old baselines
        [survivingBaselines removeObject:newBaseline];
        for (CDEStoreModificationEvent *baseline in survivingBaselines) {
            [context deleteObject:baseline];
        }
        
        // Save
        if (context.hasChanges) success = [context save:&error];
        if (!success) {
            [self failWithCompletion:completion error:error];
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            CDELog(CDELoggingLevelVerbose, @"Finishing baseline consolidation");
            if (completion) completion(nil);
        });
    }];
}

- (void)failWithCompletion:(CDECompletionBlock)completion error:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(error);
    });
}

- (NSArray *)decreasingRecencySortDescriptors
{
    NSArray *sortDescriptors = @[
        [NSSortDescriptor sortDescriptorWithKey:@"globalCount" ascending:NO],
        [NSSortDescriptor sortDescriptorWithKey:@"timestamp" ascending:NO],
        [NSSortDescriptor sortDescriptorWithKey:@"eventRevision.persistentStoreIdentifier" ascending:NO]
    ];
    return sortDescriptors;
}

- (NSArray *)baselinesDecreasingInRecencyInManagedObjectContext:(NSManagedObjectContext *)context error:(NSError * __autoreleasing *)error
{
    NSFetchRequest *fetch = [self.class baselineFetchRequest];
    fetch.sortDescriptors = [self decreasingRecencySortDescriptors];
    NSArray *baselineEvents = [context executeFetchRequest:fetch error:error];
    return baselineEvents;
}

- (NSSet *)redundantBaselinesInBaselines:(NSArray *)allBaselines
{
    NSMutableSet *baselinesToEliminate = [NSMutableSet setWithCapacity:allBaselines.count];
    for (NSUInteger i = 0; i < allBaselines.count; i++) {
        CDEStoreModificationEvent *firstEvent = allBaselines[i];
        
        for (NSUInteger j = 0; j < i; j++) {
            CDEStoreModificationEvent *secondEvent = allBaselines[j];

            CDERevisionSet *firstSet = firstEvent.revisionSet;
            CDERevisionSet *secondSet = secondEvent.revisionSet;
            NSComparisonResult comparison = [firstSet compare:secondSet];
            
            if (comparison == NSOrderedDescending) {
                [baselinesToEliminate addObject:secondEvent];
            }
            else if (comparison == NSOrderedAscending) {
                [baselinesToEliminate addObject:firstEvent];
            }
            else if ([firstSet isEqualToRevisionSet:secondSet]) {
                // If exactly the same, eliminate the oldest
                NSArray *events = @[firstEvent, secondEvent];
                events = [events sortedArrayUsingDescriptors:[self decreasingRecencySortDescriptors]];
                [baselinesToEliminate addObject:events.lastObject];
            }
        }
    }
    return baselinesToEliminate;
}

- (CDEStoreModificationEvent *)mergedBaselineFromOrderedBaselineEvents:(NSArray *)baselines error:(NSError * __autoreleasing *)error
{
    if (baselines.count == 0) return nil;
    if (baselines.count == 1) return baselines.lastObject;
    
    // Change the first baseline into our new baseline by assigning a different unique id
    // Global count should be minimum, to ensure it preceeds all other events
    CDEStoreModificationEvent *firstBaseline = baselines.firstObject;
    firstBaseline.uniqueIdentifier = [[NSProcessInfo processInfo] globallyUniqueString];
    firstBaseline.timestamp = [NSDate timeIntervalSinceReferenceDate];
    firstBaseline.modelVersion = [self.ensemble.managedObjectModel cde_entityHashesPropertyList];
    firstBaseline.globalCount = [baselines.lastObject globalCount];
    
    // Update the revisions of each store in the baseline
    CDERevisionSet *newRevisionSet = [CDERevisionSet revisionSetByTakingStoreWiseMaximumOfRevisionSets:[baselines valueForKeyPath:@"revisionSet"]];
    NSString *persistentStoreId = self.eventStore.persistentStoreIdentifier;
    [firstBaseline setRevisionSet:newRevisionSet forPersistentStoreIdentifier:persistentStoreId];
    
    // Retrieve all global identifiers. Map global ids to object changes.
    [CDEStoreModificationEvent prefetchRelatedObjectsForStoreModificationEvents:@[firstBaseline]];
    NSMapTable *objectChangesByGlobalId = [NSMapTable strongToStrongObjectsMapTable];
    NSSet *objectChanges = firstBaseline.objectChanges;
    for (CDEObjectChange *change in objectChanges) {
        [objectChangesByGlobalId setObject:change forKey:change.globalIdentifier];
    }
    
    // Get other baselines
    NSMutableArray *otherBaselines = [baselines mutableCopy];
    [otherBaselines removeObject:firstBaseline];
    
    // Apply changes from others
    for (CDEStoreModificationEvent *baseline in otherBaselines) {
        [CDEStoreModificationEvent prefetchRelatedObjectsForStoreModificationEvents:@[baseline]];
        [baseline.objectChanges.allObjects cde_enumerateObjectsDrainingEveryIterations:100 usingBlock:^(CDEObjectChange *change, NSUInteger index, BOOL *stop) {
            CDEObjectChange *existingChange = [objectChangesByGlobalId objectForKey:change.globalIdentifier];
            if (!existingChange) {
                // Move change to new baseline
                change.storeModificationEvent = firstBaseline;
                [objectChangesByGlobalId setObject:change forKey:change.globalIdentifier];
            }
            else {
                [existingChange mergeValuesFromSubordinateObjectChange:change];
            }
        }];
    }
    
    return firstBaseline;
}

@end
