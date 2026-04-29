#ifndef CONTENT_SHELL_BROWSER_OWL_FRESH_HOST_MAC_H_
#define CONTENT_SHELL_BROWSER_OWL_FRESH_HOST_MAC_H_

#include "base/memory/scoped_refptr.h"
#include "content/shell/common/shell_controller.test-mojom.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom-forward.h"

namespace content {

class FileSelectListener;
class RenderFrameHost;

bool OwlFreshMaybeRunFileChooser(
    RenderFrameHost* render_frame_host,
    scoped_refptr<FileSelectListener> listener,
    const blink::mojom::FileChooserParams& params);

void BindOwlFreshSessionForCurrentShell(
    mojo::PendingReceiver<mojom::OwlFreshSession> receiver);

}  // namespace content

#endif
