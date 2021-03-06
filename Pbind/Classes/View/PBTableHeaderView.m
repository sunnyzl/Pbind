//
//  PBTableHeaderView.m
//  Pbind <https://github.com/wequick/Pbind>
//
//  Created by Galen Lin on 16/9/9.
//  Copyright (c) 2015-present, Wequick.net. All rights reserved.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "PBTableHeaderView.h"

@implementation PBTableHeaderView

- (void)setContentSize:(CGSize)contentSize {
    if (contentSize.height == 0) {
        contentSize.height = CGFLOAT_MIN;
    }
    [super setContentSize:contentSize];
}

@end
