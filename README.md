# OpenXWebcam

Open-source macOS app that turns a **Fujifilm camera into a webcam over USB** — no
capture card, no disabling SIP. A modern, MIT-licensed successor to Fujifilm's
abandoned "FUJIFILM X Webcam" app (a legacy CoreMediaIO **DAL** plugin that macOS 26
no longer loads).

Target hardware: **Fujifilm X-T30** (original, 2019). Target OS: **macOS 26** (Tahoe),
Apple Silicon.

## How it works

The original X-T30 has no native UVC webcam mode, so video is tunneled out over USB
using **PTP**. Instead of fighting macOS's `ptpcamerad` for the raw USB interface
(blocked by SIP), we relay PTP commands **through** Apple's sanctioned camera stack:

```
X-T30 --USB PTP-->  [Agent app]  ImageCaptureCore + requestSendPTPCommand -> decode JPEG
                          |  (IOSurface / XPC)
                          v
                  [CoreMediaIO Camera Extension]  -->  "OpenXWebcam" in Zoom/Meet/etc.
```

`ICCameraDevice.requestSendPTPCommand` relays arbitrary PTP opcodes with SIP enabled.
ImageCaptureCore is **not** available inside a CoreMediaIO extension, so the camera
work runs in a normal user-space agent that ships decoded frames to the extension.

The Fuji live-view PTP opcode sequence is a protocol fact documented in the
open-source [libgphoto2](https://github.com/gphoto/libgphoto2) ptp2 driver. No
third-party source code is reused.

## Status

Early development. **Phase 0** is a feasibility spike proving we can pull usable
live-view frames over ImageCaptureCore PTP — see [`spike/`](spike/).

## Phase 0 spike — how to run

1. Set the camera: **MENU -> Connection Setting -> PC CONNECTION MODE -> USB TETHER
   SHOOTING FIXED**, and **Auto Power Off -> OFF**. Connect it by USB and make sure
   it's awake.
2. Build and run:
   ```sh
   cd spike
   ./run.sh
   ```
3. If macOS prompts for camera access, click **Allow**. The spike enumerates the
   camera, starts Fuji live view, saves ~30 JPEG frames to `spike/frames/`, and
   prints the achievable frame rate and a VERDICT.

Success criterion: usable fps (target >=15) and clean frames. If ImageCaptureCore
refuses the Fuji opcodes, the fallback is raw IOUSBHost (still SIP-safe); if USB is
entirely unworkable, the hardware fallback is an HDMI capture card.

## License

MIT — see [LICENSE](LICENSE).
