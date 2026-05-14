#include "fresh_owl/owl_fresh_mojo_runtime.h"

#include <cstdlib>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

#include "base/apple/foundation_util.h"
#include "base/at_exit.h"
#include "base/base64.h"
#include "base/command_line.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/process/launch.h"
#include "base/process/process.h"
#include "base/run_loop.h"
#include "base/strings/strcat.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_executor.h"
#include "base/task/thread_pool/thread_pool_instance.h"
#include "base/threading/thread.h"
#include "base/values.h"
#include "content/shell/common/shell_controller.test-mojom.h"
#include "mojo/core/embedder/configuration.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/core/embedder/scoped_ipc_support.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/platform/platform_channel.h"
#include "mojo/public/cpp/system/invitation.h"

namespace {

struct GlobalState {
  base::AtExitManager at_exit;
  std::unique_ptr<base::SingleThreadTaskExecutor> main_executor;
  std::unique_ptr<base::Thread> ipc_thread;
  std::unique_ptr<mojo::core::ScopedIPCSupport> ipc_support;
  bool initialized = false;
};

GlobalState& GetGlobal() {
  static base::NoDestructor<GlobalState> global;
  return *global;
}

char* DuplicateCString(const std::string& value) {
  char* copy = static_cast<char*>(std::malloc(value.size() + 1));
  if (!copy) {
    return nullptr;
  }
  auto [text, terminator] =
      UNSAFE_BUFFERS(base::span<char>(copy, value.size() + 1))
          .split_at(value.size());
  text.copy_from(base::span(std::string_view(value)));
  terminator.copy_from(base::span_from_ref('\0'));
  return copy;
}

void Emit(OwlFreshMojoEventCallback callback,
          void* user_data,
          const OwlFreshMojoEvent& event) {
  if (callback) {
    callback(&event, user_data);
  }
}

int Fail(char** error, std::string_view message) {
  if (error) {
    *error = DuplicateCString(std::string(message));
  }
  return 1;
}

int Succeed(char** result_json, std::string_view result) {
  if (result_json) {
    *result_json = DuplicateCString(std::string(result));
  }
  return 0;
}

bool WriteJSON(base::Value value, std::string* json) {
  return base::JSONWriter::Write(value, json);
}

int WriteDictResult(base::DictValue dict, char** result_json, char** error) {
  std::string json;
  if (!WriteJSON(base::Value(std::move(dict)), &json)) {
    return Fail(error, "JSONWriter failed");
  }
  return Succeed(result_json, json);
}

base::DictValue SurfaceTreeToDict(
    const content::mojom::OwlFreshSurfaceTreePtr& tree) {
  base::DictValue dict;
  dict.Set("generation", tree ? static_cast<int>(tree->generation) : 0);
  base::ListValue surfaces;
  if (tree) {
    for (const auto& surface : tree->surfaces) {
      base::DictValue surface_dict;
      surface_dict.Set("surfaceId", static_cast<int>(surface->surface_id));
      surface_dict.Set("parentSurfaceId",
                       static_cast<int>(surface->parent_surface_id));
      surface_dict.Set("kind", static_cast<int>(surface->kind));
      surface_dict.Set("contextId", static_cast<int>(surface->context_id));
      surface_dict.Set("x", surface->x);
      surface_dict.Set("y", surface->y);
      surface_dict.Set("width", static_cast<int>(surface->width));
      surface_dict.Set("height", static_cast<int>(surface->height));
      surface_dict.Set("scale", surface->scale);
      surface_dict.Set("zIndex", surface->z_index);
      surface_dict.Set("visible", surface->visible);
      base::ListValue menu_items;
      for (const std::string& item : surface->menu_items) {
        menu_items.Append(item);
      }
      surface_dict.Set("menuItems", std::move(menu_items));
      base::ListValue native_menu_items;
      for (const auto& item : surface->native_menu_items) {
        base::DictValue item_dict;
        item_dict.Set("label", item->label);
        item_dict.Set("toolTip", item->tool_tip);
        item_dict.Set("enabled", item->enabled);
        item_dict.Set("separator", item->separator);
        item_dict.Set("group", item->group);
        item_dict.Set("textDirection", static_cast<int>(item->text_direction));
        item_dict.Set("hasTextDirectionOverride",
                      item->has_text_direction_override);
        native_menu_items.Append(std::move(item_dict));
      }
      surface_dict.Set("nativeMenuItems", std::move(native_menu_items));
      surface_dict.Set("selectedIndex", surface->selected_index);
      surface_dict.Set("itemFontSize", surface->item_font_size);
      surface_dict.Set("rightAligned", surface->right_aligned);
      surface_dict.Set("filePickerMode", surface->file_picker_mode);
      base::ListValue file_picker_accept_types;
      for (const std::string& accept_type : surface->file_picker_accept_types) {
        file_picker_accept_types.Append(accept_type);
      }
      surface_dict.Set("filePickerAcceptTypes",
                       std::move(file_picker_accept_types));
      surface_dict.Set("filePickerAllowsMultiple",
                       surface->file_picker_allows_multiple);
      surface_dict.Set("filePickerUploadFolder",
                       surface->file_picker_upload_folder);
      surface_dict.Set("label", surface->label);
      surfaces.Append(std::move(surface_dict));
    }
  }
  dict.Set("surfaces", std::move(surfaces));
  return dict;
}

}  // namespace

struct OwlFreshMojoSession;

class OwlFreshMojoClientImpl final : public content::mojom::OwlFreshClient {
 public:
  explicit OwlFreshMojoClientImpl(OwlFreshMojoSession* session)
      : session_(session) {}
  ~OwlFreshMojoClientImpl() override = default;

  void OnReady(int32_t host_pid,
               content::mojom::OwlFreshCompositorInfoPtr compositor) override;
  void OnCompositorChanged(
      content::mojom::OwlFreshCompositorInfoPtr compositor) override;
  void OnSurfaceTreeChanged(
      content::mojom::OwlFreshSurfaceTreePtr surface_tree) override;
  void OnNavigationChanged(const std::string& url,
                           const std::string& title,
                           bool loading) override;
  void OnHostLog(const std::string& message) override;

 private:
  raw_ptr<OwlFreshMojoSession> session_;
};

struct OwlFreshMojoSession {
  base::Process process;
  mojo::Remote<content::mojom::ShellController> controller;
  mojo::Remote<content::mojom::OwlFreshSession> owl_session;
  mojo::Remote<content::mojom::OwlFreshProfile> profile;
  mojo::Remote<content::mojom::OwlFreshWebView> web_view;
  mojo::Remote<content::mojom::OwlFreshInput> input;
  mojo::Remote<content::mojom::OwlFreshSurfaceTreeHost> surface_tree;
  mojo::Remote<content::mojom::OwlFreshNativeSurfaceHost> native_surface_host;
  mojo::Remote<content::mojom::OwlFreshDevToolsHost> devtools_host;
  std::unique_ptr<OwlFreshMojoClientImpl> client_impl;
  std::unique_ptr<mojo::Receiver<content::mojom::OwlFreshClient>>
      client_receiver;
  OwlFreshMojoEventCallback callback = nullptr;
  raw_ptr<void> user_data = nullptr;
  uint64_t client_handle = 0;
  uint64_t profile_handle = 0;
  uint64_t web_view_handle = 0;
  uint64_t input_handle = 0;
  uint64_t surface_tree_handle = 0;
  uint64_t native_surface_host_handle = 0;
  uint64_t devtools_host_handle = 0;
};

int ValidateBindRequest(OwlFreshMojoSession* session,
                        uint64_t handle,
                        const char* interface_name,
                        uint64_t existing_handle,
                        char** error) {
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (handle == 0) {
    return Fail(error, base::StrCat({interface_name, " handle is zero"}));
  }
  if (!session->owl_session.is_bound()) {
    return Fail(error, "OwlFreshSession is not bound");
  }
  if (existing_handle != 0) {
    return Fail(error, base::StrCat({interface_name, " is already bound"}));
  }
  return 0;
}

void OwlFreshMojoClientImpl::OnReady(
    int32_t host_pid,
    content::mojom::OwlFreshCompositorInfoPtr compositor) {
  OwlFreshMojoEvent event = {};
  event.kind = kOwlFreshMojoEventReady;
  event.host_pid = host_pid;
  event.context_id = compositor ? compositor->context_id : 0;
  Emit(session_->callback, session_->user_data, event);
}

void OwlFreshMojoClientImpl::OnCompositorChanged(
    content::mojom::OwlFreshCompositorInfoPtr compositor) {
  OwlFreshMojoEvent event = {};
  event.kind = kOwlFreshMojoEventCompositor;
  event.context_id = compositor ? compositor->context_id : 0;
  Emit(session_->callback, session_->user_data, event);
}

void OwlFreshMojoClientImpl::OnSurfaceTreeChanged(
    content::mojom::OwlFreshSurfaceTreePtr surface_tree) {
  std::string json;
  WriteJSON(base::Value(SurfaceTreeToDict(surface_tree)), &json);
  OwlFreshMojoEvent event = {};
  event.kind = kOwlFreshMojoEventSurfaceTree;
  event.message = json.c_str();
  Emit(session_->callback, session_->user_data, event);
}

void OwlFreshMojoClientImpl::OnNavigationChanged(const std::string& url,
                                                 const std::string& title,
                                                 bool loading) {
  OwlFreshMojoEvent event = {};
  event.kind = kOwlFreshMojoEventNavigation;
  event.url = url.c_str();
  event.title = title.c_str();
  event.loading = loading;
  Emit(session_->callback, session_->user_data, event);
}

void OwlFreshMojoClientImpl::OnHostLog(const std::string& message) {
  OwlFreshMojoEvent event = {};
  event.kind = kOwlFreshMojoEventLog;
  event.message = message.c_str();
  Emit(session_->callback, session_->user_data, event);
}

extern "C" int owl_fresh_mojo_global_init(void) {
  GlobalState& global = GetGlobal();
  if (global.initialized) {
    return 0;
  }

  base::apple::SetBaseBundleIDOverride("org.chromium.ContentShell");

  const char* argv[] = {"owl_fresh_mojo_runtime"};
  base::CommandLine::Init(1, argv);
  logging::SetMinLogLevel(logging::LOGGING_INFO);

  base::ThreadPoolInstance::CreateAndStartWithDefaultParams(
      "owl_fresh_mojo_runtime");

  mojo::core::Configuration config;
  config.is_broker_process = true;
  config.max_message_num_bytes = 128 * 1024 * 1024;
  mojo::core::Init(config);

  global.ipc_thread = std::make_unique<base::Thread>("owl_fresh_mojo_ipc");
  base::Thread::Options options;
  options.message_pump_type = base::MessagePumpType::IO;
  if (!global.ipc_thread->StartWithOptions(std::move(options))) {
    return 1;
  }
  global.ipc_support = std::make_unique<mojo::core::ScopedIPCSupport>(
      global.ipc_thread->task_runner(),
      mojo::core::ScopedIPCSupport::ShutdownPolicy::CLEAN);
  global.main_executor = std::make_unique<base::SingleThreadTaskExecutor>();
  global.initialized = true;
  return 0;
}

extern "C" OwlFreshMojoSession* owl_fresh_mojo_session_create(
    const char* content_shell_path,
    const char* initial_url,
    const char* user_data_dir,
    OwlFreshMojoEventCallback callback,
    void* user_data) {
  if (!GetGlobal().initialized || !content_shell_path || !*content_shell_path) {
    return nullptr;
  }

  mojo::PlatformChannel channel;
  base::LaunchOptions launch_options;
  base::FilePath program_path(content_shell_path);
  base::CommandLine command_line(program_path);
  const bool visible_control_mode = std::getenv("OWL_FRESH_NO_EMBED") != nullptr;
  if (!visible_control_mode) {
    command_line.AppendSwitch("fresh-owl-embed");
    command_line.AppendSwitch("fresh-owl-hosted-frame-pump");
  } else {
    command_line.AppendSwitch("owl-fresh-visible-control");
  }
  if (std::getenv("OWL_FRESH_ENABLE_DEVTOOLS") != nullptr) {
    command_line.AppendSwitch("owl-fresh-enable-devtools");
  } else {
    command_line.AppendSwitch("owl-fresh-disable-devtools");
  }
  if (std::getenv("OWL_FRESH_WINDOW_SNAPSHOT") != nullptr) {
    command_line.AppendSwitch("owl-fresh-window-snapshot");
  }
  if (std::getenv("OWL_FRESH_LAYER_FIXTURE") != nullptr) {
    command_line.AppendSwitch("owl-fresh-layer-fixture-context");
  }
  command_line.AppendSwitch("content-shell-hide-toolbar");
  command_line.AppendSwitch("no-first-run");
  command_line.AppendSwitch("no-default-browser-check");
  if (std::getenv("OWL_FRESH_DISABLE_GPU") != nullptr) {
    command_line.AppendSwitch("disable-gpu");
  }
  if (std::getenv("OWL_FRESH_IN_PROCESS_GPU") != nullptr) {
    command_line.AppendSwitch("in-process-gpu");
  }
  if (const char* proxy_server = std::getenv("CMUX_CHROMIUM_PROXY_SERVER");
      proxy_server && *proxy_server) {
    command_line.AppendSwitchASCII("proxy-server", proxy_server);
  }
  command_line.AppendSwitchASCII("enable-logging", "stderr");
  command_line.AppendSwitchASCII("vmodule", "*owl*=1,*fresh*=1,*shell*=1");
  if (user_data_dir && *user_data_dir) {
    command_line.AppendSwitchASCII("user-data-dir", user_data_dir);
  }
  if (initial_url && *initial_url) {
    command_line.AppendArg(initial_url);
  }
  channel.PrepareToPassRemoteEndpoint(&launch_options, &command_line);

  base::Process process = base::LaunchProcess(command_line, launch_options);
  channel.RemoteProcessLaunchAttempted();
  if (!process.IsValid()) {
    return nullptr;
  }

  auto session = std::make_unique<OwlFreshMojoSession>();
  session->callback = callback;
  session->user_data = user_data;
  session->process = std::move(process);

  mojo::OutgoingInvitation invitation;
  session->controller = mojo::Remote<content::mojom::ShellController>(
      mojo::PendingRemote<content::mojom::ShellController>(
          invitation.AttachMessagePipe(0), 0));
  mojo::OutgoingInvitation::Send(std::move(invitation),
                                 session->process.Handle(),
                                 channel.TakeLocalEndpoint());

  session->controller->BindOwlFreshSession(
      session->owl_session.BindNewPipeAndPassReceiver());

  session->controller.set_disconnect_handler(base::BindRepeating(
      [](OwlFreshMojoSession* session) {
        OwlFreshMojoEvent event = {};
        event.kind = kOwlFreshMojoEventDisconnected;
        Emit(session->callback, session->user_data, event);
      },
      session.get()));
  session->owl_session.set_disconnect_handler(base::BindRepeating(
      [](OwlFreshMojoSession* session) {
        OwlFreshMojoEvent event = {};
        event.kind = kOwlFreshMojoEventDisconnected;
        Emit(session->callback, session->user_data, event);
      },
      session.get()));

  return session.release();
}

extern "C" void owl_fresh_mojo_session_destroy(
    OwlFreshMojoSession* session) {
  if (!session) {
    return;
  }
  if (session->controller.is_bound()) {
    session->controller->ShutDown();
  }
  session->devtools_host.reset();
  session->native_surface_host.reset();
  session->surface_tree.reset();
  session->input.reset();
  session->web_view.reset();
  session->profile.reset();
  session->owl_session.reset();
  session->controller.reset();
  base::RunLoop loop;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, loop.QuitClosure(), base::Milliseconds(100));
  loop.Run();
  session->process.WaitForExitWithTimeout(base::Seconds(2), nullptr);
  delete session;
}

extern "C" int32_t owl_fresh_mojo_session_host_pid(
    OwlFreshMojoSession* session) {
  return session && session->process.IsValid() ? session->process.Pid() : -1;
}

extern "C" int owl_fresh_mojo_session_set_client(
    OwlFreshMojoSession* session,
    uint64_t client_handle,
    char** error) {
  int validation_status = ValidateBindRequest(
      session, client_handle, "OwlFreshClient", session ? session->client_handle : 0,
      error);
  if (validation_status != 0) {
    return validation_status;
  }
  session->client_handle = client_handle;
  session->client_impl = std::make_unique<OwlFreshMojoClientImpl>(session);
  session->client_receiver =
      std::make_unique<mojo::Receiver<content::mojom::OwlFreshClient>>(
          session->client_impl.get());
  session->owl_session->SetClient(
      session->client_receiver->BindNewPipeAndPassRemote());
  return 0;
}

extern "C" int owl_fresh_mojo_session_bind_profile(
    OwlFreshMojoSession* session,
    uint64_t profile_handle,
    char** error) {
  int validation_status = ValidateBindRequest(
      session, profile_handle, "OwlFreshProfile",
      session ? session->profile_handle : 0, error);
  if (validation_status != 0) {
    return validation_status;
  }
  session->profile_handle = profile_handle;
  session->owl_session->BindProfile(
      session->profile.BindNewPipeAndPassReceiver());
  return 0;
}

extern "C" int owl_fresh_mojo_session_bind_web_view(
    OwlFreshMojoSession* session,
    uint64_t web_view_handle,
    char** error) {
  int validation_status = ValidateBindRequest(
      session, web_view_handle, "OwlFreshWebView",
      session ? session->web_view_handle : 0, error);
  if (validation_status != 0) {
    return validation_status;
  }
  session->web_view_handle = web_view_handle;
  session->owl_session->BindWebView(
      session->web_view.BindNewPipeAndPassReceiver());
  return 0;
}

extern "C" int owl_fresh_mojo_session_bind_input(
    OwlFreshMojoSession* session,
    uint64_t input_handle,
    char** error) {
  int validation_status = ValidateBindRequest(
      session, input_handle, "OwlFreshInput",
      session ? session->input_handle : 0, error);
  if (validation_status != 0) {
    return validation_status;
  }
  session->input_handle = input_handle;
  session->owl_session->BindInput(
      session->input.BindNewPipeAndPassReceiver());
  return 0;
}

extern "C" int owl_fresh_mojo_session_bind_surface_tree(
    OwlFreshMojoSession* session,
    uint64_t surface_tree_handle,
    char** error) {
  int validation_status = ValidateBindRequest(
      session, surface_tree_handle, "OwlFreshSurfaceTreeHost",
      session ? session->surface_tree_handle : 0, error);
  if (validation_status != 0) {
    return validation_status;
  }
  session->surface_tree_handle = surface_tree_handle;
  session->owl_session->BindSurfaceTree(
      session->surface_tree.BindNewPipeAndPassReceiver());
  return 0;
}

extern "C" int owl_fresh_mojo_session_bind_native_surface_host(
    OwlFreshMojoSession* session,
    uint64_t native_surface_host_handle,
    char** error) {
  int validation_status = ValidateBindRequest(
      session, native_surface_host_handle, "OwlFreshNativeSurfaceHost",
      session ? session->native_surface_host_handle : 0, error);
  if (validation_status != 0) {
    return validation_status;
  }
  session->native_surface_host_handle = native_surface_host_handle;
  session->owl_session->BindNativeSurfaceHost(
      session->native_surface_host.BindNewPipeAndPassReceiver());
  return 0;
}


extern "C" int owl_fresh_mojo_session_bind_devtools_host(
    OwlFreshMojoSession* session,
    uint64_t devtools_host_handle,
    char** error) {
  int validation_status = ValidateBindRequest(
      session, devtools_host_handle, "OwlFreshDevToolsHost",
      session ? session->devtools_host_handle : 0, error);
  if (validation_status != 0) {
    return validation_status;
  }
  session->devtools_host_handle = devtools_host_handle;
  session->owl_session->BindDevToolsHost(
      session->devtools_host.BindNewPipeAndPassReceiver());
  return 0;
}

extern "C" int owl_fresh_mojo_shell_execute_javascript(
    OwlFreshMojoSession* session,
    const char* script,
    char** result_json,
    char** error) {
  if (result_json) {
    *result_json = nullptr;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!script) {
    return Fail(error, "script is required");
  }
  if (!session->controller.is_bound()) {
    return Fail(error, "ShellController is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->controller->ExecuteJavaScript(
      base::UTF8ToUTF16(script),
      base::BindOnce(
          [](base::OnceClosure quit,
             int* status,
             char** result_json,
             char** error,
             base::Value result) {
            std::string json;
            if (!WriteJSON(std::move(result), &json)) {
              Fail(error, "JSONWriter failed");
              std::move(quit).Run();
              return;
            }
            Succeed(result_json, json);
            *status = 0;
            std::move(quit).Run();
          },
          loop.QuitClosure(), &status, result_json, error));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_session_flush(OwlFreshMojoSession* session,
                                             bool* ok,
                                             char** error) {
  if (error) {
    *error = nullptr;
  }
  if (ok) {
    *ok = false;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->owl_session.is_bound()) {
    return Fail(error, "OwlFreshSession is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->owl_session->Flush(base::BindOnce(
      [](base::OnceClosure quit, int* status, bool* ok, bool result) {
        if (ok) {
          *ok = result;
        }
        *status = 0;
        std::move(quit).Run();
      },
      loop.QuitClosure(), &status, ok));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_profile_get_path(OwlFreshMojoSession* session,
                                                char** path,
                                                char** error) {
  if (path) {
    *path = nullptr;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->profile.is_bound()) {
    return Fail(error, "OwlFreshProfile is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->profile->GetPath(base::BindOnce(
      [](base::OnceClosure quit,
         int* status,
         char** path,
         const std::string& result) {
        if (path) {
          *path = DuplicateCString(result);
        }
        *status = 0;
        std::move(quit).Run();
      },
      loop.QuitClosure(), &status, path));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_web_view_navigate(OwlFreshMojoSession* session,
                                                 const char* url,
                                                 char** error) {
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!url) {
    return Fail(error, "url is required");
  }
  if (!session->web_view.is_bound()) {
    return Fail(error, "OwlFreshWebView is not bound");
  }
  session->web_view->Navigate(url);
  return 0;
}

extern "C" int owl_fresh_mojo_web_view_resize(OwlFreshMojoSession* session,
                                               uint32_t width,
                                               uint32_t height,
                                               float scale,
                                               char** error) {
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->web_view.is_bound()) {
    return Fail(error, "OwlFreshWebView is not bound");
  }
  session->web_view->Resize(width, height, scale);
  return 0;
}

extern "C" int owl_fresh_mojo_web_view_set_focus(OwlFreshMojoSession* session,
                                                  bool focused,
                                                  char** error) {
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->web_view.is_bound()) {
    return Fail(error, "OwlFreshWebView is not bound");
  }
  session->web_view->SetFocus(focused);
  return 0;
}

extern "C" int owl_fresh_mojo_input_send_mouse(OwlFreshMojoSession* session,
                                                uint32_t kind,
                                                float x,
                                                float y,
                                                uint32_t button,
                                                uint32_t click_count,
                                                float delta_x,
                                                float delta_y,
                                                uint32_t modifiers,
                                                char** error) {
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->input.is_bound()) {
    return Fail(error, "OwlFreshInput is not bound");
  }
  auto event = content::mojom::OwlFreshMouseEvent::New();
  event->kind = static_cast<content::mojom::OwlFreshMouseKind>(kind);
  event->x = x;
  event->y = y;
  event->button = button;
  event->click_count = click_count;
  event->delta_x = delta_x;
  event->delta_y = delta_y;
  event->modifiers = modifiers;
  session->input->SendMouse(std::move(event));
  return 0;
}

extern "C" int owl_fresh_mojo_input_send_key(OwlFreshMojoSession* session,
                                              bool key_down,
                                              uint32_t key_code,
                                              const char* text,
                                              uint32_t modifiers,
                                              char** error) {
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->input.is_bound()) {
    return Fail(error, "OwlFreshInput is not bound");
  }
  auto event = content::mojom::OwlFreshKeyEvent::New();
  event->key_down = key_down;
  event->key_code = key_code;
  event->text = text ? text : "";
  event->modifiers = modifiers;
  session->input->SendKey(std::move(event));
  return 0;
}

extern "C" int owl_fresh_mojo_surface_tree_capture_surface_json(
    OwlFreshMojoSession* session,
    char** result_json,
    char** error) {
  if (result_json) {
    *result_json = nullptr;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->surface_tree.is_bound()) {
    return Fail(error, "OwlFreshSurfaceTreeHost is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->surface_tree->CaptureSurface(base::BindOnce(
      [](base::OnceClosure quit,
         int* status,
         char** result_json,
         char** error,
         content::mojom::OwlFreshCaptureResultPtr result) {
        if (!result) {
          Fail(error, "CaptureSurface returned no result");
          std::move(quit).Run();
          return;
        }
        base::DictValue dict;
        dict.Set("pngBase64", base::Base64Encode(base::span(result->png)));
        dict.Set("width", static_cast<int>(result->width));
        dict.Set("height", static_cast<int>(result->height));
        dict.Set("captureMode", result->capture_mode);
        dict.Set("error", result->error);
        if (WriteDictResult(std::move(dict), result_json, error) == 0) {
          *status = 0;
        }
        std::move(quit).Run();
      },
      loop.QuitClosure(), &status, result_json, error));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_surface_tree_get_json(
    OwlFreshMojoSession* session,
    char** result_json,
    char** error) {
  if (result_json) {
    *result_json = nullptr;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->surface_tree.is_bound()) {
    return Fail(error, "OwlFreshSurfaceTreeHost is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->surface_tree->GetSurfaceTree(base::BindOnce(
      [](base::OnceClosure quit,
         int* status,
         char** result_json,
         char** error,
         content::mojom::OwlFreshSurfaceTreePtr surface_tree) {
        if (WriteDictResult(SurfaceTreeToDict(surface_tree), result_json,
                            error) == 0) {
          *status = 0;
        }
        std::move(quit).Run();
      },
      loop.QuitClosure(), &status, result_json, error));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_native_surface_accept_active_popup_menu_item(
    OwlFreshMojoSession* session,
    uint32_t index,
    bool* ok,
    char** error) {
  if (ok) {
    *ok = false;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->native_surface_host.is_bound()) {
    return Fail(error, "OwlFreshNativeSurfaceHost is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->native_surface_host->AcceptActivePopupMenuItem(
      index,
      base::BindOnce(
          [](base::OnceClosure quit, int* status, bool* ok, bool result) {
            if (ok) {
              *ok = result;
            }
            *status = 0;
            std::move(quit).Run();
          },
          loop.QuitClosure(), &status, ok));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_native_surface_cancel_active_popup(
    OwlFreshMojoSession* session,
    bool* ok,
    char** error) {
  if (ok) {
    *ok = false;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->native_surface_host.is_bound()) {
    return Fail(error, "OwlFreshNativeSurfaceHost is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->native_surface_host->CancelActivePopup(base::BindOnce(
      [](base::OnceClosure quit, int* status, bool* ok, bool result) {
        if (ok) {
          *ok = result;
        }
        *status = 0;
        std::move(quit).Run();
      },
      loop.QuitClosure(), &status, ok));
  loop.Run();
  return status;
}

extern "C" int
owl_fresh_mojo_native_surface_select_active_file_picker_files_json(
    OwlFreshMojoSession* session,
    const char* paths_json,
    bool* ok,
    char** error) {
  if (ok) {
    *ok = false;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->native_surface_host.is_bound()) {
    return Fail(error, "OwlFreshNativeSurfaceHost is not bound");
  }

  std::optional<base::Value> value = base::JSONReader::Read(
      paths_json ? std::string_view(paths_json) : std::string_view("[]"),
      base::JSON_PARSE_RFC);
  if (!value || !value->is_list()) {
    return Fail(error, "file picker paths JSON must be an array");
  }
  std::vector<std::string> paths;
  for (const base::Value& item : value->GetList()) {
    if (!item.is_string()) {
      return Fail(error, "file picker paths JSON contains non-string item");
    }
    paths.push_back(item.GetString());
  }

  int status = 1;
  base::RunLoop loop;
  session->native_surface_host->SelectActiveFilePickerFiles(
      paths,
      base::BindOnce(
          [](base::OnceClosure quit, int* status, bool* ok, bool result) {
            if (ok) {
              *ok = result;
            }
            *status = 0;
            std::move(quit).Run();
          },
          loop.QuitClosure(), &status, ok));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_native_surface_cancel_active_file_picker(
    OwlFreshMojoSession* session,
    bool* ok,
    char** error) {
  if (ok) {
    *ok = false;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->native_surface_host.is_bound()) {
    return Fail(error, "OwlFreshNativeSurfaceHost is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->native_surface_host->CancelActiveFilePicker(base::BindOnce(
      [](base::OnceClosure quit, int* status, bool* ok, bool result) {
        if (ok) {
          *ok = result;
        }
        *status = 0;
        std::move(quit).Run();
      },
      loop.QuitClosure(), &status, ok));
  loop.Run();
  return status;
}


extern "C" int owl_fresh_mojo_devtools_open(OwlFreshMojoSession* session,
                                              uint32_t mode,
                                              bool* ok,
                                              char** error) {
  if (ok) {
    *ok = false;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->devtools_host.is_bound()) {
    return Fail(error, "OwlFreshDevToolsHost is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->devtools_host->OpenDevTools(
      static_cast<content::mojom::OwlFreshDevToolsMode>(mode),
      base::BindOnce(
          [](base::OnceClosure quit, int* status, bool* ok, bool result) {
            if (ok) {
              *ok = result;
            }
            *status = 0;
            std::move(quit).Run();
          },
          loop.QuitClosure(), &status, ok));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_devtools_close(OwlFreshMojoSession* session,
                                               bool* ok,
                                               char** error) {
  if (ok) {
    *ok = false;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!session->devtools_host.is_bound()) {
    return Fail(error, "OwlFreshDevToolsHost is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->devtools_host->CloseDevTools(base::BindOnce(
      [](base::OnceClosure quit, int* status, bool* ok, bool result) {
        if (ok) {
          *ok = result;
        }
        *status = 0;
        std::move(quit).Run();
      },
      loop.QuitClosure(), &status, ok));
  loop.Run();
  return status;
}

extern "C" int owl_fresh_mojo_devtools_evaluate_javascript(
    OwlFreshMojoSession* session,
    const char* script,
    char** result_json,
    char** error) {
  if (result_json) {
    *result_json = nullptr;
  }
  if (error) {
    *error = nullptr;
  }
  if (!session) {
    return Fail(error, "session is null");
  }
  if (!script) {
    return Fail(error, "script is required");
  }
  if (!session->devtools_host.is_bound()) {
    return Fail(error, "OwlFreshDevToolsHost is not bound");
  }
  int status = 1;
  base::RunLoop loop;
  session->devtools_host->EvaluateDevToolsJavaScript(
      script,
      base::BindOnce(
          [](base::OnceClosure quit,
             int* status,
             char** result_json,
             const std::string& result) {
            Succeed(result_json, result);
            *status = 0;
            std::move(quit).Run();
          },
          loop.QuitClosure(), &status, result_json));
  loop.Run();
  return status;
}

extern "C" void owl_fresh_mojo_poll_events(uint32_t timeout_ms) {
  base::RunLoop loop;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, loop.QuitClosure(), base::Milliseconds(timeout_ms));
  loop.Run();
}

extern "C" void owl_fresh_mojo_free_buffer(void* buffer) {
  std::free(buffer);
}
