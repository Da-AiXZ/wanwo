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

#import <LindChain/Utils/Swizzle.h>

typedef struct {
    Method method;
    SwizzleMethodType type;
} SwizzleMethod;

static SwizzleMethod SwizzleGetMethod(Class class,
                                      SEL selector,
                                      SwizzleMethodType swizzleMethodType)
{
    SwizzleMethod swizzleMethod = { .method = nil, .type = swizzleMethodType };
    if(selector == nil)
    {
        return swizzleMethod;
    }
    
    switch(swizzleMethodType)
    {
        case kSwizzleMethodTypeClass:
            swizzleMethod.method = class_getClassMethod(class, selector);
            break;
        case kSwizzleMethodTypeInstance:
            swizzleMethod.method = class_getInstanceMethod(class, selector);
            break;
        default:
            break;
            
    }
    
    if(swizzleMethod.method == nil)
    {
        swizzleMethod.type = kSwizzleMethodTypeUnknown;
    }
    
    return swizzleMethod;
}

SwizzleReturn SwizzleObjCMethod(SEL originalAction,
                                Class originalClass,
                                SEL replacementAction,
                                Class replacementClass,
                                SwizzleMethodType swizzleMethodType)
{
    if(originalAction == nil || originalClass == nil  || replacementAction == nil)
    {
        return kSwizzleReturnArguments;
    }
    
    SwizzleMethod originalMethod = SwizzleGetMethod(originalClass, originalAction, swizzleMethodType);
    SwizzleMethod replacementMethod = SwizzleGetMethod(replacementClass ?: originalClass, replacementAction, swizzleMethodType);
    if(originalMethod.method == nil || replacementMethod.method == nil)
    {
        return kSwizzleReturnArguments;
    }
    
    Class targetClass = (swizzleMethodType == kSwizzleMethodTypeClass) ? object_getClass((id)originalClass) : originalClass;
    
    if(replacementClass)
    {
        class_addMethod(targetClass, replacementAction, method_getImplementation(replacementMethod.method), method_getTypeEncoding(replacementMethod.method));
        replacementMethod = SwizzleGetMethod(originalClass, replacementAction, swizzleMethodType);
        if(replacementMethod.method == nil)
        {
            return kSwizzleReturnArguments;
        }
    }
    method_exchangeImplementations(originalMethod.method, replacementMethod.method);
    
    return kSwizzleReturnSuccess;
}
