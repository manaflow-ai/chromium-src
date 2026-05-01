#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^OwlFreshMojoRuntimeEventHandler)(NSInteger kind,
                                                uint32_t contextID,
                                                int32_t hostPID,
                                                BOOL loading,
                                                NSString* _Nullable url,
                                                NSString* _Nullable title,
                                                NSString* _Nullable message);

@protocol OwlFreshMojoRuntimeSessionBridge <NSObject>
@property(nonatomic, readonly) int32_t hostPID;

- (void)destroy;
- (BOOL)setClientWithHandle:(uint64_t)handle
                      error:(NSError**)error NS_SWIFT_NAME(setClient(handle:));
- (BOOL)setClientWithRemoteHandle:(uint64_t)remoteHandle
                   receiverHandle:(uint64_t)receiverHandle
                            error:(NSError**)error
    NS_SWIFT_NAME(setClient(remoteHandle:receiverHandle:));
- (BOOL)setClientWithRemoteHandle:(uint64_t)remoteHandle
                            error:(NSError**)error
    NS_SWIFT_NAME(setClient(remoteHandle:));
- (BOOL)bindProfileWithHandle:(uint64_t)handle
                        error:(NSError**)error
    NS_SWIFT_NAME(bindProfile(handle:));
- (BOOL)bindProfileWithRemoteHandle:(uint64_t)remoteHandle
                     receiverHandle:(uint64_t)receiverHandle
                              error:(NSError**)error
    NS_SWIFT_NAME(bindProfile(remoteHandle:receiverHandle:));
- (BOOL)bindProfileWithReceiverHandle:(uint64_t)receiverHandle
                                error:(NSError**)error
    NS_SWIFT_NAME(bindProfile(receiverHandle:));
- (BOOL)bindWebViewWithHandle:(uint64_t)handle
                        error:(NSError**)error
    NS_SWIFT_NAME(bindWebView(handle:));
- (BOOL)bindWebViewWithRemoteHandle:(uint64_t)remoteHandle
                     receiverHandle:(uint64_t)receiverHandle
                              error:(NSError**)error
    NS_SWIFT_NAME(bindWebView(remoteHandle:receiverHandle:));
- (BOOL)bindWebViewWithReceiverHandle:(uint64_t)receiverHandle
                                error:(NSError**)error
    NS_SWIFT_NAME(bindWebView(receiverHandle:));
- (BOOL)bindInputWithHandle:(uint64_t)handle
                      error:(NSError**)error NS_SWIFT_NAME(bindInput(handle:));
- (BOOL)bindInputWithRemoteHandle:(uint64_t)remoteHandle
                   receiverHandle:(uint64_t)receiverHandle
                            error:(NSError**)error
    NS_SWIFT_NAME(bindInput(remoteHandle:receiverHandle:));
- (BOOL)bindInputWithReceiverHandle:(uint64_t)receiverHandle
                              error:(NSError**)error
    NS_SWIFT_NAME(bindInput(receiverHandle:));
- (BOOL)bindSurfaceTreeWithHandle:(uint64_t)handle
                            error:(NSError**)error
    NS_SWIFT_NAME(bindSurfaceTree(handle:));
- (BOOL)bindSurfaceTreeWithRemoteHandle:(uint64_t)remoteHandle
                         receiverHandle:(uint64_t)receiverHandle
                                  error:(NSError**)error
    NS_SWIFT_NAME(bindSurfaceTree(remoteHandle:receiverHandle:));
- (BOOL)bindSurfaceTreeWithReceiverHandle:(uint64_t)receiverHandle
                                    error:(NSError**)error
    NS_SWIFT_NAME(bindSurfaceTree(receiverHandle:));
- (BOOL)bindNativeSurfaceHostWithHandle:(uint64_t)handle
                                  error:(NSError**)error
    NS_SWIFT_NAME(bindNativeSurfaceHost(handle:));
- (BOOL)bindNativeSurfaceHostWithRemoteHandle:(uint64_t)remoteHandle
                               receiverHandle:(uint64_t)receiverHandle
                                        error:(NSError**)error
    NS_SWIFT_NAME(bindNativeSurfaceHost(remoteHandle:receiverHandle:));
- (BOOL)bindNativeSurfaceHostWithReceiverHandle:(uint64_t)receiverHandle
                                          error:(NSError**)error
    NS_SWIFT_NAME(bindNativeSurfaceHost(receiverHandle:));
- (BOOL)bindDevToolsHostWithHandle:(uint64_t)handle
                             error:(NSError**)error
    NS_SWIFT_NAME(bindDevToolsHost(handle:));
- (BOOL)bindDevToolsHostWithRemoteHandle:(uint64_t)remoteHandle
                          receiverHandle:(uint64_t)receiverHandle
                                   error:(NSError**)error
    NS_SWIFT_NAME(bindDevToolsHost(remoteHandle:receiverHandle:));
- (BOOL)bindDevToolsHostWithReceiverHandle:(uint64_t)receiverHandle
                                     error:(NSError**)error
    NS_SWIFT_NAME(bindDevToolsHost(receiverHandle:));
- (nullable NSNumber*)flushWithError:(NSError**)error NS_SWIFT_NAME(flush());
- (nullable NSString*)profilePathWithError:(NSError**)error
    NS_SWIFT_NAME(profilePath());
- (nullable NSString*)executeJavaScript:(NSString*)script
                                  error:(NSError**)error;
- (BOOL)navigateToURL:(NSString*)url
                error:(NSError**)error NS_SWIFT_NAME(navigate(to:));
- (BOOL)resizeWithWidth:(uint32_t)width
                 height:(uint32_t)height
                  scale:(float)scale
                  error:(NSError**)error
    NS_SWIFT_NAME(resize(width:height:scale:));
- (BOOL)setFocus:(BOOL)focused error:(NSError**)error;
- (BOOL)sendMouseWithKind:(uint32_t)kind
                        x:(float)x
                        y:(float)y
                   button:(uint32_t)button
               clickCount:(uint32_t)clickCount
                   deltaX:(float)deltaX
                   deltaY:(float)deltaY
                modifiers:(uint32_t)modifiers
                    error:(NSError**)error
    NS_SWIFT_NAME(sendMouse(kind:x:y:button:clickCount:deltaX:deltaY:modifiers:));
- (BOOL)sendKeyWithKeyDown:(BOOL)keyDown
                   keyCode:(uint32_t)keyCode
                      text:(NSString*)text
                 modifiers:(uint32_t)modifiers
                     error:(NSError**)error
    NS_SWIFT_NAME(sendKey(keyDown:keyCode:text:modifiers:));
- (nullable NSString*)captureSurfaceJSONWithError:(NSError**)error
    NS_SWIFT_NAME(captureSurfaceJSON());
- (nullable NSString*)captureSurfaceJSONWithLabel:(NSString*)label
                                            error:(NSError**)error
    NS_SWIFT_NAME(captureSurfaceJSON(label:));
- (nullable NSString*)surfaceTreeJSONWithError:(NSError**)error
    NS_SWIFT_NAME(surfaceTreeJSON());
- (nullable NSNumber*)acceptActivePopupMenuItemAtIndex:(uint32_t)index
                                                 error:(NSError**)error
    NS_SWIFT_NAME(acceptActivePopupMenuItem(index:));
- (nullable NSNumber*)cancelActivePopupWithError:(NSError**)error
    NS_SWIFT_NAME(cancelActivePopup());
- (nullable NSNumber*)selectActiveFilePickerFilesJSON:(NSString*)pathsJSON
                                                error:(NSError**)error;
- (nullable NSNumber*)cancelActiveFilePickerWithError:(NSError**)error
    NS_SWIFT_NAME(cancelActiveFilePicker());
- (nullable NSNumber*)openDevToolsWithMode:(uint32_t)mode
                                     error:(NSError**)error
    NS_SWIFT_NAME(openDevTools(mode:));
- (nullable NSNumber*)closeDevToolsWithError:(NSError**)error
    NS_SWIFT_NAME(closeDevTools());
- (nullable NSString*)evaluateDevToolsJavaScript:(NSString*)script
                                           error:(NSError**)error;
@end

@protocol OwlFreshMojoRuntimeBridgeProtocol <NSObject>
- (BOOL)initializeRuntimeWithError:(NSError**)error
    NS_SWIFT_NAME(initializeRuntime());
- (nullable id<OwlFreshMojoRuntimeSessionBridge>)
    createSessionWithContentShellPath:(NSString*)contentShellPath
                           initialURL:(NSString*)initialURL
                    userDataDirectory:(NSString*)userDataDirectory
                         eventHandler:
                             (OwlFreshMojoRuntimeEventHandler)eventHandler
                                error:(NSError**)error
    NS_SWIFT_NAME(createSession(contentShellPath:initialURL:userDataDirectory:eventHandler:));
- (void)pollEventsWithMilliseconds:(uint32_t)milliseconds
    NS_SWIFT_NAME(pollEvents(milliseconds:));
@end

@interface OwlFreshMojoRuntimeBridge
    : NSObject <OwlFreshMojoRuntimeBridgeProtocol>
@end

NS_ASSUME_NONNULL_END
