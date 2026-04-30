#include "fresh_owl/owl_fresh_mojo_runtime_objc.h"

#include <utility>

#include "base/memory/raw_ptr.h"
#include "fresh_owl/owl_fresh_mojo_runtime.h"

namespace {

NSError* OwlFreshNSError(NSString* message) {
  return [NSError errorWithDomain:@"OwlFreshMojoRuntime"
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

BOOL FinishStatus(int status, char* c_error, NSError** error) {
  if (status == 0) {
    if (c_error) {
      owl_fresh_mojo_free_buffer(c_error);
    }
    return YES;
  }
  if (error) {
    NSString* message =
        c_error ? [NSString stringWithUTF8String:c_error] : @"unknown Mojo runtime error";
    *error = OwlFreshNSError(message ?: @"unknown Mojo runtime error");
  }
  if (c_error) {
    owl_fresh_mojo_free_buffer(c_error);
  }
  return NO;
}

NSString* ConsumeString(char* value) {
  if (!value) {
    return @"";
  }
  NSString* result = [NSString stringWithUTF8String:value] ?: @"";
  owl_fresh_mojo_free_buffer(value);
  return result;
}

}  // namespace

@interface OwlFreshMojoRuntimeSessionBridgeImpl
    : NSObject <OwlFreshMojoRuntimeSessionBridge>
- (instancetype)initWithEventHandler:(OwlFreshMojoRuntimeEventHandler)eventHandler;
- (void)setSession:(OwlFreshMojoSession*)session;
- (void)emitEvent:(const OwlFreshMojoEvent*)event;
@end

static void OwlFreshMojoRuntimeEventThunk(const OwlFreshMojoEvent* event,
                                          void* user_data) {
  if (!event || !user_data) {
    return;
  }
  OwlFreshMojoRuntimeSessionBridgeImpl* session =
      (__bridge OwlFreshMojoRuntimeSessionBridgeImpl*)user_data;
  [session emitEvent:event];
}

@implementation OwlFreshMojoRuntimeSessionBridgeImpl {
  raw_ptr<OwlFreshMojoSession> _session;
  OwlFreshMojoRuntimeEventHandler _eventHandler;
  BOOL _destroyed;
}

- (instancetype)initWithEventHandler:(OwlFreshMojoRuntimeEventHandler)eventHandler {
  self = [super init];
  if (self) {
    _eventHandler = [eventHandler copy];
  }
  return self;
}

- (void)dealloc {
  [self destroy];
}

- (void)setSession:(OwlFreshMojoSession*)session {
  _session = session;
}

- (int32_t)hostPID {
  return _session ? owl_fresh_mojo_session_host_pid(_session) : -1;
}

- (void)destroy {
  if (_destroyed || !_session) {
    return;
  }
  _destroyed = YES;
  owl_fresh_mojo_session_destroy(_session);
  _session = nullptr;
}

- (void)emitEvent:(const OwlFreshMojoEvent*)event {
  if (!_eventHandler || !event) {
    return;
  }
  NSString* url = event->url ? [NSString stringWithUTF8String:event->url] : nil;
  NSString* title =
      event->title ? [NSString stringWithUTF8String:event->title] : nil;
  NSString* message =
      event->message ? [NSString stringWithUTF8String:event->message] : nil;
  _eventHandler(event->kind, event->context_id, event->host_pid,
                event->loading, url, title, message);
}

- (BOOL)setClientWithHandle:(uint64_t)handle error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(owl_fresh_mojo_session_set_client(_session, handle, &c_error),
                      c_error, error);
}

- (BOOL)bindProfileWithHandle:(uint64_t)handle error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(owl_fresh_mojo_session_bind_profile(_session, handle, &c_error),
                      c_error, error);
}

- (BOOL)bindWebViewWithHandle:(uint64_t)handle error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(owl_fresh_mojo_session_bind_web_view(_session, handle, &c_error),
                      c_error, error);
}

- (BOOL)bindInputWithHandle:(uint64_t)handle error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(owl_fresh_mojo_session_bind_input(_session, handle, &c_error),
                      c_error, error);
}

- (BOOL)bindSurfaceTreeWithHandle:(uint64_t)handle error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(
      owl_fresh_mojo_session_bind_surface_tree(_session, handle, &c_error),
      c_error, error);
}

- (BOOL)bindNativeSurfaceHostWithHandle:(uint64_t)handle error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(
      owl_fresh_mojo_session_bind_native_surface_host(_session, handle, &c_error),
      c_error, error);
}

- (BOOL)bindDevToolsHostWithHandle:(uint64_t)handle error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(
      owl_fresh_mojo_session_bind_devtools_host(_session, handle, &c_error),
      c_error, error);
}

- (nullable NSNumber*)flushWithError:(NSError**)error {
  BOOL ok = NO;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_session_flush(_session, &ok, &c_error),
                    c_error, error)) {
    return nil;
  }
  return @(ok);
}

- (nullable NSString*)profilePathWithError:(NSError**)error {
  char* path = nullptr;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_profile_get_path(_session, &path, &c_error),
                    c_error, error)) {
    return nil;
  }
  return ConsumeString(path);
}

- (nullable NSString*)executeJavaScript:(NSString*)script error:(NSError**)error {
  char* result = nullptr;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_shell_execute_javascript(
                        _session, script.UTF8String, &result, &c_error),
                    c_error, error)) {
    return nil;
  }
  return ConsumeString(result);
}

- (BOOL)navigateToURL:(NSString*)url error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(
      owl_fresh_mojo_web_view_navigate(_session, url.UTF8String, &c_error),
      c_error, error);
}

- (BOOL)resizeWithWidth:(uint32_t)width
                 height:(uint32_t)height
                  scale:(float)scale
                  error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(
      owl_fresh_mojo_web_view_resize(_session, width, height, scale, &c_error),
      c_error, error);
}

- (BOOL)setFocus:(BOOL)focused error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(
      owl_fresh_mojo_web_view_set_focus(_session, focused, &c_error), c_error,
      error);
}

- (BOOL)sendMouseWithKind:(uint32_t)kind
                        x:(float)x
                        y:(float)y
                   button:(uint32_t)button
               clickCount:(uint32_t)clickCount
                   deltaX:(float)deltaX
                   deltaY:(float)deltaY
                modifiers:(uint32_t)modifiers
                    error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(owl_fresh_mojo_input_send_mouse(
                          _session, kind, x, y, button, clickCount, deltaX,
                          deltaY, modifiers, &c_error),
                      c_error, error);
}

- (BOOL)sendKeyWithKeyDown:(BOOL)keyDown
                   keyCode:(uint32_t)keyCode
                      text:(NSString*)text
                 modifiers:(uint32_t)modifiers
                     error:(NSError**)error {
  char* c_error = nullptr;
  return FinishStatus(owl_fresh_mojo_input_send_key(
                          _session, keyDown, keyCode, text.UTF8String,
                          modifiers, &c_error),
                      c_error, error);
}

- (nullable NSString*)captureSurfaceJSONWithError:(NSError**)error {
  char* result = nullptr;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_surface_tree_capture_surface_json(
                        _session, &result, &c_error),
                    c_error, error)) {
    return nil;
  }
  return ConsumeString(result);
}

- (nullable NSString*)surfaceTreeJSONWithError:(NSError**)error {
  char* result = nullptr;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_surface_tree_get_json(_session, &result,
                                                         &c_error),
                    c_error, error)) {
    return nil;
  }
  return ConsumeString(result);
}

- (nullable NSNumber*)acceptActivePopupMenuItemAtIndex:(uint32_t)index
                                                error:(NSError**)error {
  BOOL ok = NO;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_native_surface_accept_active_popup_menu_item(
                        _session, index, &ok, &c_error),
                    c_error, error)) {
    return nil;
  }
  return @(ok);
}

- (nullable NSNumber*)cancelActivePopupWithError:(NSError**)error {
  BOOL ok = NO;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_native_surface_cancel_active_popup(
                        _session, &ok, &c_error),
                    c_error, error)) {
    return nil;
  }
  return @(ok);
}

- (nullable NSNumber*)selectActiveFilePickerFilesJSON:(NSString*)pathsJSON
                                               error:(NSError**)error {
  BOOL ok = NO;
  char* c_error = nullptr;
  if (!FinishStatus(
          owl_fresh_mojo_native_surface_select_active_file_picker_files_json(
              _session, pathsJSON.UTF8String, &ok, &c_error),
          c_error, error)) {
    return nil;
  }
  return @(ok);
}

- (nullable NSNumber*)cancelActiveFilePickerWithError:(NSError**)error {
  BOOL ok = NO;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_native_surface_cancel_active_file_picker(
                        _session, &ok, &c_error),
                    c_error, error)) {
    return nil;
  }
  return @(ok);
}

- (nullable NSNumber*)openDevToolsWithMode:(uint32_t)mode error:(NSError**)error {
  BOOL ok = NO;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_devtools_open(_session, mode, &ok, &c_error),
                    c_error, error)) {
    return nil;
  }
  return @(ok);
}

- (nullable NSNumber*)closeDevToolsWithError:(NSError**)error {
  BOOL ok = NO;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_devtools_close(_session, &ok, &c_error),
                    c_error, error)) {
    return nil;
  }
  return @(ok);
}

- (nullable NSString*)evaluateDevToolsJavaScript:(NSString*)script
                                          error:(NSError**)error {
  char* result = nullptr;
  char* c_error = nullptr;
  if (!FinishStatus(owl_fresh_mojo_devtools_evaluate_javascript(
                        _session, script.UTF8String, &result, &c_error),
                    c_error, error)) {
    return nil;
  }
  return ConsumeString(result);
}

@end

@implementation OwlFreshMojoRuntimeBridge

- (BOOL)initializeRuntimeWithError:(NSError**)error {
  const int status = owl_fresh_mojo_global_init();
  if (status == 0) {
    return YES;
  }
  if (error) {
    *error = OwlFreshNSError(@"owl_fresh_mojo_global_init failed");
  }
  return NO;
}

- (nullable id<OwlFreshMojoRuntimeSessionBridge>)
    createSessionWithContentShellPath:(NSString*)contentShellPath
                           initialURL:(NSString*)initialURL
                    userDataDirectory:(NSString*)userDataDirectory
                         eventHandler:(OwlFreshMojoRuntimeEventHandler)eventHandler
                                error:(NSError**)error {
  OwlFreshMojoRuntimeSessionBridgeImpl* session_object =
      [[OwlFreshMojoRuntimeSessionBridgeImpl alloc]
          initWithEventHandler:eventHandler];
  OwlFreshMojoSession* session = owl_fresh_mojo_session_create(
      contentShellPath.UTF8String, initialURL.UTF8String,
      userDataDirectory.UTF8String, OwlFreshMojoRuntimeEventThunk,
      (__bridge void*)session_object);
  if (!session) {
    if (error) {
      *error = OwlFreshNSError(@"owl_fresh_mojo_session_create returned null");
    }
    return nil;
  }
  [session_object setSession:session];
  return session_object;
}

- (void)pollEventsWithMilliseconds:(uint32_t)milliseconds {
  owl_fresh_mojo_poll_events(milliseconds);
}

@end
