#include "ui/accelerated_widget_mac/owl_fresh_context.h"

#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <atomic>
#include <map>
#include <string>
#include <utility>

#include "base/no_destructor.h"
#include "ui/base/cocoa/remote_layer_api.h"
#include "ui/gfx/geometry/size.h"

namespace ui {
namespace {

struct OwlFreshDisplayPortal {
  CAContext* __strong context = nil;
  CALayer* __strong root_layer = nil;
  CALayerHost* __strong host_layer = nil;
  CALayer* __strong image_layer = nil;
  CIContext* __strong image_context = nil;
};

struct OwlFreshSurfaceRecord {
  uint64_t stable_id = 0;
  uint64_t surface_key = 0;
  uint64_t parent_surface_key = 0;
  OwlFreshSurfaceKind kind = OwlFreshSurfaceKind::kWebView;
  uint32_t context_id = 0;
  CAContext* __strong context = nil;
  CALayer* __strong root_layer = nil;
  CALayerHost* __strong host_layer = nil;
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

struct OwlFreshDevToolsDockLayout {
  bool active = false;
  std::string label;
  CGRect web_bounds = CGRectZero;
  CGRect devtools_bounds = CGRectZero;
};

std::atomic<uint32_t> g_legacy_context_id{0};
std::atomic<uint32_t> g_portal_context_id{0};
std::atomic<uint64_t> g_portal_generation{0};

std::string& DevToolsSurfaceLabelStorage() {
  static base::NoDestructor<std::string> label("devtools-bottom");
  return *label;
}

OwlFreshDevToolsDockLayout& DevToolsDockLayoutStorage() {
  static base::NoDestructor<OwlFreshDevToolsDockLayout> layout;
  return *layout;
}

OwlFreshDisplayPortal& Portal() {
  static base::NoDestructor<OwlFreshDisplayPortal> portal;
  return *portal;
}

std::map<uint64_t, OwlFreshSurfaceRecord>& SurfaceRecords() {
  static base::NoDestructor<std::map<uint64_t, OwlFreshSurfaceRecord>> records;
  return *records;
}

uint64_t& NextSurfaceID() {
  static uint64_t next_id = 1;
  return next_id;
}

CGRect NormalizedFrame(CGRect frame) {
  if (CGRectIsEmpty(frame) || frame.size.width <= 0 || frame.size.height <= 0) {
    return CGRectMake(0, 0, 1, 1);
  }
  return CGRectMake(frame.origin.x, frame.origin.y, frame.size.width,
                    frame.size.height);
}

CGRect ZeroOriginFrame(CGRect frame) {
  if (CGRectIsEmpty(frame) || frame.size.width <= 0 || frame.size.height <= 0) {
    return CGRectMake(0, 0, 1, 1);
  }
  return CGRectMake(0, 0, frame.size.width, frame.size.height);
}

void SizeLayer(CALayer* layer, CGRect frame) {
  layer.anchorPoint = CGPointZero;
  layer.frame = ZeroOriginFrame(frame);
  layer.bounds = ZeroOriginFrame(frame);
  layer.position = CGPointZero;
}

void EnsurePortalContext() {
  OwlFreshDisplayPortal& portal = Portal();

  if (!portal.context) {
    CGSConnectionID connection = CGSMainConnectionID();
    portal.context = [CAContext contextWithCGSConnection:connection
                                                 options:@{}];
    g_portal_context_id.store(portal.context.contextId,
                              std::memory_order_relaxed);
  }
}

void EnsureSurfacePortal(OwlFreshSurfaceRecord& record) {
  if (!record.context) {
    CGSConnectionID connection = CGSMainConnectionID();
    record.context = [CAContext contextWithCGSConnection:connection
                                                 options:@{}];
    record.root_layer = [[CALayer alloc] init];
    record.root_layer.geometryFlipped = YES;
    record.host_layer = [[CALayerHost alloc] init];
    record.host_layer.autoresizingMask =
        kCALayerWidthSizable | kCALayerHeightSizable;
    [record.host_layer setValue:@YES forKey:@"inheritsSecurity"];
    [record.root_layer addSublayer:record.host_layer];
    record.context.layer = record.root_layer;
  }
}

void EnsurePortal(CGRect frame) {
  OwlFreshDisplayPortal& portal = Portal();
  frame = ZeroOriginFrame(frame);

  EnsurePortalContext();

  if (!portal.root_layer) {
    portal.root_layer = [[CALayer alloc] init];
    portal.root_layer.geometryFlipped = YES;

    portal.host_layer = [[CALayerHost alloc] init];
    portal.host_layer.autoresizingMask =
        kCALayerWidthSizable | kCALayerHeightSizable;
    [portal.host_layer setValue:@YES forKey:@"inheritsSecurity"];

    portal.image_layer = [[CALayer alloc] init];
    portal.image_layer.contentsGravity = kCAGravityTopLeft;
    portal.image_layer.geometryFlipped = YES;

    portal.image_context = [CIContext contextWithOptions:nil];
  }

  SizeLayer(portal.root_layer, frame);
  SizeLayer(portal.host_layer, frame);
  SizeLayer(portal.image_layer, frame);
  portal.context.layer = portal.root_layer;
}

OwlFreshSurfaceRecord& EnsureSurfaceRecord(uint64_t surface_key) {
  std::map<uint64_t, OwlFreshSurfaceRecord>& records = SurfaceRecords();
  auto [it, inserted] = records.try_emplace(surface_key);
  OwlFreshSurfaceRecord& record = it->second;
  if (inserted) {
    record.surface_key = surface_key;
    record.stable_id = NextSurfaceID()++;
  }
  return record;
}

uint64_t StableIDForKey(uint64_t surface_key) {
  if (surface_key == 0) {
    return 0;
  }
  auto it = SurfaceRecords().find(surface_key);
  return it == SurfaceRecords().end() ? 0 : it->second.stable_id;
}

}  // namespace

OwlFreshNativeMenuItem::OwlFreshNativeMenuItem() = default;
OwlFreshNativeMenuItem::OwlFreshNativeMenuItem(const OwlFreshNativeMenuItem&) =
    default;
OwlFreshNativeMenuItem& OwlFreshNativeMenuItem::operator=(
    const OwlFreshNativeMenuItem&) = default;
OwlFreshNativeMenuItem::~OwlFreshNativeMenuItem() = default;

OwlFreshSurfaceSnapshot::OwlFreshSurfaceSnapshot() = default;
OwlFreshSurfaceSnapshot::OwlFreshSurfaceSnapshot(
    const OwlFreshSurfaceSnapshot&) = default;
OwlFreshSurfaceSnapshot& OwlFreshSurfaceSnapshot::operator=(
    const OwlFreshSurfaceSnapshot&) = default;
OwlFreshSurfaceSnapshot::~OwlFreshSurfaceSnapshot() = default;

void OwlFreshSetLatestContextID(uint32_t id) {
  g_legacy_context_id.store(id, std::memory_order_relaxed);
}

uint32_t OwlFreshLatestContextID() {
  const OwlFreshSurfaceRecord* latest_web_view = nullptr;
  for (const auto& [key, record] : SurfaceRecords()) {
    if (record.visible && record.kind == OwlFreshSurfaceKind::kWebView &&
        record.context_id != 0 &&
        (!latest_web_view || record.stable_id > latest_web_view->stable_id)) {
      latest_web_view = &record;
    }
  }
  if (latest_web_view) {
    return latest_web_view->context_id;
  }
  uint32_t portal_context_id =
      g_portal_context_id.load(std::memory_order_relaxed);
  if (portal_context_id != 0) {
    return portal_context_id;
  }
  return g_legacy_context_id.load(std::memory_order_relaxed);
}

uint64_t OwlFreshDisplayPortalGeneration() {
  return g_portal_generation.load(std::memory_order_relaxed);
}

void OwlFreshSetDevToolsSurfaceLabel(const std::string& label) {
  DevToolsSurfaceLabelStorage() = label.empty() ? "devtools-bottom" : label;
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

std::string OwlFreshDevToolsSurfaceLabel() {
  return DevToolsSurfaceLabelStorage();
}

void OwlFreshSetDevToolsDockLayout(const std::string& label,
                                   CGRect web_bounds,
                                   CGRect devtools_bounds) {
  OwlFreshDevToolsDockLayout& layout = DevToolsDockLayoutStorage();
  layout.active = true;
  layout.label = label;
  layout.web_bounds = NormalizedFrame(web_bounds);
  layout.devtools_bounds = NormalizedFrame(devtools_bounds);
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

void OwlFreshClearDevToolsDockLayout() {
  OwlFreshDevToolsDockLayout& layout = DevToolsDockLayoutStorage();
  layout.active = false;
  layout.label.clear();
  layout.web_bounds = CGRectZero;
  layout.devtools_bounds = CGRectZero;
  for (auto& [key, record] : SurfaceRecords()) {
    if (record.kind == OwlFreshSurfaceKind::kDevTools) {
      record.visible = false;
    }
  }
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

std::vector<OwlFreshSurfaceSnapshot> OwlFreshSurfaceTreeSnapshot() {
  std::vector<OwlFreshSurfaceSnapshot> snapshots;
  const OwlFreshDevToolsDockLayout& layout = DevToolsDockLayoutStorage();
  uint64_t active_devtools_surface_key = 0;
  if (layout.active) {
    uint32_t active_context_id = 0;
    for (const auto& [key, record] : SurfaceRecords()) {
      if (record.visible && record.kind == OwlFreshSurfaceKind::kDevTools &&
          record.context_id >= active_context_id) {
        active_context_id = record.context_id;
        active_devtools_surface_key = key;
      }
    }
  }
  for (const auto& [key, record] : SurfaceRecords()) {
    if (!record.visible) {
      continue;
    }
    if (layout.active && record.kind == OwlFreshSurfaceKind::kDevTools &&
        key != active_devtools_surface_key) {
      continue;
    }
    OwlFreshSurfaceSnapshot snapshot;
    snapshot.surface_id = record.stable_id;
    snapshot.parent_surface_id = StableIDForKey(record.parent_surface_key);
    snapshot.kind = record.kind;
    snapshot.context_id = record.context_id;
    CGRect snapshot_bounds = record.bounds;
    if (layout.active && record.kind == OwlFreshSurfaceKind::kWebView) {
      snapshot_bounds = layout.web_bounds;
    } else if (layout.active && record.kind == OwlFreshSurfaceKind::kDevTools) {
      snapshot_bounds = layout.devtools_bounds;
    }
    snapshot.bounds = NormalizedFrame(snapshot_bounds);
    snapshot.scale = record.scale;
    snapshot.z_index = record.z_index;
    snapshot.visible = record.visible;
    snapshot.menu_items = record.menu_items;
    snapshot.native_menu_items = record.native_menu_items;
    snapshot.selected_index = record.selected_index;
    snapshot.item_font_size = record.item_font_size;
    snapshot.right_aligned = record.right_aligned;
    snapshot.file_picker_mode = record.file_picker_mode;
    snapshot.file_picker_accept_types = record.file_picker_accept_types;
    snapshot.file_picker_allows_multiple = record.file_picker_allows_multiple;
    snapshot.file_picker_upload_folder = record.file_picker_upload_folder;
    snapshot.label =
        layout.active && record.kind == OwlFreshSurfaceKind::kDevTools
            ? layout.label
            : record.label;
    snapshots.push_back(std::move(snapshot));
  }
  std::stable_sort(snapshots.begin(), snapshots.end(),
                   [](const OwlFreshSurfaceSnapshot& lhs,
                      const OwlFreshSurfaceSnapshot& rhs) {
                     if (lhs.z_index != rhs.z_index) {
                       return lhs.z_index < rhs.z_index;
                     }
                     return lhs.surface_id < rhs.surface_id;
                   });
  return snapshots;
}

void OwlFreshDisplayPortalPresentCAContext(uint32_t ca_context_id,
                                           CGRect frame) {
  if (ca_context_id == 0) {
    return;
  }
  g_legacy_context_id.store(ca_context_id, std::memory_order_relaxed);

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  EnsurePortal(frame);

  OwlFreshDisplayPortal& portal = Portal();
  [portal.image_layer removeFromSuperlayer];
  if (!portal.host_layer.superlayer) {
    [portal.root_layer addSublayer:portal.host_layer];
  }
  portal.host_layer.contextId = ca_context_id;

  [CATransaction commit];
  [CATransaction flush];
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

void HidePreviousRootSurfaceRecords(OwlFreshSurfaceKind kind,
                                    const std::string& label,
                                    uint64_t active_surface_key) {
  if (kind != OwlFreshSurfaceKind::kWebView &&
      kind != OwlFreshSurfaceKind::kDevTools) {
    return;
  }
  for (auto& [key, record] : SurfaceRecords()) {
    if (key != active_surface_key && record.visible &&
        record.parent_surface_key == 0 && record.kind == kind &&
        record.label == label) {
      record.visible = false;
    }
  }
}

void OwlFreshDisplayPortalPresentCAContextForSurface(
    uint64_t surface_key,
    uint64_t parent_surface_key,
    OwlFreshSurfaceKind kind,
    uint32_t ca_context_id,
    CGRect bounds,
    float scale,
    bool visible,
    const std::string& label) {
  if (surface_key == 0 || ca_context_id == 0) {
    return;
  }

  HidePreviousRootSurfaceRecords(kind, label, surface_key);

  OwlFreshSurfaceRecord& record = EnsureSurfaceRecord(surface_key);
  record.parent_surface_key = parent_surface_key;
  record.kind = kind;
  record.bounds = NormalizedFrame(bounds);
  record.scale = scale <= 0 ? 1.0f : scale;
  if (kind == OwlFreshSurfaceKind::kPopupWidget) {
    record.z_index = 100;
  } else if (kind == OwlFreshSurfaceKind::kDevTools) {
    record.z_index = -10;
  } else {
    record.z_index = 0;
  }
  record.visible = visible;
  record.menu_items.clear();
  record.native_menu_items.clear();
  record.selected_index = -1;
  record.item_font_size = 0.0f;
  record.right_aligned = false;
  record.file_picker_mode.clear();
  record.file_picker_accept_types.clear();
  record.file_picker_allows_multiple = false;
  record.file_picker_upload_folder = false;
  record.label = label;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  EnsureSurfacePortal(record);
  SizeLayer(record.root_layer, record.bounds);
  SizeLayer(record.host_layer, record.bounds);
  record.host_layer.contextId = ca_context_id;
  record.context.layer = record.root_layer;
  record.context_id = record.context.contextId;
  [CATransaction commit];
  [CATransaction flush];

  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

void OwlFreshPublishNativeMenuSurface(
    uint64_t surface_key,
    uint64_t parent_surface_key,
    CGRect bounds,
    float scale,
    const std::vector<std::string>& items,
    const std::vector<OwlFreshNativeMenuItem>& native_items,
    int32_t selected_index,
    float item_font_size,
    bool right_aligned,
    const std::string& label) {
  if (surface_key == 0 || items.empty()) {
    return;
  }
  OwlFreshSurfaceRecord& record = EnsureSurfaceRecord(surface_key);
  record.parent_surface_key = parent_surface_key;
  record.kind = OwlFreshSurfaceKind::kNativeMenu;
  record.context_id = 0;
  record.context = nil;
  record.root_layer = nil;
  record.host_layer = nil;
  record.bounds = NormalizedFrame(bounds);
  record.scale = scale <= 0 ? 1.0f : scale;
  record.z_index = 200;
  record.visible = true;
  record.menu_items = items;
  record.native_menu_items = native_items;
  record.selected_index = selected_index;
  record.item_font_size = item_font_size;
  record.right_aligned = right_aligned;
  record.file_picker_mode.clear();
  record.file_picker_accept_types.clear();
  record.file_picker_allows_multiple = false;
  record.file_picker_upload_folder = false;
  record.label = label;
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

void OwlFreshPublishNativeFilePickerSurface(
    uint64_t surface_key,
    uint64_t parent_surface_key,
    CGRect bounds,
    float scale,
    const std::string& mode,
    const std::vector<std::string>& accept_types,
    bool allows_multiple,
    bool upload_folder,
    const std::string& label) {
  if (surface_key == 0) {
    return;
  }
  OwlFreshSurfaceRecord& record = EnsureSurfaceRecord(surface_key);
  record.parent_surface_key = parent_surface_key;
  record.kind = OwlFreshSurfaceKind::kNativeFilePicker;
  record.context_id = 0;
  record.context = nil;
  record.root_layer = nil;
  record.host_layer = nil;
  record.bounds = NormalizedFrame(bounds);
  record.scale = scale <= 0 ? 1.0f : scale;
  record.z_index = 250;
  record.visible = true;
  record.menu_items.clear();
  record.native_menu_items.clear();
  record.selected_index = -1;
  record.item_font_size = 0.0f;
  record.right_aligned = false;
  record.file_picker_mode = mode;
  record.file_picker_accept_types = accept_types;
  record.file_picker_allows_multiple = allows_multiple;
  record.file_picker_upload_folder = upload_folder;
  record.label = label;
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

void OwlFreshMarkSurfaceHidden(uint64_t surface_key) {
  auto it = SurfaceRecords().find(surface_key);
  if (it == SurfaceRecords().end()) {
    return;
  }
  it->second.visible = false;
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

void OwlFreshClearNativeMenuSurfaces() {
  bool changed = false;
  for (auto& [key, record] : SurfaceRecords()) {
    if (record.kind == OwlFreshSurfaceKind::kNativeMenu && record.visible) {
      record.visible = false;
      changed = true;
    }
  }
  if (changed) {
    g_portal_generation.fetch_add(1, std::memory_order_relaxed);
  }
}

void OwlFreshClearNativeFilePickerSurfaces() {
  bool changed = false;
  for (auto& [key, record] : SurfaceRecords()) {
    if (record.kind == OwlFreshSurfaceKind::kNativeFilePicker &&
        record.visible) {
      record.visible = false;
      changed = true;
    }
  }
  if (changed) {
    g_portal_generation.fetch_add(1, std::memory_order_relaxed);
  }
}

void OwlFreshDisplayPortalPresentIOSurface(IOSurfaceRef io_surface,
                                           const gfx::Size& dip_size,
                                           float scale_factor) {
  if (!io_surface) {
    return;
  }

  CGRect frame = CGRectMake(0, 0, dip_size.width(), dip_size.height());
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  EnsurePortal(frame);

  OwlFreshDisplayPortal& portal = Portal();
  [portal.host_layer removeFromSuperlayer];
  if (!portal.image_layer.superlayer) {
    [portal.root_layer addSublayer:portal.image_layer];
  }

  CIImage* ci_image = [CIImage imageWithIOSurface:io_surface];
  CGRect image_rect = CGRectMake(0, 0, IOSurfaceGetWidth(io_surface),
                                 IOSurfaceGetHeight(io_surface));
  CGImageRef image = [portal.image_context createCGImage:ci_image
                                                fromRect:image_rect];
  if (image) {
    portal.image_layer.contents = (__bridge id)image;
    CGImageRelease(image);
  }

  portal.image_layer.contentsScale = scale_factor;

  [CATransaction commit];
  [CATransaction flush];
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

void OwlFreshDisplayPortalResize(CGRect frame) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  EnsurePortal(frame);
  OwlFreshDisplayPortal& portal = Portal();
  uint32_t legacy_context_id =
      g_legacy_context_id.load(std::memory_order_relaxed);
  if (legacy_context_id != 0) {
    if (!portal.host_layer.superlayer) {
      [portal.root_layer addSublayer:portal.host_layer];
    }
    portal.host_layer.contextId = legacy_context_id;
  }
  [CATransaction commit];
  [CATransaction flush];
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

void OwlFreshDisplayPortalPresentLayer(CALayer* layer, CGRect frame) {
  if (!layer) {
    return;
  }

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  EnsurePortalContext();
  frame = NormalizedFrame(frame);
  SizeLayer(layer, frame);

  OwlFreshDisplayPortal& portal = Portal();
  portal.context.layer = layer;

  [CATransaction commit];
  [CATransaction flush];
  g_portal_generation.fetch_add(1, std::memory_order_relaxed);
}

}  // namespace ui
