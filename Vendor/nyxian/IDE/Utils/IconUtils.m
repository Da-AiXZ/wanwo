/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

#import <UIKit/UIKit.h>
#import <LindChain/Services/bootstrapd/ISIcon.h>
#import <LindChain/Utils/IconUtils.h>
#import <LindChain/Private/UIKitPrivate.h>

static ISImageDescriptor *ISIDescriptorFor(CGSize size,
                                           CGFloat scale,
                                           BOOL darkMode)
{
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });

    NSString *key = [NSString stringWithFormat:@"%.1fx%.1f@%.1f.%@", size.width, size.height, scale, @(darkMode)];
    @synchronized(cache)
    {
        ISImageDescriptor *descriptor = cache[key];
        if(!descriptor)
        {
            descriptor = [[PrivClass(ISImageDescriptor) alloc] initWithSize:size scale:scale];
            descriptor.shape = 1;
            descriptor.appearance = darkMode ? ISImageDescriptorApparanceDarkMode : ISImageDescriptorApparanceLightMode;
            descriptor.appearanceVariant = ISImageDescriptorApparanceVariantDefault;
            descriptor.shouldApplyMask = YES;
            descriptor.drawBorder = YES;
            cache[key] = descriptor;
        }
        return descriptor;
    }
}

UIImage *Gib26Icon(UIImage *rawLightIcon,
                   UIImage *rawDarkIcon,
                   CGSize size,
                   CGFloat scale)
{
    if(!rawLightIcon.CGImage || !rawDarkIcon.CGImage)
    {
        return nil;
    }
    
    /* like black and white hole from the universe x3 (white hole, black hole, tight ...) */
    IFImage *lightSource = [[PrivClass(IFImage) alloc] initWithCGImage:rawLightIcon.CGImage scale:rawLightIcon.scale];  /* like from my flashlight */
    IFImage *darkSource = [[PrivClass(IFImage) alloc] initWithCGImage:rawDarkIcon.CGImage scale:rawDarkIcon.scale];
    if(!lightSource || !darkSource)
    {
        return nil;
    }
    
    ISIcon *lightIcon = [[PrivClass(ISIcon) alloc] initWithImages:@[lightSource]];
    ISIcon *darkIcon = [[PrivClass(ISIcon) alloc] initWithImages:@[darkSource]];
    if(!lightIcon || !darkIcon)
    {
        return nil;
    }
    
    /* more research is needed on how apple applies the format :c */
    ISImageDescriptor *descriptor = ISIDescriptorFor(size, scale, NO);
    
    /* apperently what apple uses */
    IFImage *lightRendered = [lightIcon prepareImageForDescriptor:descriptor];
    IFImage *darkRendered = [darkIcon prepareImageForDescriptor:descriptor];
    if(!lightRendered || !lightRendered.CGImage ||
       !darkRendered || !darkRendered.CGImage)
    {
        return nil;
    }
    
    UIImage *lightImage = [UIImage imageWithCGImage:lightRendered.CGImage scale:scale orientation:UIImageOrientationUp];
    UIImage *darkImage = [UIImage imageWithCGImage:darkRendered.CGImage scale:scale orientation:UIImageOrientationUp];
    
    UIImageAsset *asset = [[UIImageAsset alloc] init];
    
    UITraitCollection *lightTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    UITraitCollection *darkTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
    
    [asset registerImage:lightImage withTraitCollection:lightTraits];
    [asset registerImage:darkImage withTraitCollection:darkTraits];
    
    return [asset imageWithTraitCollection:UITraitCollection.currentTraitCollection];
}

UIImage *Gib26FallbackIcon(CGSize size, CGFloat scale)
{
    ISIcon *icon = [PrivClass(ISIcon) genericApplicationIcon];
    if(!icon)
    {
        return nil;
    }
    
    ISImageDescriptor *lightDescriptor = ISIDescriptorFor(size, scale, NO);
    ISImageDescriptor *darkDescriptor = ISIDescriptorFor(size, scale, YES);
    
    IFImage *lightRendered = [icon prepareImageForDescriptor:lightDescriptor];
    IFImage *darkRendered = [icon prepareImageForDescriptor:darkDescriptor];
    if(!lightRendered || !lightRendered.CGImage ||
       !darkRendered || !darkRendered.CGImage)
    {
        return nil;
    }
    
    UIImage *lightImage = [UIImage imageWithCGImage:lightRendered.CGImage scale:scale orientation:UIImageOrientationUp];
    UIImage *darkImage = [UIImage imageWithCGImage:darkRendered.CGImage scale:scale orientation:UIImageOrientationUp];
    
    UIImageAsset *asset = [[UIImageAsset alloc] init];
    
    UITraitCollection *lightTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    UITraitCollection *darkTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
    
    [asset registerImage:lightImage withTraitCollection:lightTraits];
    [asset registerImage:darkImage withTraitCollection:darkTraits];
    
    return [asset imageWithTraitCollection:UITraitCollection.currentTraitCollection];
}
