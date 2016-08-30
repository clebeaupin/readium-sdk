//
//  RDContainer.mm
//  RDServices
//
//  Created by Shane Meyer on 2/4/13.
//  Copyright (c) 2014 Readium Foundation and/or its licensees. All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without modification, 
//  are permitted provided that the following conditions are met:
//  1. Redistributions of source code must retain the above copyright notice, this 
//  list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright notice, 
//  this list of conditions and the following disclaimer in the documentation and/or 
//  other materials provided with the distribution.
//  3. Neither the name of the organization nor the names of its contributors may be 
//  used to endorse or promote products derived from this software without specific 
//  prior written permission.
//  
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. 
//  IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, 
//  INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
//  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
//  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF 
//  LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE 
//  OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED 
//  OF THE POSSIBILITY OF SUCH DAMAGE.

#import "RDContainer.h"
#import <ePub3/container.h>
#import <ePub3/initialization.h>
#import <ePub3/utilities/byte_stream.h>
#import <ePub3/utilities/error_handler.h>
#import "RDPackage.h"


#import <platform/apple/src/lcp.h>
#import <LcpContentModule.h>
#import "RDLCPService.h"

#import "RDLcpCredentialHandler.h"

#include <ePub3/content_module_exception.h>

class LcpCredentialHandler : public lcp::ICredentialHandler
{
private:
    id <RDContainerDelegate> _delegate;
    RDContainer* _container;
public:
    LcpCredentialHandler(RDContainer* container, id <RDContainerDelegate> delegate) {
        _container = container;
        _delegate = delegate;
    }
    
    void decrypt(lcp::ILicense *license) {
        //if (![_delegate respondsToSelector:@selector(decrypt:)]) return;
        
        LCPLicense* lcpLicense = [[LCPLicense alloc] initWithLicense:license];
        [_delegate decrypt:lcpLicense container:_container];
    }
};

@interface RDContainer () {
	@private std::shared_ptr<ePub3::Container> m_container;
	@private __weak id <RDContainerDelegate> m_delegate;
	@private NSMutableArray *m_packages;
	@private ePub3::Container::PackageList m_packageList;
	@private NSString *m_path;
	//@private lcp::ICredentialHandler *m_credentialHandler;
}

@end


@implementation RDContainer


@synthesize packages = m_packages;
@synthesize path = m_path;
//@synthesize credentialHandler = m_credentialHandler;

- (RDPackage *)firstPackage {
	return m_packages.count == 0 ? nil : [m_packages objectAtIndex:0];
}


- (instancetype)initWithDelegate:(id <RDContainerDelegate>)delegate path:(NSString *)path {
	if (path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		return nil;
	}

	if (self = [super init]) {
		m_delegate = delegate;

		ePub3::ErrorHandlerFn sdkErrorHandler = ^(const ePub3::error_details& err) {

			const char * msg = err.message();

			BOOL isSevereEpubError = NO;
			if (err.is_spec_error()
					&& (err.severity() == ePub3::ViolationSeverity::Critical
					|| err.severity() == ePub3::ViolationSeverity::Major))
				isSevereEpubError = YES;

			BOOL res = [m_delegate container:self handleSdkError:[NSString stringWithUTF8String:msg] isSevereEpubError:isSevereEpubError];

			return (res == YES ? true : false);
			//return ePub3::DefaultErrorHandler(err);
		};
		ePub3::SetErrorHandler(sdkErrorHandler);

		ePub3::InitializeSdk();
		ePub3::PopulateFilterManager();
		
        //[[RDLCPService sharedService] registerContentFilter];
//		if ([delegate respondsToSelector:@selector(containerRegisterContentFilters:)]) {
//			[delegate containerRegisterContentFilters:self];
//		}
        
		lcp::ICredentialHandler* credentialHandlerNative = new LcpCredentialHandler(self, delegate);
        RDLcpCredentialHandler* credentialHandler = [[RDLcpCredentialHandler alloc] initWithNative:credentialHandlerNative];
        
        [[RDLCPService sharedService] registerContentModule:credentialHandler];
//		if ([delegate respondsToSelector:@selector(containerRegisterContentModules:)]) {
//			[delegate containerRegisterContentModules:self];
//		}
        
        m_path = path;
        
        try {
            m_container = ePub3::Container::OpenContainer(path.UTF8String);
        }
//        catch (NSException *e) {
//            BOOL res = [m_delegate container:self handleSdkError:[e reason] isSevereEpubError:NO];
//        }
        catch (ePub3::ContentModuleExceptionDecryptFlow& e) {
            // NoOP
        }
        catch (std::exception& e) { // includes ePub3::ContentModuleException
        
            auto msg = e.what();
            
            std::cout << msg << std::endl;
            
            BOOL res = [m_delegate container:self handleSdkError:[NSString stringWithUTF8String:msg] isSevereEpubError:NO];
        }
        catch (...) {
            BOOL res = [m_delegate container:self handleSdkError:@"unknown exception" isSevereEpubError:NO];
        }
        
		if (m_container == nullptr) {
			return nil;
		}

		m_packageList = m_container->Packages();
		m_packages = [[NSMutableArray alloc] initWithCapacity:4];

		for (auto i = m_packageList.begin(); i != m_packageList.end(); i++) {
			RDPackage *package = [[RDPackage alloc] initWithPackage:i->get()];
			[m_packages addObject:package];
		}
	}

	return self;
}

- (BOOL)fileExistsAtPath:(NSString *)relativePath {
    return m_container->FileExistsAtPath([relativePath UTF8String]);
}

- (NSString *)contentsOfFileAtPath:(NSString *)relativePath encoding:(NSStringEncoding)encoding {
    if (![self fileExistsAtPath:relativePath])
    	return nil;

    std::unique_ptr<ePub3::ByteStream> stream = m_container->ReadStreamAtPath([relativePath UTF8String]);
    if (stream == nullptr)
    	return nil;

    void *buffer = nullptr;
    size_t length = stream->ReadAllBytes(&buffer);
    std::string nativeContent((char *)buffer, length);
    free (buffer);

    return [NSString stringWithCString:nativeContent.c_str() encoding:encoding];
}

@end
