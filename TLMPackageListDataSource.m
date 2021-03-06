//
//  TLMPackageListDataSource.m
//  TeX Live Utility
//
//  Created by Adam Maxwell on 12/22/08.
/*
 This software is Copyright (c) 2008-2016
 Adam Maxwell. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:
 
 - Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 - Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in
 the documentation and/or other materials provided with the
 distribution.
 
 - Neither the name of Adam Maxwell nor the names of any
 contributors may be used to endorse or promote products derived
 from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "TLMPackageListDataSource.h"
#import "TLMPackageNode.h"
#import "TLMInfoController.h"
#import "TLMOutlineView.h"

@implementation TLMPackageListDataSource

@synthesize outlineView = _outlineView;
@synthesize packageNodes = _packageNodes;
@synthesize _searchField;
@synthesize _controller;
@synthesize statusWindow = _statusWindow;
@synthesize refreshing = _refreshing;
@synthesize needsUpdate = _needsUpdate;

- (id)init
{
    self = [super init];
    if (self) {
        _displayedPackageNodes = [NSMutableArray new];
        _sortDescriptors = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc
{
    _controller = nil;
    [_outlineView setDelegate:nil];
    [_outlineView setDataSource:nil];
    [_outlineView release];
    [_packageNodes release];
    [_displayedPackageNodes release];
    [_searchField release];
    [_sortDescriptors release];
    [_statusWindow release];
    [super dealloc];
}

- (void)awakeFromNib
{
    [_outlineView setFontNamePreferenceKey:@"TLMPackageListTableFontName" 
                         sizePreferenceKey:@"TLMPackageListTableFontSize"];
    [_outlineView setDoubleAction:@selector(showInfo:)];
    [_outlineView setTarget:self];
}

- (void)setPackageNodes:(NSArray *)nodes
{
    [_packageNodes autorelease];
    _packageNodes = [nodes copy];
    [self search:nil];
}

- (IBAction)showInfo:(id)sender;
{
    if ([self selectedItem] != nil)
        [[TLMInfoController sharedInstance] showInfoForPackage:[self selectedItem] location:[_controller serverURL]];
    else if ([[[TLMInfoController sharedInstance] window] isVisible] == NO) {
        [[TLMInfoController sharedInstance] showInfoForPackage:nil location:[_controller serverURL]];
        [[TLMInfoController sharedInstance] showWindow:nil];
    }
}

- (IBAction)refreshList:(id)sender;
{
    [_controller refreshFullPackageList];
}

- (IBAction)installSelectedRows:(id)sender;
{
    NSArray *selItems = [_outlineView selectedItems];
    
    // see if we need to do a reinstall
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(isInstalled == YES)"];
    NSArray *packages = [selItems filteredArrayUsingPredicate:predicate];

    [_controller installPackagesWithNames:[selItems valueForKey:@"fullName"] reinstall:([packages count] > 0)];
}

// install automatically does this, so the action is only implemented here for symmetry
- (IBAction)reinstallSelectedRows:(id)sender;
{
    NSArray *selItems = [_outlineView selectedItems];
    [_controller installPackagesWithNames:[selItems valueForKey:@"fullName"] reinstall:YES];
}

- (IBAction)removeSelectedRows:(id)sender;
{
    NSArray *packageNames = [[_outlineView selectedItems] valueForKey:@"fullName"];
    [_controller removePackagesWithNames:packageNames force:NO];
}

- (IBAction)forciblyRemoveSelectedRows:(id)sender;
{
    NSArray *packageNames = [[_outlineView selectedItems] valueForKey:@"fullName"];
    [_controller removePackagesWithNames:packageNames force:YES];
}  

- (BOOL)_validateRemoveSelectedRow
{
    if ([_packageNodes count] == 0)
        return NO;
    
    if ([[_outlineView selectedRowIndexes] count] == 0)
        return NO;
    
    // be strict about this; only installed packages can be removed
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"isInstalled == NO"];
    if ([[[_outlineView selectedItems] filteredArrayUsingPredicate:predicate] count])
        return NO;
    
    return YES;
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)anItem;
{
    SEL action = [anItem action];
    if (@selector(showInfo:) == action)
        return [[[TLMInfoController sharedInstance] window] isVisible] == NO;
    else if (@selector(removeSelectedRows:) == action || @selector(forciblyRemoveSelectedRows:) == action)
        return [self _validateRemoveSelectedRow];
    else if (@selector(installSelectedRows:) == action || @selector(reinstallSelectedRows:) == action)
        return [[_outlineView selectedRowIndexes] count] > 0;
    else if (@selector(refreshList:) == action)
        return NO == _refreshing;
    else
        return YES;
}

- (id)selectedItem
{
    return [_outlineView selectedRow] != -1 ? [_outlineView itemAtRow:[_outlineView selectedRow]] : nil;
}

- (IBAction)search:(id)sender;
{
    NSString *searchString = [_searchField stringValue];
    NSArray *selectedItems = [_outlineView selectedItems];
    
    if (nil == searchString || [searchString isEqualToString:@""]) {
        [_displayedPackageNodes setArray:_packageNodes];
    }
    else {
        [_displayedPackageNodes removeAllObjects];
        for (TLMPackageNode *node in _packageNodes) {
            if ([node matchesSearchString:searchString])
                [_displayedPackageNodes addObject:node];
        }
    }
    [_displayedPackageNodes sortUsingDescriptors:_sortDescriptors];    
    [_outlineView reloadData];
    
    // restore previously selected packages, if possible
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    for (id item in selectedItems) {
        NSInteger idx = [_outlineView rowForItem:item];
        if (-1 != idx)
            [indexes addIndex:idx];
    }
    [_outlineView selectRowIndexes:indexes byExtendingSelection:NO];
}

#pragma mark NSOutlineView datasource

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)anIndex ofItem:(TLMPackageNode *)item;
{
    return (nil == item) ? [_displayedPackageNodes objectAtIndex:anIndex] : [item childAtIndex:anIndex];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(TLMPackageNode *)item;
{
    return (nil == item) ? YES : [item numberOfChildren];
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(TLMPackageNode *)item;
{
    return (nil == item) ? [_displayedPackageNodes count] : [item numberOfChildren];
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item;
{
    return [item valueForKey:[tableColumn identifier]];
}

#pragma mark NSOutlineView delegate

- (void)outlineView:(NSOutlineView *)outlineView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn item:(id)item;
{
    TLMPackageNode *node = item;
    if ([node hasMixedStatus])
        [cell setTextColor:[NSColor purpleColor]];
    else if ([node isInstalled] == NO)
        [cell setTextColor:[NSColor blueColor]];
    else
        [cell setTextColor:[NSColor blackColor]];
}

- (void)outlineView:(NSOutlineView *)outlineView didClickTableColumn:(NSTableColumn *)tableColumn;
{
    _sortAscending = !_sortAscending;
    
    for (NSTableColumn *col in [outlineView tableColumns])
        [outlineView setIndicatorImage:nil inTableColumn:col];
    NSImage *image = _sortAscending ? [NSImage imageNamed:@"NSAscendingSortIndicator"] : [NSImage imageNamed:@"NSDescendingSortIndicator"];
    [outlineView setIndicatorImage:image inTableColumn:tableColumn];
    
    NSString *key = [tableColumn identifier];
    NSSortDescriptor *sort = nil;
    
    // all string keys, so do a simple comparison
    sort = [[NSSortDescriptor alloc] initWithKey:key ascending:_sortAscending selector:@selector(localizedCaseInsensitiveCompare:)];
    [sort autorelease];
    
    // make sure we're not duplicating any descriptors (possibly with reversed order)
    NSUInteger cnt = [_sortDescriptors count];
    while (cnt--) {
        if ([[[_sortDescriptors objectAtIndex:cnt] key] isEqualToString:key])
            [_sortDescriptors removeObjectAtIndex:cnt];
    }
    
    // push the new sort descriptor, which is correctly ascending/descending
    if (sort) [_sortDescriptors insertObject:sort atIndex:0];
    
    // pop the last sort descriptor, if we have more sort descriptors than table columns
    while ((NSInteger)[_sortDescriptors count] > [outlineView numberOfColumns])
        [_sortDescriptors removeLastObject];
    
    NSArray *selectedItems = [_outlineView selectedItems];
    
    [_displayedPackageNodes sortUsingDescriptors:_sortDescriptors];
    [outlineView reloadData];
    
    // restore selection
    NSMutableIndexSet *selRows = [NSMutableIndexSet indexSet];
    for (id item in selectedItems) {
        NSInteger row = [_outlineView rowForItem:item];
        if (row != -1)
            [selRows addIndex:row];
    }
    [outlineView selectRowIndexes:selRows byExtendingSelection:NO];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification;
{
    if ([[[TLMInfoController sharedInstance] window] isVisible]) {
        // reset for multiple selection or empty selection
        if ([_outlineView numberOfSelectedRows] != 1)
            [[TLMInfoController sharedInstance] showInfoForPackage:nil location:[_controller serverURL]];
        else
            [self showInfo:nil];
    }
    
    // toolbar updating is somewhat erratic, so force it to validate here
    [[[_controller window] toolbar] validateVisibleItems];
}

- (NSMenu *)tableView:(NSTableView *)tableView contextMenuForRow:(NSInteger)row column:(NSInteger)column;
{
    NSZone *zone = [NSMenu menuZone];
    NSMenu *menu = [[[NSMenu allocWithZone:zone] init] autorelease];
    
    NSMenuItem *item = [[NSMenuItem allocWithZone:zone] initWithTitle:NSLocalizedString(@"Install Selected Packages", @"context menu")
                                                               action:@selector(installSelectedRows:)
                                                        keyEquivalent:@""];
    [item setAction:@selector(installSelectedRows:)];
    [item setTarget:self];
    if ([self validateUserInterfaceItem:item])
        [menu addItem:item];
    [item release];
    
    item = [[NSMenuItem allocWithZone:zone] initWithTitle:NSLocalizedString(@"Reinstall Selected Packages", @"context menu")
                                                   action:@selector(reinstallSelectedRows:)
                                            keyEquivalent:@""];
    [item setAction:@selector(reinstallSelectedRows:)];
    [item setTarget:self];
    if ([self validateUserInterfaceItem:item])
        [menu addItem:item];
    [item release];
    
    item = [[NSMenuItem allocWithZone:zone] initWithTitle:NSLocalizedString(@"Remove Selected Packages", @"context menu")
                                                   action:@selector(removeSelectedRows:)
                                            keyEquivalent:@""];
    [item setAction:@selector(removeSelectedRows:)];
    [item setTarget:self];
    
    // if we add remove, let's try to add forcible removal as the alternate, same as in the main menu
    if ([self validateUserInterfaceItem:item]) {
        [menu addItem:item];
        [item release];

        item = [[NSMenuItem allocWithZone:zone] initWithTitle:NSLocalizedString(@"Forcibly Remove Selected Packages", @"context menu")
                                                       action:@selector(forciblyRemoveSelectedRows:)
                                                keyEquivalent:@""];
        [item setAction:@selector(forciblyRemoveSelectedRows:)];
        [item setTarget:self];
        [item setAlternate:YES];
        [item setKeyEquivalentModifierMask:NSAlternateKeyMask];
        if ([self validateUserInterfaceItem:item])
            [menu addItem:item];
    }
    [item release];
    
    if ([menu numberOfItems])
        [menu addItem:[NSMenuItem separatorItem]];
    
    item = [[NSMenuItem allocWithZone:zone] initWithTitle:NSLocalizedString(@"Show Info", @"context menu")
                                                   action:@selector(showInfo:)
                                            keyEquivalent:@""];
    [item setAction:@selector(showInfo:)];
    [item setTarget:self];
    if ([self validateUserInterfaceItem:item])
        [menu addItem:item];
    [item release];
    
    return [menu numberOfItems] ? menu : nil;
}

@end
