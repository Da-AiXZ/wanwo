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

#import <LindChain/IDEBuilder/NXPhaseRunner.h>
#import <UI/XCodeButton.h>

@interface NXPhaseRunner(Private)

@property (atomic) CFIndex steps;
@property (atomic) CFIndex donestep;

@end

@implementation NXPhaseRunner {
    double _progressStep;
    CFIndex _steps;
    CFIndex _donestep;
}

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        _progressStep = 0.0;
        _steps = 0;
        _donestep = 0;
    }
    return self;
}

- (CFIndex)steps
{
    return _steps;
}

- (void)setSteps:(CFIndex)steps
{
    _steps = steps;
    _progressStep = 1.0 / (double)_steps;
    [self refreshDoneStep];
}

- (CFIndex)donestep
{
    return _donestep;
}

- (void)setDonestep:(CFIndex)donestep
{
    _donestep = donestep;
    [self refreshDoneStep];
}

- (void)refreshDoneStep
{
    double progress = _progressStep * (double)_donestep;
    [XCButton updateProgressWithValue:progress];
}

- (BOOL)runJob:(MDKJob *)job withinPhase:(MDKPhase *)phase
{
    BOOL success = [super runJob:job withinPhase:phase];
    self.donestep += 1;
    return success;
}

- (BOOL)runPhase:(MDKPhase *)phase
{
    switch(phase.type)
    {
        case MDKJobTypeCompiler:
        case MDKJobTypeSwiftCompiler:
            [XCButton switchImageSyncWithSystemName:@"hammer.fill" animated:YES];
            break;
        case MDKJobTypeLinker:
            [XCButton switchImageSyncWithSystemName:@"link" animated:YES];
            [[fallthrough]];
        default:
            break;
    }
    return [super runPhase:phase];
}

- (BOOL)runPhasesWithPhases:(NSArray *)phases
{
    for(MDKPhase *phase in phases)
    {
        if([phase isKindOfClass:[MDKPhase class]])
        {
            self.steps += phase.jobs.count;
        }
    }
    return [super runPhasesWithPhases:phases];
}

@end
