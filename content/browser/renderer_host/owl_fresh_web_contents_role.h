// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_BROWSER_RENDERER_HOST_OWL_FRESH_WEB_CONTENTS_ROLE_H_
#define CONTENT_BROWSER_RENDERER_HOST_OWL_FRESH_WEB_CONTENTS_ROLE_H_

#include <memory>

#include "base/supports_user_data.h"
#include "content/public/browser/web_contents.h"

namespace content::owl_fresh {

namespace internal {

inline const void* DevToolsFrontendRoleKey() {
  static int key = 0;
  return &key;
}

class DevToolsFrontendRole final : public base::SupportsUserData::Data {};

}  // namespace internal

inline void MarkDevToolsFrontend(WebContents* web_contents) {
  if (!web_contents ||
      web_contents->GetUserData(internal::DevToolsFrontendRoleKey())) {
    return;
  }
  web_contents->SetUserData(
      internal::DevToolsFrontendRoleKey(),
      std::make_unique<internal::DevToolsFrontendRole>());
}

inline bool IsDevToolsFrontend(const WebContents* web_contents) {
  return web_contents &&
         web_contents->GetUserData(internal::DevToolsFrontendRoleKey());
}

}  // namespace content::owl_fresh

#endif  // CONTENT_BROWSER_RENDERER_HOST_OWL_FRESH_WEB_CONTENTS_ROLE_H_
