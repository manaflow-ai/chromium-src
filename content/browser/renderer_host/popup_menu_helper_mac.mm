// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/browser/renderer_host/popup_menu_helper_mac.h"

#include <algorithm>
#include <cmath>

#include "base/command_line.h"
#include "base/numerics/safe_conversions.h"
#import "content/app_shim_remote_cocoa/render_widget_host_view_cocoa.h"
#include "content/browser/permissions/permission_controller_impl.h"
#include "content/browser/renderer_host/frame_tree.h"
#include "content/browser/renderer_host/frame_tree_node.h"
#include "content/browser/renderer_host/render_frame_host_impl.h"
#include "content/browser/renderer_host/render_view_host_impl.h"
#include "content/browser/renderer_host/render_widget_host_view_mac.h"
#include "content/common/content_export.h"
#include "content/public/browser/web_contents.h"
#import "ui/base/cocoa/base_view.h"
#include "ui/accelerated_widget_mac/owl_fresh_context.h"

namespace content {

namespace {

bool g_allow_showing_popup_menus = true;
PopupMenuHelper* g_owl_fresh_active_popup_menu = nullptr;

std::vector<std::string> MenuLabels(
    const std::vector<blink::mojom::MenuItemPtr>& items) {
  std::vector<std::string> labels;
  labels.reserve(items.size());
  for (const auto& item : items) {
    if (!item || item->type == blink::mojom::MenuItem::Type::kSeparator) {
      labels.push_back("---");
      continue;
    }
    labels.push_back(item->label.value_or(std::string()));
  }
  return labels;
}

std::vector<ui::OwlFreshNativeMenuItem> NativeMenuItems(
    const std::vector<blink::mojom::MenuItemPtr>& items) {
  std::vector<ui::OwlFreshNativeMenuItem> native_items;
  native_items.reserve(items.size());
  for (const auto& item : items) {
    ui::OwlFreshNativeMenuItem native_item;
    if (!item) {
      native_item.label = "";
      native_item.enabled = false;
      native_items.push_back(std::move(native_item));
      continue;
    }
    native_item.separator =
        item->type == blink::mojom::MenuItem::Type::kSeparator;
    native_item.group = item->type == blink::mojom::MenuItem::Type::kGroup;
    native_item.label = native_item.separator ? "---"
                                             : item->label.value_or(std::string());
    native_item.tool_tip = item->tool_tip.value_or(std::string());
    native_item.enabled = item->enabled;
    native_item.text_direction = static_cast<uint32_t>(item->text_direction);
    native_item.has_text_direction_override = item->has_text_direction_override;
    native_items.push_back(std::move(native_item));
  }
  return native_items;
}

}  // namespace

PopupMenuHelper::PopupMenuHelper(
    Delegate* delegate,
    RenderFrameHost* render_frame_host,
    mojo::PendingRemote<blink::mojom::PopupMenuClient> popup_client)
    : delegate_(delegate),
      render_frame_host_(
          static_cast<RenderFrameHostImpl*>(render_frame_host)->GetWeakPtr()),
      popup_client_(std::move(popup_client)) {
  RenderWidgetHost* widget_host =
      render_frame_host->GetRenderViewHost()->GetWidget();
  observation_.Observe(widget_host);

  popup_client_.set_disconnect_handler(
      base::BindOnce(&PopupMenuHelper::Hide, weak_ptr_factory_.GetWeakPtr()));
}

PopupMenuHelper::~PopupMenuHelper() {
  if (g_owl_fresh_active_popup_menu == this) {
    g_owl_fresh_active_popup_menu = nullptr;
  }
  Hide();
}

void PopupMenuHelper::ShowPopupMenu(
    const gfx::Rect& bounds,
    double item_font_size,
    int selected_item,
    std::vector<blink::mojom::MenuItemPtr> items,
    bool right_aligned,
    bool allow_multiple_selection) {
  // Only single selection list boxes show a popup on Mac.
  DCHECK(!allow_multiple_selection);
  if (!g_allow_showing_popup_menus)
    return;

  RenderWidgetHostViewMac* rwhvm = GetRenderWidgetHostView();
  auto* web_contents = rwhvm->GetWebContents();

  // Convert element_bounds to be in screen.
  gfx::Rect client_area = web_contents->GetContainerBounds();
  gfx::Rect bounds_in_screen = bounds + client_area.OffsetFromOrigin();

  // The new popup menu would overlap the permission prompt, which could lead to
  // users making decisions based on incorrect information. We should close the
  // popup if it intersects with the permission prompt.
  auto permission_exclusion_area_bounds =
      PermissionControllerImpl::FromBrowserContext(
          web_contents->GetBrowserContext())
          ->GetExclusionAreaBoundsInScreen(web_contents);
  if (permission_exclusion_area_bounds &&
      permission_exclusion_area_bounds->Intersects(bounds_in_screen)) {
    popup_client_->DidCancel();
    delegate_->OnMenuClosed();  // May delete |this|.
    return;
  }

  if (base::CommandLine::ForCurrentProcess()->HasSwitch("fresh-owl-embed")) {
    g_owl_fresh_active_popup_menu = this;
    ui::OwlFreshPublishNativeMenuSurface(
        reinterpret_cast<uint64_t>(this),
        reinterpret_cast<uint64_t>(rwhvm),
        CGRectMake(bounds.x(), bounds.y(), bounds.width(), bounds.height()),
        rwhvm->GetCurrentScreenInfo().device_scale_factor, MenuLabels(items),
        NativeMenuItems(items), selected_item, static_cast<float>(item_font_size),
        right_aligned, "select-menu");
    return;
  }

  remote_runner_.reset();
  rwhvm->GetNSView()->DisplayPopupMenu(
      remote_cocoa::mojom::PopupMenu::New(
          std::move(items), bounds, item_font_size, right_aligned,
          selected_item, remote_runner_.BindNewPipeAndPassReceiver()),
      base::BindOnce(&PopupMenuHelper::PopupMenuClosed,
                     weak_ptr_factory_.GetWeakPtr()));
}

void PopupMenuHelper::Hide() {
  if (g_owl_fresh_active_popup_menu == this) {
    g_owl_fresh_active_popup_menu = nullptr;
    ui::OwlFreshClearNativeMenuSurfaces();
  }
  if (remote_runner_) {
    remote_runner_->Hide();
  }
  popup_was_hidden_ = true;
  popup_client_.reset();
}

void PopupMenuHelper::OwlFreshAcceptItem(uint32_t selected_item) {
  if (g_owl_fresh_active_popup_menu == this) {
    g_owl_fresh_active_popup_menu = nullptr;
  }
  ui::OwlFreshClearNativeMenuSurfaces();
  PopupMenuClosed(selected_item);
}

void PopupMenuHelper::OwlFreshCancel() {
  if (g_owl_fresh_active_popup_menu == this) {
    g_owl_fresh_active_popup_menu = nullptr;
  }
  ui::OwlFreshClearNativeMenuSurfaces();
  PopupMenuClosed(std::nullopt);
}

RenderWidgetHostViewMac* PopupMenuHelper::GetRenderWidgetHostView() const {
  return static_cast<RenderWidgetHostViewMac*>(
      render_frame_host_->GetOutermostMainFrameOrEmbedder()->GetView());
}

void PopupMenuHelper::RenderWidgetHostVisibilityChanged(
    RenderWidgetHost* widget_host,
    bool became_visible) {
  if (!became_visible)
    Hide();
}

void PopupMenuHelper::RenderWidgetHostDestroyed(RenderWidgetHost* widget_host) {
  DCHECK(observation_.IsObservingSource(widget_host));
  observation_.Reset();
}

void PopupMenuHelper::PopupMenuClosed(std::optional<uint32_t> selected_item) {
  // The RenderFrameHost may be deleted while running the menu, or it may have
  // requested the close. Don't notify in these cases.
  if (popup_client_ && !popup_was_hidden_) {
    if (selected_item.has_value()) {
      popup_client_->DidAcceptIndices(
          {base::saturated_cast<int32_t>(*selected_item)});
    } else {
      popup_client_->DidCancel();
    }
  }

  delegate_->OnMenuClosed();  // May delete |this|.
}

bool OwlFreshAcceptActivePopupMenuItem(uint32_t selected_item) {
  if (!g_owl_fresh_active_popup_menu) {
    return false;
  }
  g_owl_fresh_active_popup_menu->OwlFreshAcceptItem(selected_item);
  return true;
}

bool OwlFreshCancelActivePopupMenu() {
  if (!g_owl_fresh_active_popup_menu) {
    ui::OwlFreshClearNativeMenuSurfaces();
    return false;
  }
  g_owl_fresh_active_popup_menu->OwlFreshCancel();
  return true;
}

// As declared in //content/public/browser/popup_menu.h.
CONTENT_EXPORT void DontShowPopupMenus() {
  g_allow_showing_popup_menus = false;
}

}  // namespace content
