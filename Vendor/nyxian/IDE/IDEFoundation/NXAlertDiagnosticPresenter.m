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

#import <LindChain/IDEFoundation/NXAlertDiagnosticPresenter.h>
#import <LindChain/WindowServer/NXWindowServer.h>

static UIViewController *NXTopViewController(UIViewController *viewController)
{
    if(viewController.presentedViewController)
    {
        return NXTopViewController(viewController.presentedViewController);
    }
    
    if([viewController isKindOfClass:[UINavigationController class]])
    {
        UINavigationController *nav = (UINavigationController *)viewController;
        return NXTopViewController(nav.visibleViewController ?: nav);
    }
    
    if([viewController isKindOfClass:[UITabBarController class]])
    {
        UITabBarController *tab = (UITabBarController *)viewController;
        return NXTopViewController(tab.selectedViewController ?: tab);
    }
    
    return viewController;
}

static NSString *NXStringForNXAlertDiagnosticPresenterLevel(NXAlertDiagnosticPresenterLevel level)
{
    switch(level)
    {
        case NXAlertDiagnosticPresenterLevelNote:
            return @"Note";
        case NXAlertDiagnosticPresenterLevelWarning:
            return @"Warning";
        case NXAlertDiagnosticPresenterLevelError:
        default:
            return @"Error";
    }
}

@implementation NXAlertDiagnosticPresenter

+ (void)notifyUserWithLevel:(NXAlertDiagnosticPresenterLevel)level
                withMessage:(NSString*)message
                  withDelay:(double)delay
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *viewController = NXTopViewController(NXWindowServer.shared.rootViewController);
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NXStringForNXAlertDiagnosticPresenterLevel(level) message:message preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
            [viewController presentViewController:alertController animated:YES completion:nil];
        });
    });
}

@end
