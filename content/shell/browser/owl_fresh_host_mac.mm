#include "content/shell/browser/owl_fresh_host_mac.h"

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/process/process.h"
#include "base/strings/strcat.h"
#include "base/strings/stringprintf.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/input/render_widget_host_input_event_router.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "components/viz/host/client_frame_sink_video_capturer.h"
#include "content/browser/devtools/devtools_video_consumer.h"
#include "content/browser/renderer_host/owl_fresh_web_contents_role.h"
#include "content/browser/renderer_host/popup_menu_helper_mac.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/browser/renderer_host/render_widget_host_view_base.h"
#include "content/browser/web_contents/web_contents_impl.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_devtools_frontend.h"
#include "media/base/video_frame.h"
#include "media/base/video_types.h"
#include "media/capture/mojom/video_capture_buffer.mojom.h"
#include "media/capture/mojom/video_capture_types.mojom.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/bindings/self_owned_receiver.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "third_party/blink/public/common/input/web_mouse_wheel_event.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/accelerated_widget_mac/owl_fresh_context.h"
#include "ui/base/cocoa/remote_layer_api.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/snapshot/snapshot.h"
#include "url/gurl.h"

@interface CAContext (OwlFreshRemoteContext)
+ (instancetype)remoteContextWithOptions:(NSDictionary*)optionsDict;
@end

namespace content {
namespace {

int g_owl_fresh_force_redraw_id = 1;
Shell* g_owl_fresh_inspected_shell = nullptr;

struct OwlFreshPendingFilePicker {
  scoped_refptr<FileSelectListener> listener;
  blink::mojom::FileChooserParams::Mode mode =
      blink::mojom::FileChooserParams::Mode::kOpen;
  uint64_t surface_key = 0;
};

OwlFreshPendingFilePicker& ActiveFilePicker() {
  static base::NoDestructor<OwlFreshPendingFilePicker> picker;
  return *picker;
}

bool OwlFreshSelectActiveFilePickerFiles(const std::vector<std::string>& paths);
bool OwlFreshCancelActiveFilePicker();

Shell* CurrentShell() {
  std::vector<Shell*>& windows = Shell::windows();
  if (g_owl_fresh_inspected_shell) {
    for (Shell* shell : windows) {
      if (shell == g_owl_fresh_inspected_shell) {
        return shell;
      }
    }
    g_owl_fresh_inspected_shell = nullptr;
  }
  if (windows.empty()) {
    return nullptr;
  }
  return windows[0];
}

WebContents* CurrentWebContents() {
  Shell* shell = CurrentShell();
  return shell ? shell->web_contents() : nullptr;
}

std::string FilePickerModeToString(blink::mojom::FileChooserParams::Mode mode) {
  switch (mode) {
    case blink::mojom::FileChooserParams::Mode::kOpen:
      return "open";
    case blink::mojom::FileChooserParams::Mode::kOpenMultiple:
      return "open-multiple";
    case blink::mojom::FileChooserParams::Mode::kOpenDirectory:
      return "open-directory";
    case blink::mojom::FileChooserParams::Mode::kUploadFolder:
      return "upload-folder";
    case blink::mojom::FileChooserParams::Mode::kSave:
      return "save";
  }
}

bool FilePickerAllowsMultiple(blink::mojom::FileChooserParams::Mode mode) {
  return mode == blink::mojom::FileChooserParams::Mode::kOpenMultiple;
}

bool FilePickerUploadsFolder(blink::mojom::FileChooserParams::Mode mode) {
  return mode == blink::mojom::FileChooserParams::Mode::kUploadFolder;
}

std::vector<std::string> AcceptTypesToUTF8(
    const std::vector<std::u16string>& accept_types) {
  std::vector<std::string> result;
  result.reserve(accept_types.size());
  for (const std::u16string& accept_type : accept_types) {
    result.push_back(base::UTF16ToUTF8(accept_type));
  }
  return result;
}

CGRect FilePickerSurfaceBounds() {
  WebContents* contents = CurrentWebContents();
  if (!contents) {
    return CGRectMake(64, 64, 720, 420);
  }
  gfx::Rect bounds = contents->GetContainerBounds();
  return CGRectMake(0, 0, std::max(bounds.width(), 480),
                    std::max(bounds.height(), 320));
}

NSWindow* CurrentWindow() {
  WebContents* contents = CurrentWebContents();
  if (!contents) {
    return nil;
  }
  NSView* view = contents->GetNativeView().GetNativeNSView();
  return view.window;
}

RenderWidgetHost* CurrentRenderWidgetHost() {
  WebContents* contents = CurrentWebContents();
  if (!contents) {
    return nullptr;
  }
  RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
  return view ? view->GetRenderWidgetHost() : nullptr;
}

void EnsureRenderWidgetProducingFramesForOwlFresh() {
  WebContents* contents = CurrentWebContents();
  if (!contents) {
    return;
  }
  contents->WasShown();
  RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
  if (view) {
    if (!view->IsShowing()) {
      view->Show();
    }
    view->WasUnOccluded();
    view->EnsureSurfaceSynchronizedForWebTest();
  }
  if (RenderWidgetHost* host = CurrentRenderWidgetHost()) {
    auto* host_impl = static_cast<RenderWidgetHostImpl*>(host);
    if (host_impl->IsHidden()) {
      host_impl->WasShown(std::nullopt);
    }
    host_impl->SetActive(true);
    host_impl->RequestForceRedraw(g_owl_fresh_force_redraw_id++);
  }
}

std::string CopyFromSurfaceErrorToString(CopyFromSurfaceError error) {
  switch (error) {
    case CopyFromSurfaceError::kUnknown:
      return "CopyFromSurface failed: unknown";
    case CopyFromSurfaceError::kNotImplemented:
      return "CopyFromSurface failed: not implemented";
    case CopyFromSurfaceError::kFrameGone:
      return "CopyFromSurface failed: frame gone";
    case CopyFromSurfaceError::kTimeout:
      return "CopyFromSurface failed: timeout";
    case CopyFromSurfaceError::kEmbeddingTokenChanged:
      return "CopyFromSurface failed: embedding token changed";
    case CopyFromSurfaceError::kVizSentEmptyBitmap:
      return "CopyFromSurface failed: viz sent empty bitmap";
    case CopyFromSurfaceError::kUnknownVizError:
      return "CopyFromSurface failed: unknown viz error";
  }
  return "CopyFromSurface failed";
}

mojom::OwlFreshCaptureResultPtr CaptureError(const std::string& message) {
  auto result = mojom::OwlFreshCaptureResult::New();
  result->capture_mode = "mojo-copy-from-surface";
  result->error = message;
  return result;
}

struct OwlFreshDevToolsDockBounds {
  gfx::Rect web_bounds;
  gfx::Rect devtools_bounds;
};

int ClampOwlFreshDockSize(int value, int lower, int upper) {
  return std::min(std::max(value, lower), upper);
}

OwlFreshDevToolsDockBounds ComputeOwlFreshDevToolsDockBounds(
    mojom::OwlFreshDevToolsMode mode,
    int width,
    int height) {
  constexpr int kMinimumWebContentWidth = 420;
  constexpr int kMinimumWebContentHeight = 320;
  constexpr int kMinimumSideDevToolsWidth = 480;
  constexpr int kPreferredSideDevToolsWidth = 520;
  constexpr int kMaximumSideDevToolsWidth = 720;
  constexpr int kMinimumBottomDevToolsHeight = 280;
  constexpr int kPreferredBottomDevToolsHeight = 320;
  constexpr int kMaximumBottomDevToolsHeight = 420;

  OwlFreshDevToolsDockBounds bounds = {
      gfx::Rect(0, 0, width, height),
      gfx::Rect(0, 0, width, height),
  };

  const int side_width_upper = std::min(
      kMaximumSideDevToolsWidth, std::max(1, width - kMinimumWebContentWidth));
  const int side_width_lower =
      std::min(kMinimumSideDevToolsWidth, side_width_upper);
  const int side_width =
      ClampOwlFreshDockSize(std::max(kPreferredSideDevToolsWidth, width / 2),
                            side_width_lower, side_width_upper);

  const int bottom_height_upper =
      std::min(kMaximumBottomDevToolsHeight,
               std::max(1, height - kMinimumWebContentHeight));
  const int bottom_height_lower =
      std::min(kMinimumBottomDevToolsHeight, bottom_height_upper);
  const int bottom_height = ClampOwlFreshDockSize(
      kPreferredBottomDevToolsHeight, bottom_height_lower, bottom_height_upper);

  switch (mode) {
    case mojom::OwlFreshDevToolsMode::kBottom:
      bounds.web_bounds =
          gfx::Rect(0, bottom_height, width, height - bottom_height);
      bounds.devtools_bounds = gfx::Rect(0, 0, width, bottom_height);
      break;
    case mojom::OwlFreshDevToolsMode::kRight:
      bounds.web_bounds = gfx::Rect(0, 0, width - side_width, height);
      bounds.devtools_bounds =
          gfx::Rect(width - side_width, 0, side_width, height);
      break;
    case mojom::OwlFreshDevToolsMode::kLeft:
      bounds.web_bounds = gfx::Rect(side_width, 0, width - side_width, height);
      bounds.devtools_bounds = gfx::Rect(0, 0, side_width, height);
      break;
    case mojom::OwlFreshDevToolsMode::kWindow:
      break;
  }
  return bounds;
}

std::string CaptureState(WebContents* contents, RenderWidgetHostView* view) {
  std::string url = contents ? contents->GetLastCommittedURL().spec() : "";
  gfx::Rect bounds = view ? view->GetViewBounds() : gfx::Rect();
  NSWindow* window = CurrentWindow();
  RenderWidgetHost* render_host = CurrentRenderWidgetHost();
  int host_hidden =
      render_host ? static_cast<RenderWidgetHostImpl*>(render_host)->IsHidden()
                  : -1;
  return base::StringPrintf(
      "url=%s loading=%d view_showing=%d surface_available=%d bounds=%s "
      "context_id=%u web_contents_visibility=%d host_hidden=%d "
      "window_visible=%d window_alpha=%.3f",
      url.c_str(), contents ? contents->IsLoading() : 0,
      view ? view->IsShowing() : 0,
      view ? view->IsSurfaceAvailableForCopy() : 0, bounds.ToString().c_str(),
      ui::OwlFreshLatestContextID(),
      contents ? static_cast<int>(contents->GetVisibility()) : -1, host_hidden,
      window ? [window isVisible] : 0, window ? [window alphaValue] : 0.0);
}

std::string CaptureStateError(const std::string& message,
                              WebContents* contents,
                              RenderWidgetHostView* view) {
  return base::StrCat({message, " (", CaptureState(contents, view), ")"});
}

mojom::OwlFreshCaptureResultPtr CaptureAppKitViewSnapshot(
    NSView* view,
    const std::string& capture_state) {
  if (!view) {
    return CaptureError("no NSView for AppKit snapshot");
  }

  NSRect bounds = view.bounds;
  if (NSIsEmptyRect(bounds)) {
    return CaptureError(
        base::StrCat({"NSView bounds are empty (", capture_state, ")"}));
  }

  NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:bounds];
  if (!rep) {
    return CaptureError(
        base::StrCat({"bitmapImageRepForCachingDisplayInRect returned nil (",
                      capture_state, ")"}));
  }
  [view cacheDisplayInRect:bounds toBitmapImageRep:rep];
  NSData* data = [rep representationUsingType:NSBitmapImageFileTypePNG
                                   properties:@{}];
  if (!data || data.length == 0) {
    return CaptureError(base::StrCat(
        {"AppKit snapshot returned empty PNG data (", capture_state, ")"}));
  }

  auto result = mojom::OwlFreshCaptureResult::New();
  result->png.resize(static_cast<size_t>(data.length));
  const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
  UNSAFE_BUFFERS(base::span(result->png))
      .copy_from(UNSAFE_BUFFERS(
          base::span<const uint8_t>(bytes, static_cast<size_t>(data.length))));
  result->width = static_cast<uint32_t>(rep.pixelsWide);
  result->height = static_cast<uint32_t>(rep.pixelsHigh);
  result->capture_mode = "mojo-appkit-cache-display";
  return result;
}

int BlinkModifiersFromCocoa(uint32_t cocoa) {
  int modifiers = 0;
  if (cocoa & NSEventModifierFlagShift) {
    modifiers |= blink::WebInputEvent::kShiftKey;
  }
  if (cocoa & NSEventModifierFlagControl) {
    modifiers |= blink::WebInputEvent::kControlKey;
  }
  if (cocoa & NSEventModifierFlagOption) {
    modifiers |= blink::WebInputEvent::kAltKey;
  }
  if (cocoa & NSEventModifierFlagCommand) {
    modifiers |= blink::WebInputEvent::kMetaKey;
  }
  if (cocoa & NSEventModifierFlagCapsLock) {
    modifiers |= blink::WebInputEvent::kCapsLockOn;
  }
  return modifiers;
}

class OwlFreshVideoCapture final : public viz::mojom::FrameSinkVideoConsumer {
 public:
  using FrameCallback = base::OnceCallback<void(SkBitmap bitmap)>;
  using ErrorCallback = base::OnceCallback<void(std::string message)>;

  OwlFreshVideoCapture(RenderWidgetHostView* view,
                       FrameCallback frame_callback,
                       ErrorCallback error_callback)
      : view_(view),
        frame_callback_(std::move(frame_callback)),
        error_callback_(std::move(error_callback)) {}

  OwlFreshVideoCapture(const OwlFreshVideoCapture&) = delete;
  OwlFreshVideoCapture& operator=(const OwlFreshVideoCapture&) = delete;

  ~OwlFreshVideoCapture() override {
    if (capturer_) {
      capturer_->Stop();
    }
  }

  void Start() {
    if (!view_) {
      FinishError("no view for frame-sink video capture");
      return;
    }
    capturer_ = view_->CreateVideoCapturer();
    if (!capturer_) {
      FinishError("CreateVideoCapturer returned null");
      return;
    }
    gfx::Size size = view_->GetViewBounds().size();
    if (size.IsEmpty()) {
      FinishError("view bounds are empty for frame-sink video capture");
      return;
    }
    capturer_->SetResolutionConstraints(size, size, false);
    capturer_->SetAutoThrottlingEnabled(false);
    capturer_->SetMinSizeChangePeriod(base::TimeDelta());
    capturer_->SetFormat(media::PIXEL_FORMAT_ARGB);
    capturer_->SetMinCapturePeriod(base::Milliseconds(16));
    capturer_->Start(this, viz::mojom::BufferFormatPreference::kDefault);
  }

 private:
  void OnFrameCaptured(
      media::mojom::VideoBufferHandlePtr data,
      media::mojom::VideoFrameInfoPtr info,
      const gfx::Rect& content_rect,
      mojo::PendingRemote<viz::mojom::FrameSinkVideoConsumerFrameCallbacks>
          callbacks) override {
    if (!frame_callback_) {
      return;
    }
    mojo::Remote<viz::mojom::FrameSinkVideoConsumerFrameCallbacks>
        callbacks_remote(std::move(callbacks));
    if (!data->is_read_only_shmem_region()) {
      FinishError("video capture returned non-shared-memory frame");
      return;
    }
    base::ReadOnlySharedMemoryRegion& shmem_region =
        data->get_read_only_shmem_region();
    base::ReadOnlySharedMemoryMapping mapping = shmem_region.Map();
    if (!mapping.IsValid()) {
      FinishError("video capture shared-memory mapping failed");
      return;
    }
    base::span<const uint8_t> mapping_memory(mapping);
    if (mapping_memory.size() < media::VideoFrame::AllocationSize(
                                    info->pixel_format, info->coded_size)) {
      FinishError("video capture shared-memory frame was too small");
      return;
    }

    scoped_refptr<media::VideoFrame> frame =
        media::VideoFrame::WrapExternalData(
            info->pixel_format, info->coded_size, content_rect,
            content_rect.size(), mapping_memory, info->timestamp);
    if (!frame) {
      FinishError("video capture could not wrap frame memory");
      return;
    }
    frame->set_metadata(info->metadata);
    frame->set_color_space(info->color_space);
    SkBitmap bitmap = DevToolsVideoConsumer::GetSkBitmapFromFrame(frame);
    callbacks_remote->Done();
    FrameCallback callback = std::move(frame_callback_);
    error_callback_.Reset();
    std::move(callback).Run(std::move(bitmap));
  }

  void OnNewCaptureVersion(
      const media::CaptureVersion& capture_version) override {}
  void OnFrameWithEmptyRegionCapture() override {}
  void OnStopped() override {}
  void OnLog(const std::string& message) override {}

  void FinishError(const std::string& message) {
    if (!error_callback_) {
      return;
    }
    ErrorCallback callback = std::move(error_callback_);
    frame_callback_.Reset();
    std::move(callback).Run(message);
  }

  raw_ptr<RenderWidgetHostView> view_;
  FrameCallback frame_callback_;
  ErrorCallback error_callback_;
  std::unique_ptr<viz::ClientFrameSinkVideoCapturer> capturer_;
};

void FocusWebContents(bool focused) {
  NSWindow* window = CurrentWindow();
  WebContents* contents = CurrentWebContents();
  RenderWidgetHost* host = CurrentRenderWidgetHost();
  if (!window || !contents || !host) {
    return;
  }
  if (!focused) {
    [window makeFirstResponder:nil];
    host->SetActive(false);
    return;
  }
  NSView* view = contents->GetNativeView().GetNativeNSView();
  [window makeFirstResponder:view];
  host->SetActive(true);
  host->Focus();
}

mojom::OwlFreshCompositorInfoPtr CompositorInfoForContextID(
    uint32_t context_id) {
  auto info = mojom::OwlFreshCompositorInfo::New();
  info->context_id = context_id;
  return info;
}

mojom::OwlFreshSurfaceKind SurfaceKindToMojom(ui::OwlFreshSurfaceKind kind) {
  switch (kind) {
    case ui::OwlFreshSurfaceKind::kWebView:
      return mojom::OwlFreshSurfaceKind::kWebView;
    case ui::OwlFreshSurfaceKind::kPopupWidget:
      return mojom::OwlFreshSurfaceKind::kPopupWidget;
    case ui::OwlFreshSurfaceKind::kNativeMenu:
      return mojom::OwlFreshSurfaceKind::kNativeMenu;
    case ui::OwlFreshSurfaceKind::kNativeFilePicker:
      return mojom::OwlFreshSurfaceKind::kNativeFilePicker;
    case ui::OwlFreshSurfaceKind::kDevTools:
      return mojom::OwlFreshSurfaceKind::kDevTools;
  }
}

mojom::OwlFreshSurfaceTreePtr SurfaceTreeFromRegistry() {
  auto tree = mojom::OwlFreshSurfaceTree::New();
  tree->generation = ui::OwlFreshDisplayPortalGeneration();
  for (const ui::OwlFreshSurfaceSnapshot& snapshot :
       ui::OwlFreshSurfaceTreeSnapshot()) {
    auto surface = mojom::OwlFreshSurfaceInfo::New();
    surface->surface_id = snapshot.surface_id;
    surface->parent_surface_id = snapshot.parent_surface_id;
    surface->kind = SurfaceKindToMojom(snapshot.kind);
    surface->context_id = snapshot.context_id;
    surface->x = static_cast<int32_t>(snapshot.bounds.origin.x);
    surface->y = static_cast<int32_t>(snapshot.bounds.origin.y);
    surface->width = static_cast<uint32_t>(snapshot.bounds.size.width);
    surface->height = static_cast<uint32_t>(snapshot.bounds.size.height);
    surface->scale = snapshot.scale;
    surface->z_index = snapshot.z_index;
    surface->visible = snapshot.visible;
    surface->menu_items = snapshot.menu_items;
    for (const ui::OwlFreshNativeMenuItem& snapshot_item :
         snapshot.native_menu_items) {
      auto item = mojom::OwlFreshNativeMenuItem::New();
      item->label = snapshot_item.label;
      item->tool_tip = snapshot_item.tool_tip;
      item->enabled = snapshot_item.enabled;
      item->separator = snapshot_item.separator;
      item->group = snapshot_item.group;
      item->text_direction = snapshot_item.text_direction;
      item->has_text_direction_override =
          snapshot_item.has_text_direction_override;
      surface->native_menu_items.push_back(std::move(item));
    }
    surface->selected_index = snapshot.selected_index;
    surface->item_font_size = snapshot.item_font_size;
    surface->right_aligned = snapshot.right_aligned;
    surface->file_picker_mode = snapshot.file_picker_mode;
    surface->file_picker_accept_types = snapshot.file_picker_accept_types;
    surface->file_picker_allows_multiple = snapshot.file_picker_allows_multiple;
    surface->file_picker_upload_folder = snapshot.file_picker_upload_folder;
    surface->label = snapshot.label;
    tree->surfaces.push_back(std::move(surface));
  }
  return tree;
}

class OwlFreshSessionImpl final : public mojom::OwlFreshSession,
                                  public mojom::OwlFreshProfile,
                                  public mojom::OwlFreshWebView,
                                  public mojom::OwlFreshInput,
                                  public mojom::OwlFreshSurfaceTreeHost,
                                  public mojom::OwlFreshNativeSurfaceHost,
                                  public mojom::OwlFreshDevToolsHost {
 public:
  OwlFreshSessionImpl() = default;
  ~OwlFreshSessionImpl() override = default;

  OwlFreshSessionImpl(const OwlFreshSessionImpl&) = delete;
  OwlFreshSessionImpl& operator=(const OwlFreshSessionImpl&) = delete;

  void SetClient(mojo::PendingRemote<mojom::OwlFreshClient> client) override {
    client_.Bind(std::move(client));
    g_owl_fresh_inspected_shell = CurrentShell();
    EnsureRenderWidgetProducingFramesForOwlFresh();
    if (client_) {
      client_->OnReady(base::GetCurrentProcId(), CurrentCompositorInfo());
      client_->OnSurfaceTreeChanged(SurfaceTreeFromRegistry());
      client_->OnHostLog("OwlFreshSession bound over Mojo");
    }
    PublishCompositorWithRetry(80);
  }

  void BindProfile(
      mojo::PendingReceiver<mojom::OwlFreshProfile> receiver) override {
    profile_receivers_.Add(this, std::move(receiver));
  }

  void BindWebView(
      mojo::PendingReceiver<mojom::OwlFreshWebView> receiver) override {
    web_view_receivers_.Add(this, std::move(receiver));
  }

  void BindInput(
      mojo::PendingReceiver<mojom::OwlFreshInput> receiver) override {
    input_receivers_.Add(this, std::move(receiver));
  }

  void BindSurfaceTree(
      mojo::PendingReceiver<mojom::OwlFreshSurfaceTreeHost> receiver) override {
    surface_tree_receivers_.Add(this, std::move(receiver));
  }

  void BindNativeSurfaceHost(
      mojo::PendingReceiver<mojom::OwlFreshNativeSurfaceHost> receiver)
      override {
    native_surface_receivers_.Add(this, std::move(receiver));
  }

  void BindDevToolsHost(
      mojo::PendingReceiver<mojom::OwlFreshDevToolsHost> receiver) override {
    devtools_host_receivers_.Add(this, std::move(receiver));
  }

  void GetPath(GetPathCallback callback) override {
    WebContents* contents = CurrentWebContents();
    BrowserContext* context =
        contents ? contents->GetBrowserContext() : nullptr;
    std::move(callback).Run(context ? context->GetPath().AsUTF8Unsafe()
                                    : std::string());
  }

  void Navigate(const std::string& url) override {
    Shell* shell = CurrentShell();
    if (!shell) {
      Log("Navigate dropped: no shell");
      return;
    }
    shell->LoadURL(GURL(url));
    EnsureRenderWidgetProducingFramesForOwlFresh();
    if (client_) {
      client_->OnNavigationChanged(url, std::string(), true);
    }
    PublishCompositorWithRetry(40);
  }

  void Resize(uint32_t width, uint32_t height, float scale) override {
    Shell* shell = CurrentShell();
    WebContents* contents = shell ? shell->web_contents() : nullptr;
    if (!shell || !contents || width == 0 || height == 0) {
      Log("Resize dropped: no shell/WebContents or empty size");
      return;
    }
    gfx::Size size(width, height);
    requested_size_ = size;
    ui::OwlFreshClearDevToolsDockLayout();
    NSSize content_size = NSMakeSize(width, height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shell->ResizeWebContentForTests(size);
    if (NSWindow* window = CurrentWindow()) {
      [window setContentSize:content_size];
      [window.contentView setNeedsLayout:YES];
    }
    NSView* native_view = contents->GetNativeView().GetNativeNSView();
    [native_view setFrameSize:content_size];
    [native_view setNeedsLayout:YES];
    [native_view layoutSubtreeIfNeeded];
    if (RenderWidgetHostView* view = contents->GetRenderWidgetHostView()) {
      view->SetSize(size);
    }
    if (RenderWidgetHost* render_host = CurrentRenderWidgetHost()) {
      static_cast<RenderWidgetHostImpl*>(render_host)
          ->SynchronizeVisualPropertiesIgnoringPendingAck();
    }
    [CATransaction commit];
    [CATransaction flush];
    EnsureRenderWidgetProducingFramesForOwlFresh();
    ui::OwlFreshDisplayPortalResize(CGRectMake(0, 0, width, height));
    PublishCompositorWithRetry(10);
    Log(base::StringPrintf("Resize applied width=%u height=%u", width, height));
  }

  void SetFocus(bool focused) override {
    FocusWebContents(focused);
    if (focused) {
      EnsureRenderWidgetProducingFramesForOwlFresh();
    }
  }

  void SendMouse(mojom::OwlFreshMouseEventPtr event) override {
    if (!event) {
      Log("SendMouse dropped: missing event");
      return;
    }
    Log(base::StringPrintf("SendMouse received kind=%d x=%.1f y=%.1f",
                           static_cast<int>(event->kind), event->x, event->y));
    WebContents* contents = CurrentWebContents();
    if (!contents) {
      Log("SendMouse dropped: no WebContents");
      return;
    }
    auto* web_contents_impl = static_cast<WebContentsImpl*>(contents);
    RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
    if (!view) {
      Log("SendMouse dropped: no RenderWidgetHostView");
      return;
    }
    auto* view_base = static_cast<RenderWidgetHostViewBase*>(view);
    RenderWidgetHostImpl* host =
        web_contents_impl->GetRenderWidgetHostWithPageFocus();
    if (!host && view) {
      host = static_cast<RenderWidgetHostImpl*>(view->GetRenderWidgetHost());
    }
    if (!host) {
      Log("SendMouse dropped: no RenderWidgetHost");
      return;
    }
    host->input_router()->MakeActive();
    host->SetActive(true);
    host->Focus();
    int modifiers = BlinkModifiersFromCocoa(event->modifiers);
    base::TimeTicks now = base::TimeTicks::Now();

    if (event->kind == mojom::OwlFreshMouseKind::kWheel) {
      blink::WebMouseWheelEvent wheel(blink::WebInputEvent::Type::kMouseWheel,
                                      modifiers, now);
      wheel.SetPositionInWidget(event->x, event->y);
      wheel.SetPositionInScreen(event->x, event->y);
      wheel.delta_x = event->delta_x;
      wheel.delta_y = event->delta_y;
      wheel.wheel_ticks_x = event->delta_x / 100.0f;
      wheel.wheel_ticks_y = event->delta_y / 100.0f;
      wheel.delta_units = ui::ScrollGranularity::kScrollByPrecisePixel;
      wheel.dispatch_type = blink::WebInputEvent::DispatchType::kBlocking;
      wheel.event_action =
          blink::WebMouseWheelEvent::EventAction::kScrollVertical;
      wheel.phase = blink::WebMouseWheelEvent::kPhaseBegan;
      web_contents_impl->GetInputEventRouter()->RouteMouseWheelEvent(
          view_base, &wheel, ui::LatencyInfo());
      EnsureRenderWidgetProducingFramesForOwlFresh();
      MarkLayerFixtureInput();
      Log("SendMouse forwarded wheel");
      return;
    }

    blink::WebInputEvent::Type type = blink::WebInputEvent::Type::kMouseMove;
    if (event->kind == mojom::OwlFreshMouseKind::kDown) {
      type = blink::WebInputEvent::Type::kMouseDown;
    } else if (event->kind == mojom::OwlFreshMouseKind::kUp) {
      type = blink::WebInputEvent::Type::kMouseUp;
    }

    blink::WebPointerProperties::Button button =
        blink::WebPointerProperties::Button::kNoButton;
    if (event->button == 0) {
      button = blink::WebPointerProperties::Button::kLeft;
    } else if (event->button == 1) {
      button = blink::WebPointerProperties::Button::kMiddle;
    } else if (event->button == 2) {
      button = blink::WebPointerProperties::Button::kRight;
    }

    if (type == blink::WebInputEvent::Type::kMouseDown) {
      if (button == blink::WebPointerProperties::Button::kLeft) {
        modifiers |= blink::WebInputEvent::kLeftButtonDown;
      } else if (button == blink::WebPointerProperties::Button::kRight) {
        modifiers |= blink::WebInputEvent::kRightButtonDown;
      } else if (button == blink::WebPointerProperties::Button::kMiddle) {
        modifiers |= blink::WebInputEvent::kMiddleButtonDown;
      }
    }

    blink::WebMouseEvent mouse(type, modifiers, now);
    mouse.SetPositionInWidget(event->x, event->y);
    gfx::Rect offset = contents->GetContainerBounds();
    mouse.SetPositionInScreen(event->x + offset.x(), event->y + offset.y());
    mouse.button = type == blink::WebInputEvent::Type::kMouseMove
                       ? blink::WebPointerProperties::Button::kNoButton
                       : button;
    mouse.click_count = event->click_count > 0 ? event->click_count : 1;
    web_contents_impl->GetInputEventRouter()->RouteMouseEvent(
        view_base, &mouse, ui::LatencyInfo());
    EnsureRenderWidgetProducingFramesForOwlFresh();
    MarkLayerFixtureInput();
    Log("SendMouse forwarded routed mouse");
  }

  void SendKey(mojom::OwlFreshKeyEventPtr event) override {
    if (!event) {
      Log("SendKey dropped: missing event");
      return;
    }
    Log(base::StringPrintf("SendKey received key_down=%d key_code=%u text=%s",
                           event->key_down, event->key_code,
                           event->text.c_str()));
    WebContents* contents = CurrentWebContents();
    if (!contents) {
      Log("SendKey dropped: no WebContents");
      return;
    }
    auto* web_contents_impl = static_cast<WebContentsImpl*>(contents);
    RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
    RenderWidgetHostImpl* host =
        web_contents_impl->GetRenderWidgetHostWithPageFocus();
    if (!host && view) {
      host = static_cast<RenderWidgetHostImpl*>(view->GetRenderWidgetHost());
    }
    if (!host) {
      Log("SendKey dropped: no RenderWidgetHost");
      return;
    }
    host->input_router()->MakeActive();
    host->SetActive(true);
    host->Focus();

    int modifiers = BlinkModifiersFromCocoa(event->modifiers);
    blink::WebInputEvent::Type type =
        event->key_down ? blink::WebInputEvent::Type::kRawKeyDown
                        : blink::WebInputEvent::Type::kKeyUp;
    input::NativeWebKeyboardEvent key_event(type, modifiers,
                                            base::TimeTicks::Now());
    key_event.native_key_code = event->key_code;
    key_event.windows_key_code = event->key_code;
    CopyText(event->text, &key_event);
    host->ForwardKeyboardEvent(key_event);
    Log("SendKey forwarded key event");

    if (event->key_down && !event->text.empty()) {
      input::NativeWebKeyboardEvent char_event(
          blink::WebInputEvent::Type::kChar, modifiers, base::TimeTicks::Now());
      char_event.native_key_code = event->key_code;
      char_event.windows_key_code = event->key_code;
      CopyText(event->text, &char_event);
      host->ForwardKeyboardEvent(char_event);
      Log("SendKey forwarded char event");
    }
    EnsureRenderWidgetProducingFramesForOwlFresh();
    MarkLayerFixtureInput();
  }

  void Flush(FlushCallback callback) override {
    EnsureRenderWidgetProducingFramesForOwlFresh();
    std::move(callback).Run(true);
  }

  void CaptureSurface(CaptureSurfaceCallback callback) override {
    WebContents* contents = CurrentWebContents();
    if (!contents) {
      std::move(callback).Run(CaptureError("no current WebContents"));
      return;
    }

    RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
    if (!view) {
      std::move(callback).Run(CaptureError("no RenderWidgetHostView"));
      return;
    }

    if (!view->IsSurfaceAvailableForCopy()) {
      std::move(callback).Run(CaptureError(CaptureStateError(
          "RenderWidgetHostView surface is not available", contents, view)));
      return;
    }

    if (!view->IsShowing()) {
      view->Show();
    }
    view->WasUnOccluded();
    view->EnsureSurfaceSynchronizedForWebTest();

    if (view->GetViewBounds().size().IsEmpty()) {
      std::move(callback).Run(CaptureError(CaptureStateError(
          "RenderWidgetHostView bounds are empty", contents, view)));
      return;
    }

    if (!pending_capture_callback_.is_null()) {
      std::move(callback).Run(CaptureError(CaptureStateError(
          "CaptureSurface already has a pending request", contents, view)));
      return;
    }

    pending_capture_state_ = CaptureState(contents, view);
    const bool from_surface =
        !base::CommandLine::ForCurrentProcess()->HasSwitch(
            "owl-fresh-window-snapshot");

    if (!from_surface) {
      std::move(callback).Run(CaptureAppKitViewSnapshot(
          view->GetNativeView().GetNativeNSView(), pending_capture_state_));
      pending_capture_state_.clear();
      pending_capture_mode_.clear();
      return;
    }

    pending_capture_mode_ = "mojo-frame-sink-video-capture";
    pending_capture_callback_ = std::move(callback);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&OwlFreshSessionImpl::OnCaptureSurfaceTimeout,
                       weak_factory_.GetWeakPtr()),
        base::Seconds(20));

    video_capture_ = std::make_unique<OwlFreshVideoCapture>(
        view,
        base::BindOnce(&OwlFreshSessionImpl::OnVideoCaptureFrame,
                       weak_factory_.GetWeakPtr()),
        base::BindOnce(&OwlFreshSessionImpl::OnVideoCaptureError,
                       weak_factory_.GetWeakPtr()));
    video_capture_->Start();
    return;
  }

  void GetSurfaceTree(GetSurfaceTreeCallback callback) override {
    std::move(callback).Run(SurfaceTreeFromRegistry());
  }

  void AcceptActivePopupMenuItem(
      uint32_t index,
      AcceptActivePopupMenuItemCallback callback) override {
    const bool ok = OwlFreshAcceptActivePopupMenuItem(index);
    if (client_) {
      client_->OnSurfaceTreeChanged(SurfaceTreeFromRegistry());
    }
    std::move(callback).Run(ok);
  }

  void CancelActivePopup(CancelActivePopupCallback callback) override {
    const bool ok = OwlFreshCancelActivePopupMenu();
    ui::OwlFreshClearNativeMenuSurfaces();
    if (client_) {
      client_->OnSurfaceTreeChanged(SurfaceTreeFromRegistry());
    }
    std::move(callback).Run(ok);
  }

  void SelectActiveFilePickerFiles(
      const std::vector<std::string>& paths,
      SelectActiveFilePickerFilesCallback callback) override {
    const bool ok = OwlFreshSelectActiveFilePickerFiles(paths);
    ui::OwlFreshClearNativeFilePickerSurfaces();
    if (client_) {
      client_->OnSurfaceTreeChanged(SurfaceTreeFromRegistry());
    }
    std::move(callback).Run(ok);
  }

  void CancelActiveFilePicker(
      CancelActiveFilePickerCallback callback) override {
    const bool ok = OwlFreshCancelActiveFilePicker();
    ui::OwlFreshClearNativeFilePickerSurfaces();
    if (client_) {
      client_->OnSurfaceTreeChanged(SurfaceTreeFromRegistry());
    }
    std::move(callback).Run(ok);
  }

  void OpenDevTools(mojom::OwlFreshDevToolsMode mode,
                    OpenDevToolsCallback callback) override {
    Shell* shell = CurrentShell();
    if (!shell || !shell->web_contents()) {
      Log("OpenDevTools dropped: no shell/WebContents");
      std::move(callback).Run(false);
      return;
    }

    std::string label = "devtools-bottom";
    std::string dock_state = "bottom";
    switch (mode) {
      case mojom::OwlFreshDevToolsMode::kBottom:
        label = "devtools-bottom";
        dock_state = "bottom";
        break;
      case mojom::OwlFreshDevToolsMode::kRight:
        label = "devtools-right";
        dock_state = "right";
        break;
      case mojom::OwlFreshDevToolsMode::kLeft:
        label = "devtools-left";
        dock_state = "left";
        break;
      case mojom::OwlFreshDevToolsMode::kWindow:
        label = "devtools-window";
        dock_state = "undocked";
        break;
    }
    ui::OwlFreshSetDevToolsSurfaceLabel(label);

    if (!devtools_frontend_) {
      ShellDevToolsFrontend* frontend =
          ShellDevToolsFrontend::Show(shell->web_contents(), dock_state);
      devtools_frontend_ = frontend->GetWeakPtr();
      if (frontend->frontend_shell()) {
        owl_fresh::MarkDevToolsFrontend(
            frontend->frontend_shell()->web_contents());
      }
    }

    WebContents* inspected_contents = shell->web_contents();
    WebContents* devtools_contents = ActiveDevToolsWebContents();
    if (!devtools_contents) {
      Log("OpenDevTools failed: frontend WebContents was not created");
      std::move(callback).Run(false);
      return;
    }
    owl_fresh::MarkDevToolsFrontend(devtools_contents);

    gfx::Rect inspected_bounds = inspected_contents->GetContainerBounds();
    const int width =
        std::max({requested_size_.width(), inspected_bounds.width(), 800});
    const int height =
        std::max({requested_size_.height(), inspected_bounds.height(), 600});
    const OwlFreshDevToolsDockBounds dock_bounds =
        ComputeOwlFreshDevToolsDockBounds(mode, width, height);
    const gfx::Rect web_bounds = dock_bounds.web_bounds;
    const gfx::Rect devtools_bounds = dock_bounds.devtools_bounds;
    shell->ResizeWebContentForTests(web_bounds.size());
    devtools_frontend_->frontend_shell()->ResizeWebContentForTests(
        devtools_bounds.size());
    ui::OwlFreshSetDevToolsDockLayout(
        label,
        CGRectMake(web_bounds.x(), web_bounds.y(), web_bounds.width(),
                   web_bounds.height()),
        CGRectMake(devtools_bounds.x(), devtools_bounds.y(),
                   devtools_bounds.width(), devtools_bounds.height()));
    EnsureWebContentsProducingFrames(inspected_contents);
    EnsureWebContentsProducingFrames(devtools_contents);
    devtools_frontend_->InspectElementAt(std::max(1, web_bounds.width() / 2),
                                         std::max(1, web_bounds.height() / 2));
    devtools_contents->Focus();
    PublishCompositorWithRetry(60);
    Log(base::StrCat({"DevTools opened label=", label}));
    std::move(callback).Run(true);
  }

  void CloseDevTools(CloseDevToolsCallback callback) override {
    if (!devtools_frontend_) {
      std::move(callback).Run(false);
      return;
    }
    devtools_frontend_->Close();
    devtools_frontend_ = base::WeakPtr<ShellDevToolsFrontend>();
    ui::OwlFreshClearDevToolsDockLayout();
    if (Shell* shell = CurrentShell()) {
      shell->ResizeWebContentForTests(requested_size_);
      EnsureWebContentsProducingFrames(shell->web_contents());
    }
    if (client_) {
      client_->OnSurfaceTreeChanged(SurfaceTreeFromRegistry());
    }
    std::move(callback).Run(true);
  }

  void EvaluateDevToolsJavaScript(
      const std::string& script,
      EvaluateDevToolsJavaScriptCallback callback) override {
    WebContents* contents = ActiveDevToolsWebContents();
    if (!contents) {
      std::move(callback).Run("null");
      return;
    }
    contents->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
        base::UTF8ToUTF16(script),
        base::BindOnce(
            [](EvaluateDevToolsJavaScriptCallback callback,
               base::Value result) {
              std::string json;
              if (!base::JSONWriter::Write(result, &json)) {
                json = "null";
              }
              std::move(callback).Run(json);
            },
            std::move(callback)),
        ISOLATED_WORLD_ID_GLOBAL);
  }

 private:
  WebContents* ActiveDevToolsWebContents() const {
    if (!devtools_frontend_) {
      return nullptr;
    }
    Shell* frontend_shell = devtools_frontend_->frontend_shell();
    return frontend_shell ? frontend_shell->web_contents() : nullptr;
  }

  void EnsureWebContentsProducingFrames(WebContents* contents) {
    if (!contents) {
      return;
    }
    contents->WasShown();
    RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
    if (view) {
      if (!view->IsShowing()) {
        view->Show();
      }
      view->WasUnOccluded();
      view->EnsureSurfaceSynchronizedForWebTest();
    }
    if (RenderWidgetHost* host = view ? view->GetRenderWidgetHost() : nullptr) {
      auto* host_impl = static_cast<RenderWidgetHostImpl*>(host);
      if (host_impl->IsHidden()) {
        host_impl->WasShown(std::nullopt);
      }
      host_impl->SetActive(true);
      host_impl->Focus();
      host_impl->SynchronizeVisualPropertiesIgnoringPendingAck();
    }
  }

  void CopyText(const std::string& text, input::NativeWebKeyboardEvent* event) {
    size_t n =
        std::min(text.size(), blink::WebKeyboardEvent::kTextLengthCap - 1);
    for (size_t i = 0; i < n; ++i) {
      event->text[i] =
          static_cast<char16_t>(static_cast<unsigned char>(text[i]));
      event->unmodified_text[i] = event->text[i];
    }
    event->text[n] = 0;
    event->unmodified_text[n] = 0;
  }

  void PublishCompositorWithRetry(int attempts_remaining) {
    if (!client_) {
      return;
    }
    uint32_t context_id = CurrentContextID();
    if (context_id != 0) {
      if (context_id != last_context_id_) {
        last_context_id_ = context_id;
      }
      client_->OnCompositorChanged(CompositorInfoForContextID(context_id));
      client_->OnSurfaceTreeChanged(SurfaceTreeFromRegistry());
    }
    if (attempts_remaining <= 0) {
      return;
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&OwlFreshSessionImpl::PublishCompositorWithRetry,
                       weak_factory_.GetWeakPtr(), attempts_remaining - 1),
        base::Milliseconds(100));
  }

  bool UseLayerFixtureContext() const {
    return base::CommandLine::ForCurrentProcess()->HasSwitch(
        "owl-fresh-layer-fixture-context");
  }

  mojom::OwlFreshCompositorInfoPtr CurrentCompositorInfo() {
    return CompositorInfoForContextID(CurrentContextID());
  }

  uint32_t CurrentContextID() {
    if (UseLayerFixtureContext()) {
      return EnsureLayerFixtureContext();
    }
    return ui::OwlFreshLatestContextID();
  }

  uint32_t EnsureLayerFixtureContext() {
    if (!fixture_context_) {
      fixture_root_ = [[CALayer alloc] init];
      fixture_root_.geometryFlipped = YES;
      fixture_root_.anchorPoint = CGPointZero;
      fixture_root_.frame = CGRectMake(0, 0, 960, 640);
      fixture_root_.backgroundColor =
          [[NSColor colorWithCalibratedRed:0.972
                                     green:0.972
                                      blue:0.972
                                     alpha:1.0] CGColor];

      auto add_block = [&](CGFloat x, CGFloat y, CGFloat width, CGFloat height,
                           NSColor* color) {
        CALayer* layer = [[CALayer alloc] init];
        layer.anchorPoint = CGPointZero;
        layer.frame = CGRectMake(x, y, width, height);
        layer.backgroundColor = [color CGColor];
        [fixture_root_ addSublayer:layer];
        return layer;
      };
      fixture_input_layer_ = add_block(48, 56, 244, 148,
                                       [NSColor colorWithCalibratedRed:1
                                                                 green:0
                                                                  blue:0
                                                                 alpha:1]);
      add_block(288, 56, 180, 140,
                [NSColor colorWithCalibratedRed:0
                                          green:0.8
                                           blue:0.267
                                          alpha:1]);
      add_block(528, 56, 180, 140,
                [NSColor colorWithCalibratedRed:0 green:0.349 blue:1 alpha:1]);

      CATextLayer* text = [CATextLayer layer];
      text.anchorPoint = CGPointZero;
      text.frame = CGRectMake(48, 238, 760, 72);
      text.string = @"OWL_INPUT_READY";
      text.fontSize = 40;
      text.contentsScale = [NSScreen mainScreen].backingScaleFactor;
      text.foregroundColor = [[NSColor colorWithCalibratedRed:0.078
                                                        green:0.078
                                                         blue:0.078
                                                        alpha:1.0] CGColor];
      [fixture_root_ addSublayer:text];
      fixture_text_layer_ = text;

      if ([CAContext respondsToSelector:@selector(contextWithCGSConnection:
                                                                   options:)]) {
        CGSConnectionID connection = CGSMainConnectionID();
        fixture_context_ = [CAContext contextWithCGSConnection:connection
                                                       options:@{}];
      } else {
        fixture_context_ = [CAContext remoteContextWithOptions:@{}];
      }
      fixture_context_.layer = fixture_root_;
      [CATransaction flush];
    }
    return fixture_context_.contextId;
  }

  void MarkLayerFixtureInput() {
    if (!UseLayerFixtureContext()) {
      return;
    }
    EnsureLayerFixtureContext();
    fixture_input_layer_.backgroundColor =
        [[NSColor colorWithCalibratedRed:1.0 green:0.824 blue:0.0
                                   alpha:1.0] CGColor];
    fixture_text_layer_.string = @"OWL_INPUT_CLICKED";
    [fixture_input_layer_ setNeedsDisplay];
    [fixture_text_layer_ setNeedsDisplay];
    [CATransaction flush];
    if (client_) {
      client_->OnCompositorChanged(CurrentCompositorInfo());
    }
  }

  void Log(const std::string& message) {
    if (client_) {
      client_->OnHostLog(message);
    }
  }

  void OnCaptureSurface(const CopyFromSurfaceResult& copy_result) {
    if (pending_capture_callback_.is_null()) {
      return;
    }

    CaptureSurfaceCallback callback = std::move(pending_capture_callback_);
    std::string capture_state = std::exchange(pending_capture_state_, "");
    pending_capture_mode_.clear();

    if (!copy_result.has_value()) {
      std::move(callback).Run(CaptureError(
          base::StrCat({CopyFromSurfaceErrorToString(copy_result.error()), " (",
                        capture_state, ")"})));
      return;
    }

    const SkBitmap& bitmap = copy_result->bitmap;
    if (bitmap.drawsNothing()) {
      std::move(callback).Run(CaptureError(base::StrCat(
          {"CopyFromSurface returned no pixels (", capture_state, ")"})));
      return;
    }

    std::optional<std::vector<uint8_t>> png =
        gfx::PNGCodec::EncodeBGRASkBitmap(bitmap,
                                          /*discard_transparency=*/false);
    if (!png || png->empty()) {
      std::move(callback).Run(CaptureError("failed to encode PNG"));
      return;
    }

    auto result = mojom::OwlFreshCaptureResult::New();
    result->png = std::move(*png);
    result->width = bitmap.width();
    result->height = bitmap.height();
    result->capture_mode = "mojo-copy-from-surface";
    std::move(callback).Run(std::move(result));
  }

  void OnSnapshotFromBrowser(const gfx::Image& image) {
    if (pending_capture_callback_.is_null()) {
      return;
    }

    CaptureSurfaceCallback callback = std::move(pending_capture_callback_);
    std::string capture_state = std::exchange(pending_capture_state_, "");
    std::string capture_mode = std::exchange(pending_capture_mode_, "");

    if (image.IsEmpty()) {
      std::move(callback).Run(CaptureError(
          base::StrCat({"GetSnapshotFromBrowser returned an empty image (",
                        capture_state, ")"})));
      return;
    }

    SkBitmap bitmap = image.AsBitmap();
    if (bitmap.drawsNothing()) {
      std::move(callback).Run(CaptureError(
          base::StrCat({"GetSnapshotFromBrowser returned no pixels (",
                        capture_state, ")"})));
      return;
    }

    std::optional<std::vector<uint8_t>> png =
        gfx::PNGCodec::EncodeBGRASkBitmap(bitmap,
                                          /*discard_transparency=*/false);
    if (!png || png->empty()) {
      std::move(callback).Run(CaptureError("failed to encode PNG"));
      return;
    }

    auto result = mojom::OwlFreshCaptureResult::New();
    result->png = std::move(*png);
    result->width = bitmap.width();
    result->height = bitmap.height();
    result->capture_mode = capture_mode;
    std::move(callback).Run(std::move(result));
  }

  void OnVideoCaptureFrame(SkBitmap bitmap) {
    video_capture_.reset();
    if (pending_capture_callback_.is_null()) {
      return;
    }

    CaptureSurfaceCallback callback = std::move(pending_capture_callback_);
    std::string capture_state = std::exchange(pending_capture_state_, "");
    std::string capture_mode = std::exchange(pending_capture_mode_, "");

    if (bitmap.drawsNothing()) {
      std::move(callback).Run(CaptureError(
          base::StrCat({"FrameSinkVideoCapturer returned no pixels (",
                        capture_state, ")"})));
      return;
    }

    std::optional<std::vector<uint8_t>> png =
        gfx::PNGCodec::EncodeBGRASkBitmap(bitmap,
                                          /*discard_transparency=*/false);
    if (!png || png->empty()) {
      std::move(callback).Run(CaptureError("failed to encode PNG"));
      return;
    }

    auto result = mojom::OwlFreshCaptureResult::New();
    result->png = std::move(*png);
    result->width = bitmap.width();
    result->height = bitmap.height();
    result->capture_mode = capture_mode;
    std::move(callback).Run(std::move(result));
  }

  void OnVideoCaptureError(std::string message) {
    video_capture_.reset();
    if (pending_capture_callback_.is_null()) {
      return;
    }

    CaptureSurfaceCallback callback = std::move(pending_capture_callback_);
    std::string capture_state = std::exchange(pending_capture_state_, "");
    pending_capture_mode_.clear();
    std::move(callback).Run(
        CaptureError(base::StrCat({message, " (", capture_state, ")"})));
  }

  void OnGrabViewSnapshot(const gfx::Image& image) {
    OnSnapshotFromBrowser(image);
  }

  void OnSnapshotError(const std::string& message) {
    if (pending_capture_callback_.is_null()) {
      return;
    }

    CaptureSurfaceCallback callback = std::move(pending_capture_callback_);
    pending_capture_state_.clear();
    pending_capture_mode_.clear();
    std::move(callback).Run(CaptureError(message));
  }

  void OnCaptureSurfaceTimeout() {
    if (pending_capture_callback_.is_null()) {
      return;
    }

    CaptureSurfaceCallback callback = std::move(pending_capture_callback_);
    std::string capture_state = std::exchange(pending_capture_state_, "");
    pending_capture_mode_.clear();
    video_capture_.reset();
    std::move(callback).Run(CaptureError(
        base::StrCat({"capture did not call back before host timeout (",
                      capture_state, ")"})));
  }

  mojo::Remote<mojom::OwlFreshClient> client_;
  uint32_t last_context_id_ = 0;
  gfx::Size requested_size_{960, 640};
  CAContext* __strong fixture_context_ = nil;
  CALayer* __strong fixture_root_ = nil;
  CALayer* __strong fixture_input_layer_ = nil;
  CATextLayer* __strong fixture_text_layer_ = nil;
  CaptureSurfaceCallback pending_capture_callback_;
  std::string pending_capture_state_;
  std::string pending_capture_mode_;
  std::unique_ptr<OwlFreshVideoCapture> video_capture_;
  mojo::ReceiverSet<mojom::OwlFreshProfile> profile_receivers_;
  mojo::ReceiverSet<mojom::OwlFreshWebView> web_view_receivers_;
  mojo::ReceiverSet<mojom::OwlFreshInput> input_receivers_;
  mojo::ReceiverSet<mojom::OwlFreshSurfaceTreeHost> surface_tree_receivers_;
  mojo::ReceiverSet<mojom::OwlFreshNativeSurfaceHost> native_surface_receivers_;
  mojo::ReceiverSet<mojom::OwlFreshDevToolsHost> devtools_host_receivers_;
  base::WeakPtr<ShellDevToolsFrontend> devtools_frontend_;
  base::WeakPtrFactory<OwlFreshSessionImpl> weak_factory_{this};
};
bool OwlFreshSelectActiveFilePickerFiles(
    const std::vector<std::string>& paths) {
  OwlFreshPendingFilePicker& pending = ActiveFilePicker();
  if (!pending.listener || paths.empty()) {
    return false;
  }

  std::vector<blink::mojom::FileChooserFileInfoPtr> files;
  files.reserve(paths.size());
  for (const std::string& path : paths) {
    base::FilePath file_path(path);
    files.push_back(blink::mojom::FileChooserFileInfo::NewNativeFile(
        blink::mojom::NativeFileInfo::New(file_path,
                                          file_path.BaseName().AsUTF16Unsafe(),
                                          std::vector<std::u16string>())));
  }

  scoped_refptr<FileSelectListener> listener = std::move(pending.listener);
  blink::mojom::FileChooserParams::Mode mode = pending.mode;
  pending.surface_key = 0;
  listener->FileSelected(std::move(files), base::FilePath(), mode);
  return true;
}

bool OwlFreshCancelActiveFilePicker() {
  OwlFreshPendingFilePicker& pending = ActiveFilePicker();
  if (!pending.listener) {
    return false;
  }
  scoped_refptr<FileSelectListener> listener = std::move(pending.listener);
  pending.surface_key = 0;
  listener->FileSelectionCanceled();
  return true;
}

}  // namespace

bool OwlFreshMaybeRunFileChooser(
    RenderFrameHost* render_frame_host,
    scoped_refptr<FileSelectListener> listener,
    const blink::mojom::FileChooserParams& params) {
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("fresh-owl-embed")) {
    return false;
  }
  if (!render_frame_host || !listener) {
    return false;
  }

  OwlFreshPendingFilePicker& pending = ActiveFilePicker();
  if (pending.listener) {
    pending.listener->FileSelectionCanceled();
  }

  pending.listener = std::move(listener);
  pending.mode = params.mode;
  pending.surface_key = reinterpret_cast<uint64_t>(pending.listener.get());

  ui::OwlFreshPublishNativeFilePickerSurface(
      pending.surface_key, 0, FilePickerSurfaceBounds(),
      [NSScreen mainScreen].backingScaleFactor,
      FilePickerModeToString(params.mode),
      AcceptTypesToUTF8(params.accept_types),
      FilePickerAllowsMultiple(params.mode),
      FilePickerUploadsFolder(params.mode), "file-picker");
  return true;
}

void BindOwlFreshSessionForCurrentShell(
    mojo::PendingReceiver<mojom::OwlFreshSession> receiver) {
  mojo::MakeSelfOwnedReceiver(std::make_unique<OwlFreshSessionImpl>(),
                              std::move(receiver));
}

}  // namespace content
