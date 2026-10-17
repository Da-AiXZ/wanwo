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

import MobileDevelopmentKit

extension NXBuilder: MDKPhaseRunnerDelegate {
    func runner(_ runner: MDKPhaseRunner,
                phase: MDKPhase, execute job: MDKJob,
                withOutDiagnostics diagnostics: AutoreleasingUnsafeMutablePointer<NSArray>?,
                withOutMainSource mainSource: AutoreleasingUnsafeMutablePointer<NSString>?) -> Bool {
        var localDiags: NSArray?
        var localSource: NSString?
        
        let ok: Bool
        if self.useRemoteServiceIfAvailable,
            let remoteCompiler = self.remoteCompiler {
            ok = remoteCompiler.execute(job, with: &localDiags, withMainSource: &localSource)
        } else {
            ok = job.execute(withOutDiagnostics: &localDiags, withOutMainSource: &localSource)
        }

        if let diags = localDiags {
            diagnostics?.pointee = diags
        }
        if let source = localSource {
            mainSource?.pointee = source
        }

        return ok
    }
    
    func runner(_ runner: MDKPhaseRunner,
                multithreadingThreadCountFor phase: MDKPhase) -> CFIndex {
        let userSelectedValue: NSNumber? = UserDefaults.standard.object(forKey: "cputhreads") as? NSNumber
        let userSelected = userSelectedValue?.intValue ?? CCGetMaximumPerformanceCores()
        return CFIndex(userSelected == 0 ? 1 : userSelected)
    }
    
    func runner(_ runner: MDKPhaseRunner,
                phase: MDKPhase,
                finishedRunning job: MDKJob,
                withResultingDiagnostics diagnostics: [MDKDiagnostic]?,
                withMainSource mainSource: String?,
                wasSuccessful success: Bool) {
        if let diagnostics = diagnostics,
           let mainSource = mainSource {
            self.database.removeFileDebug(ofPath: mainSource)
            if job.type == .linker {
                self.database.addDiagnosticMessages(title: "Linker", items: diagnostics, clearPrevious: true)
            } else {
                self.database.appendDebug(originatorPath: mainSource, synItems: diagnostics)
            }
        }
    }
}

