# OpenXWebcam

Open-source macOS app that turns a Fujifilm camera into a system webcam over USB.
No capture card, no disabling SIP. A replacement for Fujifilm's discontinued
"FUJIFILM X Webcam" app, which no longer works on current macOS.

**Status: working, pre-release.** The menu bar app streams an X-T30 into a
virtual "OpenXWebcam" camera that shows up in QuickTime, Zoom, Meet and OBS,
up to 1024×768 at ~30 fps. Resolution, quality and any settings the camera
offers over USB (film simulation, white balance, …) are adjustable from the
menu. Releases are not notarized yet, so for now you have to build and sign
the app yourself with Xcode.

## How it works

Fujifilm X cameras have no UVC webcam mode, so the video has to be pulled over
USB PTP. macOS's `ptpcamerad` normally holds the camera's USB interface; we take
it over and run the Fuji live-view sequence ourselves:

```
camera ──USB/PTP──> menu bar app ──> CMIO camera extension ──> Zoom / Meet / OBS
                    (claims the interface, starts live view,
                     decodes the JPEG stream)
```

The PTP opcode sequence is a protocol fact documented by the
[libgphoto2](https://github.com/gphoto/libgphoto2) project. No third-party
source code is reused; everything here is MIT.

## Spikes

Research code that got the protocol working, kept for reference:

- [`spike-rawusb/`](spike-rawusb/) — the working proof. Claims the interface via
  IOUSBLib, opens a PTP session, sets the camera's priority mode to USB control,
  starts live view and saves frames. Camera setup: USB MODE = `X WEBCAM`,
  Auto Power Off = OFF, data cable. Run with `./build.sh && ./run.sh`.
- [`spike/`](spike/) — earlier ImageCaptureCore attempt. Dead end: capture never
  starts while Apple's daemon co-owns the session.

## Camera support

The live-view protocol is the same across modern X and GFX bodies. The app
adapts at runtime: it reads what the connected camera advertises and only
offers settings the camera actually has.

| Camera | Status |
| --- | --- |
| X-T30 | works, tested |
| X-T1, X-T2, X-T3, X-T4, X-T5, X-Pro2, X-Pro3, X-E3, X-H1, X-H2, X-S10, X100V, X-M5, GFX 50S, GFX 50R, GFX 100, GFX 100S, GFX 100 II | expected to work — same protocol, live view confirmed by the libgphoto2 project |
| X-H2S, X-E4, X-E5, X100VI, X-T30 II, X-S20, older X bodies | should work, unconfirmed |

Have an unconfirmed body? Try it and open an issue with the output of
"Copy Diagnostics" from the menu — that's enough to add your camera to the
table.

## Troubleshooting

- Use a data-capable USB cable. Charge-only cables look like "no camera".
- Set Auto Power Off to OFF, or the camera drops off the bus mid-stream.
- After unplugging mid-session the X-T30 sometimes won't re-enumerate until
  you power it off and on with the cable connected.

## License

MIT — see [LICENSE](LICENSE).
