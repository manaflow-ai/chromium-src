#ifndef UI_ACCELERATED_WIDGET_MAC_OWL_FRESH_CONTEXT_H_
#define UI_ACCELERATED_WIDGET_MAC_OWL_FRESH_CONTEXT_H_

#include <stdint.h>

#include <string>
#include <vector>

#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>

#include "base/functional/callback.h"
#include "ui/accelerated_widget_mac/accelerated_widget_mac_export.h"

#if defined(__OBJC__)
@class CALayer;
#endif

namespace gfx {
class Size;
}  // namespace gfx

namespace ui {

enum class OwlFreshSurfaceKind {
  kWebView = 0,
  kPopupWidget = 1,
  kNativeMenu = 2,
  kNativeFilePicker = 3,
  kDevTools = 4,
};

struct OwlFreshNativeMenuItem {
  OwlFreshNativeMenuItem();
  OwlFreshNativeMenuItem(const OwlFreshNativeMenuItem&);
  OwlFreshNativeMenuItem& operator=(const OwlFreshNativeMenuItem&);
  ~OwlFreshNativeMenuItem();

  std::string label;
  std::string tool_tip;
  bool enabled = true;
  bool separator = false;
  bool group = false;
  uint32_t text_direction = 2;
  bool has_text_direction_override = false;
};

struct OwlFreshSurfaceSnapshot {
  OwlFreshSurfaceSnapshot();
  OwlFreshSurfaceSnapshot(const OwlFreshSurfaceSnapshot&);
  OwlFreshSurfaceSnapshot& operator=(const OwlFreshSurfaceSnapshot&);
  ~OwlFreshSurfaceSnapshot();

  uint64_t surface_id = 0;
  uint64_t parent_surface_id = 0;
  OwlFreshSurfaceKind kind = OwlFreshSurfaceKind::kWebView;
  uint32_t context_id = 0;
  CGRect bounds = CGRectZero;
  float scale = 1.0f;
  int32_t z_index = 0;
  bool visible = false;
  std::vector<std::string> menu_items;
  std::vector<OwlFreshNativeMenuItem> native_menu_items;
  int32_t selected_index = -1;
  float item_font_size = 0.0f;
  bool right_aligned = false;
  std::string file_picker_mode;
  std::vector<std::string> file_picker_accept_types;
  bool file_picker_allows_multiple = false;
  bool file_picker_upload_folder = false;
  std::string label;
};

ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshSetLatestContextID(uint32_t id);
ACCELERATED_WIDGET_MAC_EXPORT uint32_t OwlFreshLatestContextID();
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshSetLatestCursorType(int32_t type);
ACCELERATED_WIDGET_MAC_EXPORT int32_t OwlFreshLatestCursorType();
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshSetDevToolsSurfaceLabel(
    const std::string& label);
ACCELERATED_WIDGET_MAC_EXPORT std::string OwlFreshDevToolsSurfaceLabel();
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshSetDevToolsDockLayout(
    const std::string& label,
    CGRect web_bounds,
    CGRect devtools_bounds);
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshClearDevToolsDockLayout();
ACCELERATED_WIDGET_MAC_EXPORT uint64_t OwlFreshDisplayPortalGeneration();
using OwlFreshSurfaceTreeChangedCallback = base::RepeatingCallback<void()>;
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshSetSurfaceTreeChangedCallback(
    OwlFreshSurfaceTreeChangedCallback callback);
ACCELERATED_WIDGET_MAC_EXPORT std::vector<OwlFreshSurfaceSnapshot>
OwlFreshSurfaceTreeSnapshot();
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshDisplayPortalPresentCAContext(
    uint32_t ca_context_id,
    CGRect frame);
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshDisplayPortalPresentCAContextForSurface(
    uint64_t surface_key,
    uint64_t parent_surface_key,
    OwlFreshSurfaceKind kind,
    uint32_t ca_context_id,
    CGRect bounds,
    float scale,
    bool visible,
    const std::string& label);
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshPublishNativeMenuSurface(
    uint64_t surface_key,
    uint64_t parent_surface_key,
    CGRect bounds,
    float scale,
    const std::vector<std::string>& items,
    const std::vector<OwlFreshNativeMenuItem>& native_items,
    int32_t selected_index,
    float item_font_size,
    bool right_aligned,
    const std::string& label);
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshPublishNativeFilePickerSurface(
    uint64_t surface_key,
    uint64_t parent_surface_key,
    CGRect bounds,
    float scale,
    const std::string& mode,
    const std::vector<std::string>& accept_types,
    bool allows_multiple,
    bool upload_folder,
    const std::string& label);
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshMarkSurfaceHidden(
    uint64_t surface_key);
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshClearNativeMenuSurfaces();
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshClearNativeFilePickerSurfaces();
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshDisplayPortalPresentIOSurface(
    IOSurfaceRef io_surface,
    const gfx::Size& dip_size,
    float scale_factor);
#if defined(__OBJC__)
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshDisplayPortalPresentLayer(
    CALayer* layer,
    CGRect frame);
ACCELERATED_WIDGET_MAC_EXPORT void OwlFreshDisplayPortalResize(CGRect frame);
#endif

}  // namespace ui

#endif
