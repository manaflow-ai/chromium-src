// Copyright 2013 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_devtools_frontend.h"

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/stringprintf.h"
#include "base/task/single_thread_task_runner.h"
#include "base/strings/utf_string_conversions.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_devtools_bindings.h"
#include "content/shell/browser/shell_devtools_manager_delegate.h"

#if !BUILDFLAG(IS_ANDROID) && !BUILDFLAG(IS_IOS)
#include "base/command_line.h"
#include "content/shell/common/shell_switches.h"
#endif

namespace content {

namespace {
static GURL GetFrontendURL() {
  int port = ShellDevToolsManagerDelegate::GetHttpHandlerPort();
#if BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_IOS)
  const char* query_string = "";
#else
  const char* query_string = "?targetType=tab&can_dock=true";
#endif

  return GURL(base::StringPrintf(
      "http://127.0.0.1:%d/devtools/devtools_app.html%s", port, query_string));
}
}  // namespace

// static
ShellDevToolsFrontend* ShellDevToolsFrontend::Show(
    WebContents* inspected_contents,
    std::string initial_dock_state,
    base::RepeatingClosure frontend_close_callback,
    base::RepeatingCallback<void(const std::string&)> dock_state_callback,
    base::RepeatingCallback<void(const gfx::Rect&)>
        inspected_page_bounds_callback) {
  Shell* shell = Shell::CreateNewWindow(inspected_contents->GetBrowserContext(),
                                        GURL(), nullptr, gfx::Size());
  ShellDevToolsFrontend* devtools_frontend =
      new ShellDevToolsFrontend(shell, inspected_contents,
                                std::move(initial_dock_state),
                                std::move(frontend_close_callback),
                                std::move(dock_state_callback),
                                std::move(inspected_page_bounds_callback));
  shell->LoadURL(GetFrontendURL());
  return devtools_frontend;
}

void ShellDevToolsFrontend::Activate() {
  frontend_shell_->ActivateContents(frontend_shell_->web_contents());
}

void ShellDevToolsFrontend::InspectElementAt(int x, int y) {
  devtools_bindings_->InspectElementAt(x, y);
}

void ShellDevToolsFrontend::Close() {
  devtools_bindings_->Detach();
  frontend_shell_->Close();
}

void ShellDevToolsFrontend::RequestCloseFromFrontend() {
  if (frontend_close_callback_) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::RepeatingClosure callback) { callback.Run(); },
                       frontend_close_callback_));
    return;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&ShellDevToolsFrontend::Close,
                                weak_ptr_factory_.GetWeakPtr()));
}

void ShellDevToolsFrontend::DevToolsDockStateChanged(
    const std::string& dock_state) {
  if (dock_state_callback_) {
    dock_state_callback_.Run(dock_state);
  }
}

void ShellDevToolsFrontend::SetInspectedPageBounds(const gfx::Rect& bounds) {
  if (inspected_page_bounds_callback_) {
    inspected_page_bounds_callback_.Run(bounds);
  }
}

void ShellDevToolsFrontend::PrimaryMainDocumentElementAvailable() {
  devtools_bindings_->Attach();
}

void ShellDevToolsFrontend::WebContentsDestroyed() {
  delete this;
}

ShellDevToolsFrontend::ShellDevToolsFrontend(
    Shell* frontend_shell,
    WebContents* inspected_contents,
    std::string initial_dock_state,
    base::RepeatingClosure frontend_close_callback,
    base::RepeatingCallback<void(const std::string&)> dock_state_callback,
    base::RepeatingCallback<void(const gfx::Rect&)>
        inspected_page_bounds_callback)
    : WebContentsObserver(frontend_shell->web_contents()),
      frontend_shell_(frontend_shell),
      devtools_bindings_(
          new ShellDevToolsBindings(frontend_shell->web_contents(),
                                    inspected_contents,
                                    this,
                                    std::move(initial_dock_state))),
      frontend_close_callback_(std::move(frontend_close_callback)),
      dock_state_callback_(std::move(dock_state_callback)),
      inspected_page_bounds_callback_(
          std::move(inspected_page_bounds_callback)) {}

ShellDevToolsFrontend::~ShellDevToolsFrontend() {}

base::WeakPtr<ShellDevToolsFrontend> ShellDevToolsFrontend::GetWeakPtr() {
  return weak_ptr_factory_.GetWeakPtr();
}

}  // namespace content
