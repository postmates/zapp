//
//  ZappAppDelegate.m
//  Zapp
//
//  Created by Jim Puls on 7/30/11.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.

#import "ZappAppDelegate.h"
#import "ZappBackgroundView.h"
#import "ZappRepositoriesController.h"
#import "ZappWebServer.h"
#import "ZappSSHURLFormatter.h"
#import "iPhoneSimulatorRemoteClient.h"


@interface ZappAppDelegate ()

@property (nonatomic, strong) NSMutableArray *buildQueue;
@property (nonatomic, readonly) ZappRepository *selectedRepository;

- (void)hideProgressPanel;
- (void)pollRepositoriesForUpdates;
- (void)pumpBuildQueue;
- (ZappBuild *)scheduleBuildForRepository:(ZappRepository *)repository;
- (void)showProgressPanelWithMessage:(NSString *)message;
- (void)updateSourceListBackground:(NSNotification *)notification;

@end


@implementation ZappAppDelegate

@synthesize activityButton;
@synthesize activityController;
@synthesize building;
@synthesize activitySplitView;
@synthesize buildQueue;
@synthesize activityTableView;
@synthesize buildsController;
@synthesize logController;
@synthesize logScrollView;
@synthesize platformPopup;
@synthesize progressIndicator;
@synthesize progressLabel;
@synthesize progressPanel;
@synthesize repositoriesController;
@synthesize schemePopup;
@synthesize searchBackgroundView;
@synthesize sourceListBackgroundView;
@synthesize sourceListView;
@synthesize window;

#pragma mark Accessors

- (ZappRepository *)selectedRepository;
{
    return [[self.repositoriesController selectedObjects] lastObject];
}

#pragma mark UI Actions

- (IBAction)build:(id)sender;
{
    [self scheduleBuildForRepository:self.selectedRepository];
    [self.buildsController setSelectionIndex:0];
}

- (IBAction)chooseLocalPath:(id)sender;
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = NO;
    openPanel.canChooseDirectories = YES;
    openPanel.canCreateDirectories = YES;
    [openPanel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton) {
            ZappRepository *currentRepository = [self.repositoriesController.selectedObjects lastObject];
            currentRepository.localURL = openPanel.URL;
        }
    }];
}

- (IBAction)clone:(id)sender;
{
    ZappRepository *repository = self.selectedRepository;
    ZappSSHURLFormatter *formatter = [ZappSSHURLFormatter new];
    NSString *formattedURL = [formatter stringForObjectValue:repository.remoteURL];
    [self showProgressPanelWithMessage:[NSString stringWithFormat:ZappLocalizedString(@"Cloning %@…"), formattedURL]];
    [repository runCommand:GitCommand withArguments:[NSArray arrayWithObjects:@"clone", formattedURL, repository.localURL.path, nil] completionBlock:^(NSString *output) {
        [self hideProgressPanel];
        [self scheduleBuildForRepository:repository];
    }];
}

- (IBAction)toggleActivity:(id)sender;
{
    NSRect boundsRect = activitySplitView.bounds;
    CGFloat multiplier = 0.8;
    if (activityButton.state == NSOffState) {
        multiplier = 1.0;
    }
    
    NSRect newTopFrame, newBottomFrame;
    NSDivideRect(boundsRect, &newTopFrame, &newBottomFrame, multiplier * boundsRect.size.height, NSMaxYEdge);
    
    newBottomFrame.size.height -= activitySplitView.dividerThickness;
    [[[[activitySplitView subviews] objectAtIndex:0] animator] setFrame:newTopFrame];
    [[[[activitySplitView subviews] objectAtIndex:1] animator] setFrame:newBottomFrame];
}

- (IBAction)cancelBuild:(id)sender;
{
    NSInteger row = [self.activityTableView rowForView:sender];
    ZappBuild *build = [self.buildQueue objectAtIndex:row];
    
    if (build.status == ZappBuildStatusPending) {
        [self.activityController removeObject:build];
    }
    
    [build cancel];
}

#pragma mark NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification;
{
    [self updateSourceListBackground:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateSourceListBackground:) name:NSApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateSourceListBackground:) name:NSApplicationDidResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(contextDidChange:) name:NSManagedObjectContextObjectsDidChangeNotification object:nil];
    
    [self toggleActivity:nil];
    
    self.buildQueue = [NSMutableArray array];
    
    NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"startTimestamp" ascending:NO];
    self.buildsController.sortDescriptors = [NSArray arrayWithObject:sortDescriptor];

    self.searchBackgroundView.backgroundGradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithDeviceWhite:0.929 alpha:1.0] endingColor:[NSColor colorWithDeviceWhite:0.851 alpha:1.0]];
    self.searchBackgroundView.borderWidth = 1.0;
    self.searchBackgroundView.borderColor = [NSColor colorWithDeviceWhite:0.75 alpha:1.0];
    [self.searchBackgroundView setNeedsDisplay:YES];
    
    [self.logController addObserver:self forKeyPath:@"content" options:0 context:NULL];
    [self.logController addObserver:self forKeyPath:@"filterPredicate" options:0 context:NULL];
    
    [NSTimer scheduledTimerWithTimeInterval:90.0 target:self selector:@selector(pollRepositoriesForUpdates) userInfo:nil repeats:YES];
    
    NSManagedObjectContext *newContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
    newContext.persistentStoreCoordinator = self.repositoriesController.managedObjectContext.persistentStoreCoordinator;
    [ZappWebServer startWithManagedObjectContext:newContext];
}

#pragma mark NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context;
{
    if ([object isEqual:self.logController]) {
        // Either the content changed or the filter predicate changed
        NSPoint newScrollOrigin;
        NSTableView *logTableView = [self.logScrollView documentView];
        if ([self.logController.selectionIndexes count]) {
            if ([keyPath isEqualToString:@"filterPredicate"]) {
                // If we have a selection, scroll to the first row of it
                NSInteger filteredSelectionIndex = [self.logController.arrangedObjects indexOfObject:[self.logController.selectedObjects objectAtIndex:0]];
                NSRect rowRect = [logTableView rectOfRow:filteredSelectionIndex];
                newScrollOrigin = rowRect.origin;
            } else {
                return;
            }
        } else {
            // If there's no selection, scroll to the bottom
            if ([[self.logScrollView documentView] isFlipped]) {
                newScrollOrigin = NSMakePoint(0.0, NSMaxY([[self.logScrollView documentView] frame]) - NSHeight([[self.logScrollView contentView] bounds]));
            } else {
                newScrollOrigin = NSZeroPoint;
            }
        }
        [logTableView scrollPoint:newScrollOrigin];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark Private methods

- (void)contextDidChange:(NSNotification *)notification;
{
    NSManagedObjectContext *context = notification.object;

    NSSet *insertedObjects = [notification.userInfo objectForKey:NSInsertedObjectsKey];
    ZappRepository *newRepository = [insertedObjects anyObject];
    if (insertedObjects && [newRepository isKindOfClass:[ZappRepository class]]) {
        // No need to save a new repository, turn on editing instead
        NSInteger row = [[self.repositoriesController arrangedObjects] indexOfObject:newRepository];
        [self.sourceListView editColumn:0 row:row withEvent:nil select:YES];
    } else {
        NSError *error = nil;
        [context save:&error];
        NSAssert(!error, @"Should not have encountered error saving context");
    }
}

- (void)hideProgressPanel;
{
    [self.progressPanel orderOut:nil];
    [[NSApplication sharedApplication] endSheet:self.progressPanel];
}

- (void)pollRepositoriesForUpdates;
{
    if (self.building) {
        return;
    }
    for (ZappRepository *repository in [self.repositoriesController arrangedObjects]) {
        [repository runCommand:GitCommand withArguments:[NSArray arrayWithObjects:GitFetchSubcommand, @"--prune", nil] completionBlock:^(NSString *output) {
            [repository runCommand:GitCommand withArguments:[NSArray arrayWithObjects:@"rev-parse", repository.lastBranch, nil] completionBlock:^(NSString *output) {
                NSArray *builds = [self.repositoriesController.managedObjectContext executeFetchRequest:repository.latestBuildsFetchRequest error:nil];
                if (!builds.count || ![[[builds objectAtIndex:0] latestRevision] isEqualToString:output]) {
                    [self scheduleBuildForRepository:repository];
                }
            }];
        }];
    }
}

- (void)pumpBuildQueue;
{
    [self.activityController rearrangeObjects];
    if (!self.buildQueue.count || self.building) {
        return;
    }
    ZappBuild *build = [self.buildQueue objectAtIndex:0];
    self.building = YES;
    [build startWithCompletionBlock:^{
        self.building = NO;
        [self.buildQueue removeObject:build];
        [self pumpBuildQueue];
    }];
}

- (ZappBuild *)scheduleBuildForRepository:(ZappRepository *)repository;
{
    ZappBuild *build = [repository createNewBuild];
    build.startTimestamp = [NSDate date];
    [repository runCommand:GitCommand withArguments:[NSArray arrayWithObjects:@"rev-parse", repository.lastBranch, nil] completionBlock:^(NSString *revision) {
        build.latestRevision = revision;
        [self.buildQueue addObject:build];
        [self pumpBuildQueue];
    }];
    [self.buildsController rearrangeObjects];
    return build;
}

- (void)showProgressPanelWithMessage:(NSString *)message;
{
    self.progressLabel.stringValue = message;
    [self.progressIndicator startAnimation:nil];
    [[NSApplication sharedApplication] beginSheet:self.progressPanel modalForWindow:self.window modalDelegate:nil didEndSelector:nil contextInfo:NULL];
}

- (void)updateSourceListBackground:(NSNotification *)notification;
{
    NSApplication *application = [NSApplication sharedApplication];
    if ([application isActive]) {
        self.sourceListBackgroundView.backgroundColor = [NSColor colorWithDeviceRed:0.824 green:0.851 blue:0.882 alpha:1.0];
    } else {
        self.sourceListBackgroundView.backgroundColor = [NSColor windowBackgroundColor];
    }
    [self.sourceListBackgroundView setNeedsDisplay:YES];
}

@end
