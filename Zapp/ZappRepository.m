//
//  ZappRepository.m
//  Zapp
//
//  Created by Jim Puls on 8/5/11.
//  Copyright (c) 2011 Square, Inc. All rights reserved.
//

#import "ZappRepository.h"
#import "ZappSSHURLFormatter.h"


static NSOperationQueue *ZappRepositoryBackgroundQueue = nil;
NSString *const GitCommand = @"/usr/bin/git";
NSString *const XcodebuildCommand = @"/usr/bin/xcodebuild";


@interface ZappRepository ()

@property (nonatomic, strong) NSMutableSet *enqueuedCommands;
@property (nonatomic, strong, readwrite) NSArray *platforms;
@property (nonatomic, strong, readwrite) NSArray *schemes;
@property (nonatomic, strong, readwrite) NSString *workspacePath;

- (void)registerObservers;
- (void)unregisterObservers;

@end

@implementation ZappRepository

@dynamic builds;
@dynamic clonedAlready;
@dynamic lastPlatform;
@dynamic lastScheme;
@dynamic latestBuildStatus;
@dynamic localURL;
@dynamic name;
@dynamic remoteURL;

@synthesize enqueuedCommands;
@synthesize platforms;
@synthesize schemes;
@synthesize workspacePath;

#pragma mark Class methods

+ (void)initialize;
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZappRepositoryBackgroundQueue = [NSOperationQueue new];
    });
}

+ (NSOperationQueue *)sharedBackgroundQueue;
{
    return ZappRepositoryBackgroundQueue;
}

#pragma mark Derived properties

- (NSArray *)platforms;
{
    if (!platforms && ![self.enqueuedCommands containsObject:@"platforms"] && self.clonedAlready) {
        [self.enqueuedCommands addObject:@"platforms"];
        [self runCommand:XcodebuildCommand withArguments:[NSArray arrayWithObject:@"-showsdks"] completionBlock:^(NSString *output) {
            NSRegularExpression *platformRegex = [NSRegularExpression regularExpressionWithPattern:@"Simulator - iOS (\\S+)" options:0 error:NULL];
            NSMutableArray *newPlatforms = [NSMutableArray array];
            [platformRegex enumerateMatchesInString:output options:0 range:NSMakeRange(0, output.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                NSString *version = [output substringWithRange:[result rangeAtIndex:1]];
                [newPlatforms addObject:[NSDictionary dictionaryWithObjectsAndKeys:version, @"version", @"iphone", @"device", [NSString stringWithFormat:ZappLocalizedString(@"iPhone %@ Simulator"), version], @"description", nil]];
                [newPlatforms addObject:[NSDictionary dictionaryWithObjectsAndKeys:version, @"version", @"ipad", @"device", [NSString stringWithFormat:ZappLocalizedString(@"iPad %@ Simulator"), version], @"description", nil]];
            }];
            self.platforms = newPlatforms;
            if (!self.lastPlatform) {
                self.lastPlatform = [self.platforms lastObject];
            }
            [self.enqueuedCommands removeObject:@"platforms"];
        }];
    }
    return platforms;
}

+ (NSSet *)keyPathsForValuesAffectingPlatforms;
{
    return [NSSet setWithObjects:@"localURL", @"clonedAlready", nil];
}

- (NSArray *)schemes;
{
    if (!schemes && ![self.enqueuedCommands containsObject:@"schemes"] && self.clonedAlready) {
        [self.enqueuedCommands addObject:@"schemes"];
        [self runCommand:XcodebuildCommand withArguments:[NSArray arrayWithObject:@"-list"] completionBlock:^(NSString *output) {
            NSRange schemeRange = [output rangeOfString:@"Schemes:\n"];
            if (schemeRange.location == NSNotFound) {
                [self.enqueuedCommands removeObject:@"schemes"];
                return;
            }
            NSMutableArray *newSchemes = [NSMutableArray array];
            NSUInteger start = schemeRange.location + schemeRange.length;
            NSRegularExpression *schemeRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\s+(.+)$" options:NSRegularExpressionAnchorsMatchLines error:NULL];
            [schemeRegex enumerateMatchesInString:output options:0 range:NSMakeRange(start, output.length - start) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                [newSchemes addObject:[output substringWithRange:[result rangeAtIndex:1]]];
            }];
            self.schemes = newSchemes;
            if (!self.lastScheme) {
                self.lastScheme = [self.schemes lastObject];
            }
            [self.enqueuedCommands removeObject:@"schemes"];
        }];
    }
    return schemes;
}

+ (NSSet *)keyPathsForValuesAffectingSchemes;
{
    return [NSSet setWithObjects:@"localURL", @"clonedAlready", nil];
}

- (NSString *)workspacePath;
{
    if (!workspacePath && ![self.enqueuedCommands containsObject:@"workspacePath"] && self.clonedAlready) {
        [self.enqueuedCommands addObject:@"workspacePath"];
        [self runCommand:XcodebuildCommand withArguments:[NSArray arrayWithObject:@"-list"] completionBlock:^(NSString *output) {
            NSRange workspaceRange = [output rangeOfString:@"wrapper workspace:\n"];
            if (workspaceRange.location == NSNotFound) {
                [self.enqueuedCommands removeObject:@"workspacePath"];
                return;
            }
            NSUInteger start = workspaceRange.location;
            NSRegularExpression *workspaceRegex = [NSRegularExpression regularExpressionWithPattern:@"workspace:\\s+(.+)\n" options:0 error:NULL];
            [workspaceRegex enumerateMatchesInString:output options:0 range:NSMakeRange(start, output.length - start) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                self.workspacePath = [output substringWithRange:[result rangeAtIndex:1]];
                *stop = YES;
            }];
            [self.enqueuedCommands removeObject:@"workspacePath"];
        }];
    }
    return workspacePath;
}

+ (NSSet *)keyPathsForValuesAffectingWorkspacePath;
{
    return [NSSet setWithObjects:@"localURL", @"clonedAlready", nil];
}

- (NSImage *)statusImage;
{
    return [NSImage imageNamed:self.latestBuildStatus == ZappBuildStatusSucceeded ? @"status-available-flat-etched" : @"status-away-flat-etched"];
}

+ (NSSet *)keyPathsForValuesAffectingStatusImage;
{
    return [NSSet setWithObject:@"latestBuildStatus"];
}

#pragma mark ZappRepository

- (ZappBuild *)createNewBuild;
{
    ZappBuild *build = [NSEntityDescription insertNewObjectForEntityForName:@"Build" inManagedObjectContext:self.managedObjectContext];
    [self willChangeValueForKey:@"latestBuild"];
    [self addBuildsObject:build];
    [self didChangeValueForKey:@"latestBuild"];
    return build;
}

- (int)runCommandAndWait:(NSString *)command withArguments:(NSArray *)arguments errorOutput:(NSString **)errorString outputBlock:(void (^)(NSString *))block;
{
    NSAssert(![NSThread isMainThread], @"Can only run command and wait from a background thread");
    NSTask *task = [NSTask new];
    
    NSPipe *outPipe = [NSPipe new];
    NSFileHandle *outHandle = [outPipe fileHandleForReading];
    [task setStandardOutput:outPipe];
    
    NSPipe *errorPipe = [NSPipe new];
    NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
    [task setStandardError:errorPipe];
    
    NSData *inData = nil;
    [task setLaunchPath:command];
    [task setArguments:arguments];
    [task setCurrentDirectoryPath:self.localURL.path];
    
    [task launch];
    
    while ((inData = [outHandle availableData]) && [inData length]) {
        NSString *inString = [[NSString alloc] initWithData:inData encoding:NSUTF8StringEncoding];
        block(inString);
    }
    
    [task waitUntilExit];
    
    NSData *errorData = [errorHandle readDataToEndOfFile];
    if (errorString) {
        *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
    }
    
    return [task terminationStatus];
}

- (void)runCommand:(NSString *)command withArguments:(NSArray *)arguments completionBlock:(void (^)(NSString *))block;
{
    NSAssert([NSThread isMainThread], @"Can only spawn a command from the main thread");
    if (!self.localURL) {
        self.clonedAlready = NO;
        return;
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:self.localURL.path isDirectory:&isDirectory] || !isDirectory) {
        self.clonedAlready = NO;
        return;
    }
    
    [ZappRepositoryBackgroundQueue addOperationWithBlock:^() {
        NSString *errorString = nil;
        
        NSMutableString *finalString = [NSMutableString string];
        [self runCommandAndWait:command withArguments:arguments errorOutput:&errorString outputBlock:^(NSString *inString) {
            [finalString appendString:inString];
        }];
        
        if ([command isEqualToString:GitCommand] && errorString.length) {
            if ([errorString rangeOfString:@"Not a git repository"].location != NSNotFound) {
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    self.clonedAlready = NO;
                }];
                return;
            }
        }
        
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            self.clonedAlready = YES;
            block([finalString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        }];
    }];
}

#pragma mark NSManagedObject

- (void)awakeFromFetch;
{
    [super awakeFromFetch];
    [self registerObservers];
    self.enqueuedCommands = [NSMutableSet set];
}

- (void)awakeFromInsert;
{
    [super awakeFromInsert];
    [self registerObservers];
    self.enqueuedCommands = [NSMutableSet set];
}

- (void)didTurnIntoFault;
{
    self.enqueuedCommands = nil;
    [self unregisterObservers];
    [super didTurnIntoFault];
}

#pragma mark NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context;
{
    if ([keyPath isEqualToString:@"localURL"]) {
        [self runCommand:GitCommand withArguments:[NSArray arrayWithObjects:@"remote", @"-v", nil] completionBlock:^(NSString *output) {
            NSRegularExpression *remotePattern = [[NSRegularExpression alloc] initWithPattern:@"^\\w+\\s+(\\S+)\\s+" options:0 error:NULL];
            ZappSSHURLFormatter *formatter = [[ZappSSHURLFormatter alloc] init];
            [remotePattern enumerateMatchesInString:output options:NSMatchingAnchored range:NSMakeRange(0, output.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                NSURL *newRemoteURL = nil;
                if ([formatter getObjectValue:&newRemoteURL forString:[output substringWithRange:[result rangeAtIndex:1]] errorDescription:NULL]) {
                    self.remoteURL = newRemoteURL;
                    *stop = YES;
                }
            }];
        }];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark Private methods

- (void)registerObservers;
{
    [self addObserver:self forKeyPath:@"localURL" options:NSKeyValueObservingOptionNew context:NULL];
}

- (void)unregisterObservers;
{
    [self removeObserver:self forKeyPath:@"localURL"];
}

@end