//
//  content_module_manager.cpp
//  ePub3
//
//  Created by Jim Dovey on 10/30/2013.
//  Copyright (c) 2014 Readium Foundation and/or its licensees. All rights reserved.
//  
//  This program is distributed in the hope that it will be useful, but WITHOUT ANY 
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  
//  
//  Licensed under Gnu Affero General Public License Version 3 (provided, notwithstanding this notice, 
//  Readium Foundation reserves the right to license this material under a different separate license, 
//  and if you have done so, the terms of that separate license control and the following references 
//  to GPL do not apply).
//  
//  This program is free software: you can redistribute it and/or modify it under the terms of the GNU 
//  Affero General Public License as published by the Free Software Foundation, either version 3 of 
//  the License, or (at your option) any later version. You should have received a copy of the GNU 
//  Affero General Public License along with this program.  If not, see <http://www.gnu.org/licenses/>.

#include <ePub3/container.h>
#include "content_module_manager.h"
#include "content_module.h"

#include <mutex>

#if FUTURE_ENABLED
#include "user_action.h"
#include "credential_request.h"
//#include <thread>
#endif //FUTURE_ENABLED

EPUB3_BEGIN_NAMESPACE

std::unique_ptr<ContentModuleManager> ContentModuleManager::s_instance;

ContentModuleManager::ContentModuleManager() :
#if FUTURE_ENABLED
        _mutex(),
#endif //FUTURE_ENABLED
        _known_modules()
{
}
ContentModuleManager::~ContentModuleManager()
{
}

ContentModuleManager* ContentModuleManager::Instance() _NOEXCEPT
{
    static std::once_flag __once;
    std::call_once(__once, [](std::unique_ptr<ContentModuleManager> *ptr) {
        ptr->reset(new ContentModuleManager);
    }, &s_instance);
    return s_instance.get();
//
//    if (ContentModuleManager::s_instance == nullptr || ContentModuleManager::s_instance.get() == nullptr) {
//        ContentModuleManager::s_instance = std::unique_ptr<ContentModuleManager>(new ContentModuleManager());
//    }
//    ContentModuleManager* ptr = ContentModuleManager::s_instance.get();
//    return ptr;
}

void ContentModuleManager::RegisterContentModule(ContentModule* module,
                                                 const ePub3::string& name) _NOEXCEPT
{
#if FUTURE_ENABLED
    std::unique_lock<std::mutex> locker(_mutex);
#endif //FUTURE_ENABLED
    _known_modules[name] = std::shared_ptr<ContentModule>(module);
}

#if FUTURE_ENABLED

void ContentModuleManager::DisplayMessage(const string& title, const string& message) _NOEXCEPT
{
    // nothing at the moment...
}

future<Credentials>
ContentModuleManager::RequestCredentialInput(const CredentialRequest &request)
{
    // nothing yet...
    // really want the std::make_immediate_future<>() function right now...
    std::promise<Credentials> promise;
    
    Credentials none;
    return make_ready_future(none);
}
#endif //FUTURE_ENABLED

#if FUTURE_ENABLED
future<ContainerPtr>
ContentModuleManager::LoadContentAtPath(const string& path, launch policy)
{
#if FUTURE_ENABLED
    std::unique_lock<std::mutex> locker(_mutex);
#endif //FUTURE_ENABLED

    if (_known_modules.empty())
    {
        // special case for when we don't have any Content Modules to rely on for an initialized result
        return make_ready_future<ContainerPtr>(ContainerPtr(nullptr));
    }
    
    future<ContainerPtr> result;

    for (auto& item : _known_modules)
    {
        auto modulePtr = item.second;
        result = modulePtr->ProcessFile(path, policy);
        
        // check the state of the future -- has it already been set?
        future_status status = result.wait_for(std::chrono::system_clock::duration(0));

        if (status == future_status::ready) {

            // WARNING! after .get(), the Future<> is empty! (future.__future_ == nullptr / !future.valid()) see Container.cpp OpenContainer()
            ContainerPtr container = result.get();

            if (bool(container)) {
                modulePtr->RegisterContentFilters();

                std::shared_ptr<Package> package = container->DefaultPackage();
                package->Unpack_Finally(true);

                // ensures the Future is valid()
                result = make_ready_future<ContainerPtr>(ContainerPtr(container));
                break;
            } else {
                continue;
            }
        } else {
            modulePtr->RegisterContentFilters();
            break;
        }
    }

    return result;
}
#else
    ContainerPtr
    ContentModuleManager::LoadContentAtPath(const string& path)
    {
#if FUTURE_ENABLED
        std::unique_lock<std::mutex> locker(_mutex);
#endif //FUTURE_ENABLED

        if (_known_modules.empty())
        {
            return nullptr;
        }

        for (auto& item : _known_modules)
        {
            std::shared_ptr<ContentModule> modulePtr = item.second;

            ContainerPtr container = modulePtr->ProcessFile(path);

            if (bool(container)) {

                // Singleton FilterManagerImpl::RegisterFilter() uses .emplace() with unique keys,
                // so ContentFilters with the same name => only the first inserted one is preserved (subsequent insertions ignored).
                modulePtr->RegisterContentFilters();

                // Problem: container was loaded okay, but if Navigation Document was encrypted,
                // then because the ContentFilters were not registered yet:
                // the NavDoc XHTML silently failed to load (populate the internal ReadiumSDK data structures)
                // as the byte buffers were scrambled. So, we need to either reload the entire EPUB, or reload only the navdoc.
                std::shared_ptr<Package> package = container->DefaultPackage();
                package->Unpack_Finally(true);

                return std::move(container);
            }
        }

        return nullptr;
    }
#endif //FUTURE_ENABLED

EPUB3_END_NAMESPACE
