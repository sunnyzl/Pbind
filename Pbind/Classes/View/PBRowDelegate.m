//
//  PBRowDelegate.m
//  Pbind <https://github.com/wequick/Pbind>
//
//  Created by Galen Lin on 22/12/2016.
//  Copyright (c) 2015-present, Wequick.net. All rights reserved.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "PBRowDelegate.h"
#import "UIView+Pbind.h"
#import "PBSection.h"
#import "PBActionStore.h"
#import "PBCollectionView.h"
#import "PBDataFetcher.h"
#import "PBDataFetching.h"
#import "PBHeaderFooterMapper.h"
#import "PBSectionView.h"
#import "PBLoadMoreControlMapper.h"

@implementation PBRowDelegate

@synthesize receiver;

static const CGFloat kMinRefreshControlDisplayingTime = .75f;

#pragma mark - Common

- (instancetype)initWithDataSource:(PBRowDataSource *)dataSource {
    if (self = [super init]) {
        self.dataSource = dataSource;
    }
    return self;
}

#pragma mark - Paging

- (void)beginRefreshingForPagingView:(UIScrollView<PBRowPaging> *)pagingView {
    if (_refreshControl == nil) {
        return;
    }
    
    if (_refreshControl.isRefreshing) {
        return;
    }
    
    CGPoint offset = pagingView.contentOffset;
    offset.y = -pagingView.contentInset.top - _refreshControl.bounds.size.height;
    pagingView.contentOffset = offset;
    [_refreshControl beginRefreshing];
    [_refreshControl sendActionsForControlEvents:UIControlEventValueChanged];
}

- (PBRowControlMapper *)more {
    if (_more == nil) {
        if ([self.dataSource.owner conformsToProtocol:@protocol(PBRowPaging)]) {
            NSDictionary *info = [(id)self.dataSource.owner more];
            if (info) {
                _more = [PBLoadMoreControlMapper mapperWithDictionary:info];
            }
        }
    }
    return _more;
}

- (void)scrollViewDidScroll:(UIScrollView<PBRowPaging> *)pagingView {
    if ([self.receiver respondsToSelector:_cmd]) {
        [self.receiver scrollViewDidScroll:pagingView];
    }
    
    if (pagingView.pagingParams == nil) {
        return;
    }
    
    if (_loadMoreControl != nil && ![_loadMoreControl isEnabled]) {
        return;
    }
    
    CGPoint contentOffset = pagingView.contentOffset;
    UIEdgeInsets contentInset = pagingView.contentInset;
    CGFloat height = pagingView.bounds.size.height;
    CGFloat pulledUpDistance = (contentOffset.y + contentInset.top + height) - MAX((pagingView.contentSize.height + contentInset.bottom + contentInset.top), height);
    
    if (pulledUpDistance <= 0) {
        // Pull down to refresh
        if (_refreshControl == nil) {
            UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
            [refreshControl addTarget:self action:@selector(refreshControlDidReleased:) forControlEvents:UIControlEventValueChanged];
            [pagingView addSubview:refreshControl];
            _refreshControl = refreshControl;
        }
    }
    
    // Pull up to load more
    if (![pagingView isDragging]) {
        return;
    }
    PBRowControlMapper *moreMapper = self.more;
    if (moreMapper == nil) {
        return;
    }
    
    UIView *owner = pagingView;
    id data = owner.rootData;
    [moreMapper updateWithData:data owner:pagingView context:pagingView];
    
    if (_loadMoreControl == nil) {
        PBLoadMoreControl *moreControl = [moreMapper createView];
        if (![moreControl isKindOfClass:[PBLoadMoreControl class]]) {
            NSLog(@"Pbind: Requires a <PBLoadMoreControl> but got <%@>.", moreControl.class);
            return;
        }
        
        [moreMapper initPropertiesForTarget:moreControl];
        [moreControl addTarget:self action:@selector(loadMoreControlDidReleased:) forControlEvents:UIControlEventValueChanged];
        [owner addSubview:moreControl];
        _loadMoreControl = moreControl;
    }
    
    CGFloat moreControlTriggerThreshold = _loadMoreControl.beginDistance;
    CGFloat moreControlInitialThreshold = MIN(0, moreControlTriggerThreshold);
    if (pulledUpDistance > moreControlInitialThreshold) {
        CGFloat height = [moreMapper heightForView:_loadMoreControl withData:data];
        CGRect frame = CGRectMake(0, pagingView.contentSize.height, owner.frame.size.width, height);
        _loadMoreControl.frame = frame;
        _loadMoreControl.hidden = NO;
        [moreMapper mapPropertiesToTarget:_loadMoreControl withData:data owner:owner context:owner];
    } else {
        _loadMoreControl.hidden = YES;
    }
    
    if (pulledUpDistance >= moreControlTriggerThreshold) {
        if ([_loadMoreControl isEnding] || [_loadMoreControl isLoading]) {
            return;
        }
        
        [_loadMoreControl beginLoading];
        [_loadMoreControl sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

- (void)refreshControlDidReleased:(UIRefreshControl *)sender {
    NSDate *start = [NSDate date];
    
    UIScrollView<PBRowPaging, PBDataFetching> *pagingView = (id)self.dataSource.owner;
    if ([pagingView isFetching] || pagingView.clients == nil) {
        [self endRefreshingControl:sender fromBeginTime:start];
        return;
    }
    
    // Reset paging params
    pagingView.page = 0;
    [pagingView pb_mapData:pagingView.data forKey:@"pagingParams"];
    
    [pagingView.fetcher fetchDataWithTransformation:^id(id data, NSError *error) {
        [self endRefreshingControl:sender fromBeginTime:start];
        return data;
    }];
}

- (void)endRefreshingControl:(UIRefreshControl *)control fromBeginTime:(NSDate *)beginTime {
    NSTimeInterval spentTime = [[NSDate date] timeIntervalSinceDate:beginTime];
    if (spentTime < kMinRefreshControlDisplayingTime) {
        NSTimeInterval fakeAwaitingTime = kMinRefreshControlDisplayingTime - spentTime;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fakeAwaitingTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [control endRefreshing];
        });
    } else {
        [control endRefreshing];
    }
    
    if (_loadMoreControl != nil) {
        [_loadMoreControl setEnabled:YES];
    }
}

- (void)loadMoreControlDidReleased:(UIRefreshControl *)sender {
    UIScrollView<PBRowPaging, PBDataFetching> *pagingView = (id)(self.dataSource.owner);
    
    UIEdgeInsets insets = pagingView.contentInset;
    insets.bottom += _loadMoreControl.bounds.size.height;
    pagingView.contentInset = insets;
    
    _loadMoreBeginTime = [[NSDate date] timeIntervalSince1970];
    _loadingMore = YES;
    if (pagingView.fetcher == nil) {
        [pagingView reloadData];
        return;
    }
    
    // Increase page
    pagingView.page++;
    [pagingView pb_mapData:pagingView.data forKey:@"pagingParams"];
    [pagingView.fetcher fetchDataWithTransformation:^id(id data, NSError *error) {
        if (pagingView.listKey != nil) {
            NSMutableArray *list = [NSMutableArray arrayWithArray:[self.dataSource list]];
            [list addObjectsFromArray:[data valueForKey:pagingView.listKey]];
            if ([data isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *newData = [NSMutableDictionary dictionaryWithDictionary:data];
                [newData setValue:list forKey:pagingView.listKey];
                data = newData;
            } else {
                [data setValue:list forKey:pagingView.listKey];
            }
        } else {
            NSMutableArray *list = [NSMutableArray arrayWithArray:pagingView.data];
            [list addObjectsFromArray:data];
            data = list;
        }
        
        return data;
    }];
}

- (void)endPullingForPagingView:(UIScrollView<PBRowPaging> *)pagingView {
    NSTimeInterval spentTime = [[NSDate date] timeIntervalSince1970] - _loadMoreBeginTime;
    if (spentTime < kMinRefreshControlDisplayingTime) {
        NSTimeInterval fakeAwaitingTime = kMinRefreshControlDisplayingTime - spentTime;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fakeAwaitingTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self endLoadingMore:pagingView];
        });
    } else {
        [self endLoadingMore:pagingView];
    }
}

- (void)endLoadingMore:(UIScrollView<PBRowPaging> *)pagingView {
    _loadingMore = NO;
    [_loadMoreControl endLoading];
    pagingView.data = [pagingView.data arrayByAddingObjectsFromArray:pagingView.data];
    [pagingView reloadData];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Adjust content insets
        UIEdgeInsets insets = pagingView.contentInset;
        insets.bottom -= _loadMoreControl.bounds.size.height;
        pagingView.contentInset = insets;
    });
}

- (BOOL)pagingViewCanReloadData:(UIScrollView<PBRowPaging> *)pagingView {
    if (_loadingMore) {
        [self endPullingForPagingView:pagingView];
        return NO;
    }
    return YES;
}

- (void)reset {
    _more = nil;
    if (_loadMoreControl != nil) {
        [_loadMoreControl removeFromSuperview];
        _loadMoreControl = nil;
    }
}

#pragma mark - UITableView
#pragma mark - Display customization

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // Hides last separator
    if (self.dataSource.sections.count > indexPath.section) {
        PBSectionMapper *mapper = [self.dataSource.sections objectAtIndex:indexPath.section];
        if (mapper.hidesLastSeparator && indexPath.row == mapper.rowCount - 1
            && [self.dataSource dataAtIndexPath:indexPath] != nil) {
            [self _hidesBottomSeparatorForCell:cell];
        }
    }
    
    // Forward delegate
    if ([self.receiver respondsToSelector:_cmd]) {
        [self.receiver tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    }
}
//- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section NS_AVAILABLE_IOS(6_0) {
//    
//}
//- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section NS_AVAILABLE_IOS(6_0) {
//    
//}
//- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath*)indexPath NS_AVAILABLE_IOS(6_0) {
//    
//}
//- (void)tableView:(UITableView *)tableView didEndDisplayingHeaderView:(UIView *)view forSection:(NSInteger)section NS_AVAILABLE_IOS(6_0) {
//    
//}
//- (void)tableView:(UITableView *)tableView didEndDisplayingFooterView:(UIView *)view forSection:(NSInteger)section NS_AVAILABLE_IOS(6_0) {
//    
//}

#pragma mark - Variable height support

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver tableView:tableView heightForRowAtIndexPath:indexPath];
    }
    
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row == nil) {
        return tableView.rowHeight;
    }
    
    return [row heightForData:tableView.data withRowDataSource:self.dataSource indexPath:indexPath];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver tableView:tableView heightForHeaderInSection:section];
    }
    
    if (self.dataSource.sections != nil) {
        if (self.dataSource.sections.count <= section) {
            return 0;
        }
        
        PBSectionMapper *mapper = [self.dataSource.sections objectAtIndex:section];
        if (mapper.header == nil) {
            return 0;
        }
        return [mapper.header heightForData:tableView.data];
    } else if ([tableView.data isKindOfClass:[PBSection class]]) {
        return tableView.sectionHeaderHeight;
    } else if (self.dataSource.row != nil || self.dataSource.rows != nil) {
        return 0;
    }
    
    if ([self.receiver respondsToSelector:_cmd]) {
        return tableView.sectionHeaderHeight;
    }
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver tableView:tableView heightForFooterInSection:section];
    }
    
    if (self.dataSource.sections.count <= section) {
        return 0;
    }
    
    PBSectionMapper *mapper = [self.dataSource.sections objectAtIndex:section];
    if (mapper.footer == nil) {
        return 0;
    }
    return [mapper.footer heightForData:tableView.data];
}

// Use the estimatedHeight methods to quickly calcuate guessed values which will allow for fast load times of the table.
// If these methods are implemented, the above -tableView:heightForXXX calls will be deferred until views are ready to be displayed, so more expensive logic can be placed there.
- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath NS_AVAILABLE_IOS(7_0) {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver tableView:tableView estimatedHeightForRowAtIndexPath:indexPath];
    }
    
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row == nil) {
        return tableView.estimatedRowHeight;
    }
    
    if (row.hidden) {
        return 0;
    }
    
    if (row.estimatedHeight == UITableViewAutomaticDimension) {
        if (tableView.estimatedRowHeight > 0) {
            return tableView.estimatedRowHeight;
        }
        return UITableViewAutomaticDimension;
    }
    
    return row.estimatedHeight;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForHeaderInSection:(NSInteger)section NS_AVAILABLE_IOS(7_0) {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver tableView:tableView estimatedHeightForHeaderInSection:section];
    }
    
    PBRowMapper *row = [self.dataSource.sections objectAtIndex:section].header;
    if (row == nil) {
        return tableView.estimatedSectionHeaderHeight;
    }
    
    if (row.hidden) {
        return 0;
    }
    
    if (row.estimatedHeight == UITableViewAutomaticDimension) {
        if (tableView.estimatedSectionHeaderHeight > 0) {
            return tableView.estimatedSectionHeaderHeight;
        }
        return UITableViewAutomaticDimension;
    }
    
    return row.estimatedHeight;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForFooterInSection:(NSInteger)section NS_AVAILABLE_IOS(7_0) {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver tableView:tableView estimatedHeightForFooterInSection:section];
    }
    
    PBRowMapper *row = [self.dataSource.sections objectAtIndex:section].footer;
    if (row == nil) {
        return tableView.estimatedSectionHeaderHeight;
    }
    
    if (row.hidden) {
        return 0;
    }
    
    if (row.estimatedHeight == UITableViewAutomaticDimension) {
        if (tableView.estimatedSectionHeaderHeight > 0) {
            return tableView.estimatedSectionHeaderHeight;
        }
        return UITableViewAutomaticDimension;
    }
    
    return row.estimatedHeight;
}

// Section header & footer information. Views are preferred over title should you decide to provide both

- (nullable UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver tableView:tableView viewForHeaderInSection:section];
    }
    
    if (self.dataSource.sections.count <= section) {
        return nil;
    }
    
    PBSectionMapper *mapper = [self.dataSource.sections objectAtIndex:section];
    if (mapper.header == nil) {
        return nil;
    }
    
    return [self tableView:tableView viewForHeaderFooterInSection:section withMapper:mapper.header isHeader:YES];
}// custom view for header. will be adjusted to default or specified header height

- (nullable UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver tableView:tableView viewForFooterInSection:section];
    }
    
    if (self.dataSource.sections.count <= section) {
        return nil;
    }
    
    PBSectionMapper *mapper = [self.dataSource.sections objectAtIndex:section];
    if (mapper.footer == nil) {
        return nil;
    }
    
    return [self tableView:tableView viewForHeaderFooterInSection:section withMapper:mapper.footer isHeader:NO];
}// custom view for footer. will be adjusted to default or specified footer height

- (UIView *)tableView:(UITableView *)tableView viewForHeaderFooterInSection:(NSInteger)section withMapper:(PBHeaderFooterMapper *)mapper isHeader:(BOOL)isHeader {
    PBSectionView *sectionView = [[PBSectionView alloc] init];
    [mapper updateWithData:tableView.data owner:nil context:tableView];
    
    // Create content view
    UIView *contentView = nil;
    NSString *title = mapper.title;
    if (title != nil) {
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = title;
        titleLabel.numberOfLines = 0;
        if (mapper.titleFont != nil) {
            titleLabel.font = mapper.titleFont;
        }
        if (mapper.titleColor != nil) {
            titleLabel.textColor = mapper.titleColor;
        }
        if (mapper.backgroundColor != nil) {
            sectionView.backgroundColor = mapper.backgroundColor;
        }
        contentView = titleLabel;
    } else {
        // Custom footer view
        contentView = [[mapper.viewClass alloc] init];
        if (mapper.layoutMapper != nil) {
            [mapper.layoutMapper renderToView:contentView];
        }
        
        [mapper initPropertiesForTarget:contentView];
        [mapper mapPropertiesToTarget:contentView withData:tableView.data owner:contentView context:tableView];
    }
    
    // Set content view margin
    [sectionView addSubview:contentView];
    UIEdgeInsets margin = mapper.margin;
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [sectionView addConstraint:[NSLayoutConstraint constraintWithItem:contentView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:sectionView attribute:NSLayoutAttributeTop multiplier:1 constant:margin.top]];
    [sectionView addConstraint:[NSLayoutConstraint constraintWithItem:contentView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:sectionView attribute:NSLayoutAttributeLeft multiplier:1 constant:margin.left]];
    [sectionView addConstraint:[NSLayoutConstraint constraintWithItem:sectionView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:contentView attribute:NSLayoutAttributeBottom multiplier:1 constant:margin.bottom]];
    [sectionView addConstraint:[NSLayoutConstraint constraintWithItem:sectionView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:contentView attribute:NSLayoutAttributeRight multiplier:1 constant:margin.right]];
    
    sectionView.section = section;
    return sectionView;
}

//#pragma mark - Accessories (disclosures).

//- (UITableViewCellAccessoryType)tableView:(UITableView *)tableView accessoryTypeForRowWithIndexPath:(NSIndexPath *)indexPath NS_DEPRECATED_IOS(2_0, 3_0) __TVOS_PROHIBITED;
//- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath;

#pragma mark - Selection

// -tableView:shouldHighlightRowAtIndexPath: is called when a touch comes down on a row.
// Returning NO to that message halts the selection process and does not cause the currently selected row to lose its selected look while the touch is down.
//- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath NS_AVAILABLE_IOS(6_0);
//- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath NS_AVAILABLE_IOS(6_0);
//- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath NS_AVAILABLE_IOS(6_0);

// Called before the user changes the selection. Return a new indexPath, or nil, to change the proposed selection.
- (nullable NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *newIndexPath = indexPath;
    
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.willSelectActionMapper != nil) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        [self dispatchAction:row.willSelectActionMapper forCell:cell atIndexPath:indexPath];
    }
    
    if ([self.receiver respondsToSelector:_cmd]) {
        newIndexPath = [self.receiver tableView:tableView willSelectRowAtIndexPath:indexPath];
    }
    
    return newIndexPath;
}

- (nullable NSIndexPath *)tableView:(UITableView *)tableView willDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *newIndexPath = indexPath;
    
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.willDeselectActionMapper != nil) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        [self dispatchAction:row.willDeselectActionMapper forCell:cell atIndexPath:indexPath];
    }
    
    if ([self.receiver respondsToSelector:_cmd]) {
        newIndexPath = [self.receiver tableView:tableView willDeselectRowAtIndexPath:indexPath];
    }
    
    return newIndexPath;
}

// Called after the user changes the selection.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.selectActionMapper != nil) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        [self dispatchAction:row.selectActionMapper forCell:cell atIndexPath:indexPath];
    }
    
    if ([self.receiver respondsToSelector:_cmd]) {
        [self.receiver tableView:tableView didSelectRowAtIndexPath:indexPath];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.deselectActionMapper != nil) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        [self dispatchAction:row.deselectActionMapper forCell:cell atIndexPath:indexPath];
    }
    
    if ([self.receiver respondsToSelector:_cmd]) {
        [self.receiver tableView:tableView didSelectRowAtIndexPath:indexPath];
    }
}

#pragma mark - Editing

- (nullable NSArray<UITableViewRowAction *> *)tableView:(UITableView<PBRowMapping> *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.editActionMappers == nil) {
        return nil;
    }
    
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSMutableArray *editActions = [[NSMutableArray alloc] initWithCapacity:row.editActionMappers.count];
    for (PBRowActionMapper *actionMapper in [row.editActionMappers reverseObjectEnumerator]) {
        [actionMapper updateWithData:tableView.rootData owner:cell context:tableView];
        UITableViewRowAction *rowAction = [UITableViewRowAction rowActionWithStyle:actionMapper.style title:actionMapper.title handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull indexPath) {
            tableView.editingIndexPath = indexPath;
            [self dispatchAction:actionMapper forCell:cell atIndexPath:indexPath];
        }];
        if (actionMapper.backgroundColor != nil) {
            rowAction.backgroundColor = actionMapper.backgroundColor;
        }
        [editActions addObject:rowAction];
    }
    
    return editActions;
}// supercedes -tableView:titleForDeleteConfirmationButtonForRowAtIndexPath: if return value is non-nil

// Controls whether the background is indented while editing.  If not implemented, the default is YES.  This is unrelated to the indentation level below.  This method only applies to grouped style table views.
//- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath;

// The willBegin/didEnd methods are called whenever the 'editing' property is automatically changed by the table (allowing insert/delete/move). This is done by a swipe activating a single row
//- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath __TVOS_PROHIBITED;
//- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(nullable NSIndexPath *)indexPath __TVOS_PROHIBITED;

//#pragma mark - Moving/reordering

// Allows customization of the target row for a particular row as it is being moved/reordered
//- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath;

//#pragma mark - Indentation

//- (NSInteger)tableView:(UITableView *)tableView indentationLevelForRowAtIndexPath:(NSIndexPath *)indexPath; // return 'depth' of row for hierarchies

//#pragma mark - Copy/Paste.  All three methods must be implemented by the delegate.

//- (BOOL)tableView:(UITableView *)tableView shouldShowMenuForRowAtIndexPath:(NSIndexPath *)indexPath NS_AVAILABLE_IOS(5_0);
//- (BOOL)tableView:(UITableView *)tableView canPerformAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(nullable id)sender NS_AVAILABLE_IOS(5_0);
//- (void)tableView:(UITableView *)tableView performAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(nullable id)sender NS_AVAILABLE_IOS(5_0);

//#pragma mark - Focus

//- (BOOL)tableView:(UITableView *)tableView canFocusRowAtIndexPath:(NSIndexPath *)indexPath NS_AVAILABLE_IOS(9_0);
//- (BOOL)tableView:(UITableView *)tableView shouldUpdateFocusInContext:(UITableViewFocusUpdateContext *)context NS_AVAILABLE_IOS(9_0);
//- (void)tableView:(UITableView *)tableView didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator NS_AVAILABLE_IOS(9_0);
//- (nullable NSIndexPath *)indexPathForPreferredFocusedViewInTableView:(UITableView *)tableView NS_AVAILABLE_IOS(9_0);


#pragma mark - UICollectionView


#pragma mark - UICollectionViewDelegate

- (BOOL)collectionView:(UICollectionView *)collectionView shouldSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    BOOL shouldSelect = YES;
    
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.willSelectActionMapper != nil) {
        UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
        [self dispatchAction:row.willSelectActionMapper forCell:cell atIndexPath:indexPath];
    }
    
    if ([self.receiver respondsToSelector:_cmd]) {
        shouldSelect = [self.receiver collectionView:collectionView shouldSelectItemAtIndexPath:indexPath];
    }
    
    return shouldSelect;
}

- (void)collectionView:(PBCollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.selectActionMapper != nil) {
        UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
        [self dispatchAction:row.selectActionMapper forCell:cell atIndexPath:indexPath];
    }
    
    collectionView.selectedData = [self.dataSource dataAtIndexPath:indexPath];
    collectionView.selectedIndexPath = indexPath;
    
    if ([self.receiver respondsToSelector:_cmd]) {
        [self.receiver collectionView:collectionView didSelectItemAtIndexPath:indexPath];
    }
}

- (BOOL)collectionView:(UICollectionView *)collectionView shouldDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    BOOL shouldDeselect = YES;
    
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.willDeselectActionMapper != nil) {
        UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
        [self dispatchAction:row.willDeselectActionMapper forCell:cell atIndexPath:indexPath];
    }
    
    if ([self.receiver respondsToSelector:_cmd]) {
        shouldDeselect = [self.receiver collectionView:collectionView shouldDeselectItemAtIndexPath:indexPath];
    }
    
    return shouldDeselect;
}

- (void)collectionView:(PBCollectionView *)collectionView didDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    PBRowMapper *row = [self.dataSource rowAtIndexPath:indexPath];
    if (row.deselectActionMapper != nil) {
        UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
        [self dispatchAction:row.deselectActionMapper forCell:cell atIndexPath:indexPath];
    }
    
    collectionView.deselectedData = [self.dataSource dataAtIndexPath:indexPath];
    collectionView.selectedIndexPath = nil;
    
    if ([self.receiver respondsToSelector:_cmd]) {
        [self.receiver collectionView:collectionView didDeselectItemAtIndexPath:indexPath];
    }
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForHeaderInSection:(NSInteger)section {
    PBRowMapper *element = [self.dataSource.sections objectAtIndex:section];
    return [self referenceSizeForCollectionView:collectionView withElementMapper:element];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForFooterInSection:(NSInteger)theSection {
    PBSectionMapper *section = [self.dataSource.sections objectAtIndex:theSection];
    return [self referenceSizeForCollectionView:collectionView withElementMapper:section.footer];
}

- (CGSize)referenceSizeForCollectionView:(UICollectionView *)collectionView withElementMapper:(PBRowMapper *)element {
    if (element == nil || (element.layout == nil && element.viewClass == [UICollectionReusableView class])) {
        return CGSizeZero;
    }
    return CGSizeMake(collectionView.bounds.size.width, element.height);
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver collectionView:collectionView layout:collectionViewLayout sizeForItemAtIndexPath:indexPath];
    }
    
    PBSectionMapper *section = [self.dataSource.sections objectAtIndex:indexPath.section];
    PBRowMapper *item = [self.dataSource rowAtIndexPath:indexPath];
    
    // Average
    if (section.numberOfColumns != 0) {
        NSInteger numberOfGaps = section.numberOfColumns - 1;
        CGFloat width = (collectionView.bounds.size.width - numberOfGaps * section.inner.width - section.inset.left - section.inset.right) / section.numberOfColumns;
        CGFloat height = item.height;
        if (height < 0) {
            CGFloat ratio = item.ratio == 0 ? 1 : item.ratio;
            height = width / ratio + item.additionalHeight;
        }
        return CGSizeMake(width, height);
    }

    // Explicit
    CGFloat itemWidth = item.width;
    CGFloat itemHeight = item.height;
    if (itemWidth == -1) {
        itemWidth = collectionView.bounds.size.width - section.inset.left - section.inset.right;
    }
    if (itemWidth != 0) {
        if (itemHeight == -1) {
            // Auto height
            itemWidth = 1.f; // the width is ignored here, after the cell created it will be set as a width  constraint.
            itemHeight = 1.f;//collectionView.bounds.size.height;
        }
        return CGSizeMake(itemWidth, itemHeight);
    }
    
    return collectionViewLayout.itemSize;
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)collectionViewLayout insetForSectionAtIndex:(NSInteger)section {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver collectionView:collectionView layout:collectionViewLayout insetForSectionAtIndex:section];
    }
    
    if (self.dataSource.sections != nil) {
        PBSectionMapper *mapper = [self.dataSource.sections objectAtIndex:section];
        UIEdgeInsets inset = mapper.inset;
        if (!UIEdgeInsetsEqualToEdgeInsets(inset, UIEdgeInsetsZero)) {
            return inset;
        }
    }
    
    return collectionViewLayout.sectionInset;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver collectionView:collectionView layout:collectionViewLayout minimumInteritemSpacingForSectionAtIndex:section];
    }
    
    if (self.dataSource.sections != nil) {
        PBSectionMapper *mapper = [self.dataSource.sections objectAtIndex:section];
        CGSize size = mapper.inner;
        if (size.width >= 0) {
            return size.width;
        }
        
        if (mapper.numberOfColumns != 0) {
            PBRowMapper *item = [self.dataSource rowAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:section]];
            if (item.width != 0) {
                CGFloat spacing = (collectionView.bounds.size.width - item.width * mapper.numberOfColumns - mapper.inset.left - mapper.inset.right) / (mapper.numberOfColumns - 1);
                return spacing;
            }
        }
    }
    
    return collectionViewLayout.minimumInteritemSpacing;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    if ([self.receiver respondsToSelector:_cmd]) {
        return [self.receiver collectionView:collectionView layout:collectionViewLayout minimumLineSpacingForSectionAtIndex:section];
    }
    
    if (self.dataSource.sections != nil) {
        PBSectionMapper *mapper = [self.dataSource.sections objectAtIndex:section];
        CGSize size = mapper.inner;
        if (size.height >= 0) {
            return size.height;
        }
    }
    
    return collectionViewLayout.minimumLineSpacing;
}

#pragma mark - Helper

- (void)_hidesBottomSeparatorForCell:(UITableViewCell *)cell {
    for (UIView *subview in cell.subviews) {
        if (subview == cell.contentView) {
            continue;
        }
        
        subview.alpha = 0;
    }
}

- (void)dispatchAction:(PBActionMapper *)action forCell:(UIView *)cell atIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *data = indexPath == nil ? nil : @{@"indexPath": indexPath};
    [[PBActionStore defaultStore] dispatchActionWithActionMapper:action context:cell data:data];
}

@end
