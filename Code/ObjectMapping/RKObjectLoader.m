//
//  RKObjectLoader.m
//  RestKit
//
//  Created by Blake Watters on 8/8/09.
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

#import "RKObjectLoader.h"
#import "RKObjectMapper.h"
#import "RKObjectManager.h"
#import "RKObjectMapperError.h"
#import "RKObjectLoader_Internals.h"
#import "RKParserRegistry.h"
#import "RKRequest_Internals.h"
#import "RKObjectMappingProvider+Contexts.h"
#import "RKObjectSerializer.h"
#import "NSManagedObject+ActiveRecord.h"
#import "RKManagedObjectStore.h"

// Set Logging Component
#undef RKLogComponent
#define RKLogComponent lcl_cRestKitNetwork

@interface RKRequest (Private)
- (void)updateInternalCacheDate;
- (void)postRequestDidFailWithErrorNotification:(NSError *)error;
@end

@interface RKObjectLoader () {
    NSManagedObjectID *_targetObjectID;  // Captured on main thread for safe background access
    NSManagedObjectID *_sourceObjectID;  // Captured on main thread for safe background access
    NSManagedObjectContext *_mappingContext;  // Fresh sibling context for this request
}
@property (nonatomic, assign, readwrite, getter = isLoaded) BOOL loaded;
@property (nonatomic, assign, readwrite, getter = isLoading) BOOL loading;
@property (nonatomic, retain, readwrite) RKResponse *response;
@end

@implementation RKObjectLoader

@synthesize mappingProvider = _mappingProvider;
@synthesize targetObject = _targetObject;
@synthesize objectMapping = _objectMapping;
@synthesize result = _result;
@synthesize serializationMapping = _serializationMapping;
@synthesize serializationMIMEType = _serializationMIMEType;
@synthesize sourceObject = _sourceObject;
@synthesize onDidFailWithError = _onDidFailWithError;
@synthesize onDidLoadObject = _onDidLoadObject;
@synthesize onDidLoadObjects = _onDidLoadObjects;
@synthesize onDidLoadObjectsDictionary = _onDidLoadObjectsDictionary;
@dynamic loaded;
@dynamic loading;
@dynamic response;

+ (id)loaderWithURL:(RKURL *)URL mappingProvider:(RKObjectMappingProvider *)mappingProvider {
    return [[[self alloc] initWithURL:URL mappingProvider:mappingProvider] autorelease];
}

- (id)initWithURL:(RKURL *)URL mappingProvider:(RKObjectMappingProvider *)mappingProvider {
    self = [super initWithURL:URL];
    if (self) {
        _mappingProvider = [mappingProvider retain];
    }

    return self;
}

- (void)dealloc {
    [_mappingProvider release];
    _mappingProvider = nil;
    [_sourceObject release];
    _sourceObject = nil;
    [_targetObject release];
    _targetObject = nil;
    [_targetObjectID release];
    _targetObjectID = nil;
    [_sourceObjectID release];
    _sourceObjectID = nil;
    [_mappingContext release];
    _mappingContext = nil;
    [_objectMapping release];
    _objectMapping = nil;
    [_result release];
    _result = nil;
    [_serializationMIMEType release];
    _serializationMIMEType = nil;
    [_serializationMapping release];
    _serializationMapping = nil;
    [_onDidFailWithError release];
    _onDidFailWithError = nil;
    [_onDidLoadObject release];
    _onDidLoadObject = nil;
    [_onDidLoadObjects release];
    _onDidLoadObjects = nil;
    [_onDidLoadObjectsDictionary release];
    _onDidLoadObjectsDictionary = nil;

    [super dealloc];
}

- (void)reset {
    [super reset];
    [_result release];
    _result = nil;
}

- (NSManagedObjectContext *)mappingContext {
    return _mappingContext;
}

- (void)informDelegateOfError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        [(NSObject<RKObjectLoaderDelegate>*)_delegate objectLoader:self didFailWithError:error];

        if (self.onDidFailWithError) {
            self.onDidFailWithError(error);
        }
    });
}

#pragma mark - Response Processing

// NOTE: This method is significant because the notifications posted are used by
// RKRequestQueue to remove requests from the queue. All requests need to be finalized.
- (void)finalizeLoad:(BOOL)successful {
    self.loading = NO;
    self.loaded = successful;
    
    if ([self.delegate respondsToSelector:@selector(objectLoaderDidFinishLoading:)]) {
        [self.delegate objectLoaderDidFinishLoading:self];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RKRequestDidFinishLoadingNotification object:self];
}

// Invoked on the main thread. Inform the delegate.
- (void)informDelegateOfObjectLoadWithResultDictionary:(NSDictionary*)resultDictionary {
    RKObjectMappingResult* result = [RKObjectMappingResult mappingResultWithDictionary:resultDictionary];

    // Dictionary callback
    if ([self.delegate respondsToSelector:@selector(objectLoader:didLoadObjectDictionary:)]) {
        [(NSObject<RKObjectLoaderDelegate>*)self.delegate objectLoader:self didLoadObjectDictionary:[result asDictionary]];
    }

    if (self.onDidLoadObjectsDictionary) {
        self.onDidLoadObjectsDictionary([result asDictionary]);
    }

    // Collection callback
    if ([self.delegate respondsToSelector:@selector(objectLoader:didLoadObjects:)]) {
        [(NSObject<RKObjectLoaderDelegate>*)self.delegate objectLoader:self didLoadObjects:[result asCollection]];
    }

    if (self.onDidLoadObjects) {
        self.onDidLoadObjects([result asCollection]);
    }

    // Singular object callback
    if ([self.delegate respondsToSelector:@selector(objectLoader:didLoadObject:)]) {
        [(NSObject<RKObjectLoaderDelegate>*)self.delegate objectLoader:self didLoadObject:[result asObject]];
    }

    if (self.onDidLoadObject) {
        self.onDidLoadObject([result asObject]);
    }

    [self finalizeLoad:YES];
}

#pragma mark - Subclass Hooks

/**
 Overloaded by RKManagedObjectLoader to serialize/deserialize managed objects
 at thread boundaries.
 @protected
 */
- (void)processMappingResult:(RKObjectMappingResult*)result {
    NSAssert(_sentSynchronously || ![NSThread isMainThread], @"Mapping result processing should occur on a background thread");
    [self performSelectorOnMainThread:@selector(informDelegateOfObjectLoadWithResultDictionary:) withObject:[result asDictionary] waitUntilDone:YES];
}

#pragma mark - Response Object Mapping

- (RKObjectMappingResult*)mapResponseWithMappingProvider:(RKObjectMappingProvider*)mappingProvider toObject:(id)targetObject inContext:(RKObjectMappingProviderContext)context error:(NSError**)error {
    id<RKParser> parser = [[RKParserRegistry sharedRegistry] parserForMIMEType:self.response.MIMEType];
    NSAssert1(parser, @"Cannot perform object load without a parser for MIME Type '%@'", self.response.MIMEType);

    // Check that there is actually content in the response body for mapping. It is possible to get back a 200 response
    // with the appropriate MIME Type with no content (such as for a successful PUT or DELETE). Make sure we don't generate an error
    // in these cases
    id bodyAsString = [self.response bodyAsString];
    RKLogTrace(@"bodyAsString: %@", bodyAsString);
    if (bodyAsString == nil || [[bodyAsString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0) {
        RKLogDebug(@"Mapping attempted on empty response body...");
        if (targetObject) {
            return [RKObjectMappingResult mappingResultWithDictionary:[NSDictionary dictionaryWithObject:targetObject forKey:@""]];
        }

        return [RKObjectMappingResult mappingResultWithDictionary:[NSDictionary dictionary]];
    }

    id parsedData = [parser objectFromString:bodyAsString error:error];
    if (parsedData == nil && error) {
        return nil;
    }

    // Allow the delegate to manipulate the data
    if ([self.delegate respondsToSelector:@selector(objectLoader:willMapData:)]) {
        parsedData = [[parsedData mutableCopy] autorelease];
        [(NSObject<RKObjectLoaderDelegate>*)self.delegate objectLoader:self willMapData:&parsedData];
    }

    RKObjectMapper* mapper = [RKObjectMapper mapperWithObject:parsedData mappingProvider:mappingProvider];
    mapper.targetObject = targetObject;
    mapper.delegate = self;
    mapper.context = context;
    RKObjectMappingResult* result = [mapper performMapping];

    // Log any mapping errors
    if (mapper.errorCount > 0) {
        RKLogError(@"Encountered errors during mapping: %@", [[mapper.errors valueForKey:@"localizedDescription"] componentsJoinedByString:@", "]);
    }

    // The object mapper will return a nil result if mapping failed
    if (nil == result) {
        // TODO: Construct a composite error that wraps up all the other errors. Should probably make it performMapping:&error when we have this?
        if (error) *error = [mapper.errors lastObject];
        return nil;
    }

    return result;
}

- (RKObjectMappingDefinition *)configuredObjectMapping {
    if (self.objectMapping) {
        return self.objectMapping;
    }

    return [self.mappingProvider objectMappingForResourcePath:self.resourcePath];
}

- (RKObjectMappingResult*)performMapping:(NSError**)error {
    NSAssert(_sentSynchronously || ![NSThread isMainThread], @"Mapping should occur on a background thread");

    RKObjectMappingProvider* mappingProvider;
    RKObjectMappingDefinition *configuredObjectMapping = [self configuredObjectMapping];
    if (configuredObjectMapping) {
        mappingProvider = [RKObjectMappingProvider mappingProvider];
        NSString *rootKeyPath = configuredObjectMapping.rootKeyPath ? configuredObjectMapping.rootKeyPath : @"";
        [mappingProvider setMapping:configuredObjectMapping forKeyPath:rootKeyPath];

        // Copy the error mapping from our configured mappingProvider
        mappingProvider.errorMapping = self.mappingProvider.errorMapping;
    } else {
        RKLogDebug(@"No object mapping provider, using mapping provider from parent object manager to perform KVC mapping");
        mappingProvider = self.mappingProvider;
    }

    // If targetObject is a managed object, fetch it from the per-request mapping context using
    // the objectID captured on the main thread. Accessing self.targetObject directly
    // from the background thread is unsafe.
    id targetObjectForMapping = nil;
    if (_targetObjectID) {
        targetObjectForMapping = [_mappingContext existingObjectWithID:_targetObjectID error:nil];
    } else {
        // Not a managed object, safe to use directly
        targetObjectForMapping = self.targetObject;
    }

    return [self mapResponseWithMappingProvider:mappingProvider toObject:targetObjectForMapping inContext:RKObjectMappingProviderContextObjectsByKeyPath error:error];
}

- (void)performMappingInDispatchQueue {
    // Use the per-request mapping context created in didFinishLoad:
    [_mappingContext performBlock:^{
        NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

        // Set thread-local mapping context so RKManagedObjectMapping can use it
        [RKManagedObjectStore setCurrentMappingContext:_mappingContext];

        RKLogDebug(@"Beginning object mapping activities within GCD queue labeled: %@", _mappingContext);
        NSError *error = nil;
        _result = [[self performMapping:&error] retain];
        NSAssert(_result || error, @"Expected performMapping to return a mapping result or an error.");
        if (self.result) {
            [self processMappingResult:self.result];
        } else if (error) {
            [self performSelectorOnMainThread:@selector(didFailLoadWithError:) withObject:error waitUntilDone:NO];
        }

        // Clear thread-local mapping context
        [RKManagedObjectStore setCurrentMappingContext:nil];

        [pool drain];
    }];
}

- (BOOL)canParseMIMEType:(NSString*)MIMEType {
    if ([[RKParserRegistry sharedRegistry] parserForMIMEType:self.response.MIMEType]) {
        return YES;
    }

    RKLogWarning(@"Unable to find parser for MIME Type '%@'", MIMEType);
    return NO;
}

- (BOOL)isResponseMappable {
    if ([self.response isServiceUnavailable]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:RKServiceDidBecomeUnavailableNotification object:self];
    }

    if ([self.response isFailure]) {
        [self informDelegateOfError:self.response.failureError];

        [self didFailLoadWithError:self.response.failureError];
        return NO;
    } else if ([self.response isNoContent]) {
        // The No Content (204) response will never have a message body or a MIME Type.
        // Use objectIDs captured on main thread to fetch objects in per-request mapping context.
        id resultDictionary = nil;
        id targetObj = nil;
        if (_targetObjectID) {
            targetObj = [_mappingContext existingObjectWithID:_targetObjectID error:nil];
        } else {
            targetObj = self.targetObject;  // Not a managed object, safe to access
        }
        id sourceObj = nil;
        if (_sourceObjectID) {
            sourceObj = [_mappingContext existingObjectWithID:_sourceObjectID error:nil];
        } else {
            sourceObj = self.sourceObject;  // Not a managed object, safe to access
        }
        if (targetObj) {
            resultDictionary = [NSDictionary dictionaryWithObject:targetObj forKey:@""];
        } else if (sourceObj) {
            resultDictionary = [NSDictionary dictionaryWithObject:sourceObj forKey:@""];
        } else {
            resultDictionary = [NSDictionary dictionary];
        }
        [self informDelegateOfObjectLoadWithResultDictionary:resultDictionary];
        return NO;
    } else if (NO == [self canParseMIMEType:[self.response MIMEType]]) {
        // We can't parse the response, it's unmappable regardless of the status code
        RKLogWarning(@"Encountered unexpected response with status code: %ld (MIME Type: %@ -> URL: %@)", (long) self.response.statusCode, self.response.MIMEType, self.URL);
        NSError* error = [NSError errorWithDomain:RKErrorDomain code:RKObjectLoaderUnexpectedResponseError userInfo:nil];
        if ([_delegate respondsToSelector:@selector(objectLoaderDidLoadUnexpectedResponse:)]) {
            [(NSObject<RKObjectLoaderDelegate>*)_delegate objectLoaderDidLoadUnexpectedResponse:self];
        } else {
            [self informDelegateOfError:error];
        }

        // NOTE: We skip didFailLoadWithError: here so that we don't send the delegate
        // conflicting messages around unexpected response and failure with error
        [self finalizeLoad:NO];

        return NO;
    } else if ([self.response isError]) {
        // This is an error and we can map the MIME Type of the response
        [self handleResponseError];
        return NO;
    }

    return YES;
}

- (void)handleResponseError {
    // Since we are mapping what we know to be an error response, we don't want to map the result back onto our
    // target object
    NSError *error = nil;
    RKObjectMappingResult *result = [self mapResponseWithMappingProvider:self.mappingProvider toObject:nil inContext:RKObjectMappingProviderContextErrors error:&error];
    if (result) {
        error = [result asError];
    } else {
        RKLogError(@"Encountered an error while attempting to map server side errors from payload: %@", [error localizedDescription]);
    }

    [self informDelegateOfError:error];
    [self finalizeLoad:NO];
}

#pragma mark - RKRequest & RKRequestDelegate methods

// Invoked just before request hits the network
- (BOOL)prepareURLRequest {
    if ((self.sourceObject && self.params == nil) && (self.method == RKRequestMethodPOST || self.method == RKRequestMethodPUT)) {
        NSAssert(self.serializationMapping, @"You must provide a serialization mapping for objects of type '%@'", NSStringFromClass([self.sourceObject class]));
        RKLogDebug(@"POST or PUT request for source object %@, serializing to MIME Type %@ for transport...", self.sourceObject, self.serializationMIMEType);
        RKObjectSerializer* serializer = [RKObjectSerializer serializerWithObject:self.sourceObject mapping:self.serializationMapping];
        NSError* error = nil;
        id params = [serializer serializationForMIMEType:self.serializationMIMEType error:&error];

        if (error) {
            RKLogError(@"Serializing failed for source object %@ to MIME Type %@: %@", self.sourceObject, self.serializationMIMEType, [error localizedDescription]);
            [self didFailLoadWithError:error];
            return NO;
        }

        if ([self.delegate respondsToSelector:@selector(objectLoader:didSerializeSourceObject:toSerialization:)]) {
            [self.delegate objectLoader:self didSerializeSourceObject:self.sourceObject toSerialization:&params];
        }

        self.params = params;
    }

    // TODO: This is an informal protocol ATM. Maybe its not obvious enough?
    if (self.sourceObject) {
        if ([self.sourceObject respondsToSelector:@selector(willSendWithObjectLoader:)]) {
            [self.sourceObject performSelector:@selector(willSendWithObjectLoader:) withObject:self];
        }
    }

    return [super prepareURLRequest];
}

- (void)didFailLoadWithError:(NSError *)error {
    NSParameterAssert(error);
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

    if (_cachePolicy & RKRequestCachePolicyLoadOnError &&
        [self.cache hasResponseForRequest:self]) {

        [self didFinishLoad:[self.cache responseForRequest:self]];
    } else {
        if ([_delegate respondsToSelector:@selector(request:didFailLoadWithError:)]) {
            [_delegate request:self didFailLoadWithError:error];
        }

        if (self.onDidFailLoadWithError) {
            self.onDidFailLoadWithError(error);
        }

        // If we failed due to a transport error or before we have a response, the request itself failed
        if (!self.response || [self.response isFailure]) {
            NSDictionary* userInfo = [NSDictionary dictionaryWithObject:error forKey:RKRequestDidFailWithErrorNotificationUserInfoErrorKey];
            [[NSNotificationCenter defaultCenter] postNotificationName:RKRequestDidFailWithErrorNotification
                                                                object:self
                                                              userInfo:userInfo];
        }
        
        if (! self.isCancelled) {
            [self informDelegateOfError:error];
        }

        [self finalizeLoad:NO];
    }

    [pool release];
}

// NOTE: We do NOT call super here. We are overloading the default behavior from RKRequest
- (void)didFinishLoad:(RKResponse*)response {
    // Capture objectIDs on main thread before entering background block.
    // Accessing managed objects directly from the background thread is unsafe.
    [_targetObjectID release];
    _targetObjectID = nil;
    if ([self.targetObject isKindOfClass:[NSManagedObject class]]) {
        _targetObjectID = [[(NSManagedObject *)self.targetObject objectID] retain];
    }
    [_sourceObjectID release];
    _sourceObjectID = nil;
    if ([self.sourceObject isKindOfClass:[NSManagedObject class]]) {
        _sourceObjectID = [[(NSManagedObject *)self.sourceObject objectID] retain];
    }

    // Create a fresh sibling context for this request.
    // This ensures no stale data and direct saves to the persistent store.
    [_mappingContext release];
    _mappingContext = [[RKManagedObjectStore defaultObjectStore] newBackgroundContext];

    [_mappingContext performBlock:^{
        self.response = response;

        if ((_cachePolicy & RKRequestCachePolicyEtag) && [response isNotModified]) {
            self.response = [self.cache responseForRequest:self];
            NSAssert(self.response, @"Unexpectedly loaded nil response from cache");
            [self updateInternalCacheDate];
        }

        if (![self.response wasLoadedFromCache] && [self.response isSuccessful] && (_cachePolicy != RKRequestCachePolicyNone)) {
            [self.cache storeResponse:self.response forRequest:self];
        }

        if ([_delegate respondsToSelector:@selector(request:didLoadResponse:)]) {
            [_delegate request:self didLoadResponse:self.response];
        }

        if (self.onDidLoadResponse) {
            self.onDidLoadResponse(self.response);
        }

        // Post the notification
        NSDictionary* userInfo = [NSDictionary dictionaryWithObject:self.response
                                                             forKey:RKRequestDidLoadResponseNotificationUserInfoResponseKey];
        [[NSNotificationCenter defaultCenter] postNotificationName:RKRequestDidLoadResponseNotification
                                                            object:self
                                                          userInfo:userInfo];

        if ([self isResponseMappable]) {
            // Determine if we are synchronous here or not.
            if (_sentSynchronously) {
                NSError* error = nil;
                _result = [[self performMapping:&error] retain];
                if (self.result) {
                    [self processMappingResult:self.result];
                } else {
                    [self performSelectorInBackground:@selector(didFailLoadWithError:) withObject:error];
                }
            } else {
                [self performMappingInDispatchQueue];
            }
        }
    }];
}

// Proxy the delegate property back to our superclass implementation. The object loader should
// really not be a subclass of RKRequest.
- (void)setDelegate:(id<RKObjectLoaderDelegate>)delegate {
    [super setDelegate:delegate];
}

- (id<RKObjectLoaderDelegate>)delegate {
    return (id<RKObjectLoaderDelegate>) [super delegate];
}

@end

@implementation RKObjectLoader (Deprecations)

+ (id)loaderWithResourcePath:(NSString*)resourcePath objectManager:(RKObjectManager*)objectManager delegate:(id<RKObjectLoaderDelegate>)delegate {
    return [[[self alloc] initWithResourcePath:resourcePath objectManager:objectManager delegate:delegate] autorelease];
}

- (id)initWithResourcePath:(NSString*)resourcePath objectManager:(RKObjectManager*)objectManager delegate:(id<RKObjectLoaderDelegate>)theDelegate {
    if ((self = [self initWithURL:[objectManager.baseURL URLByAppendingResourcePath:resourcePath] mappingProvider:objectManager.mappingProvider])) {
        [objectManager.client configureRequest:self];
        _delegate = theDelegate;
    }

    return self;
}

@end
