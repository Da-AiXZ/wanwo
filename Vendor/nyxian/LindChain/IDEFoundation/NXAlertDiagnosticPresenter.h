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

#ifndef NXALERTDIAGNOSTICPRESENTER_H
#define NXALERTDIAGNOSTICPRESENTER_H

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, NXAlertDiagnosticPresenterLevel) {
    NXAlertDiagnosticPresenterLevelNote =   0,
    NXAlertDiagnosticPresenterLevelWarning,
    NXAlertDiagnosticPresenterLevelError,
};

@interface NXAlertDiagnosticPresenter : NSObject

+ (void)notifyUserWithLevel:(NXAlertDiagnosticPresenterLevel)level withMessage:(NSString*)message withDelay:(double)delay;

@end

#endif /* NXALERTDIAGNOSTICPRESENTER_H */
