# OpenXWebcam

Open-source macOS app that turns a Fujifilm camera into a system webcam over USB.
No capture card, no disabling SIP. A replacement for Fujifilm's discontinued
"FUJIFILM X Webcam" app, which no longer works on current macOS.

**Status: early development.** Live view over raw USB is proven on an X-T30:
~26 fps live-view JPEG stream, pulled with our own PTP transport (see
[`spike-rawusb/`](spike-rawusb/)). The next step is the CoreMediaIO camera
extension so the camera shows up in Zoom, Meet, FaceTime and OBS.

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

Developed and tested with an X-T30. Other X and GFX bodies speak the same
protocol and are expected to work; a support table will be published once the
app is usable.

## Troubleshooting

- Use a data-capable USB cable. Charge-only cables look like "no camera".
- Set Auto Power Off to OFF, or the camera drops off the bus mid-stream.
- After unplugging mid-session the X-T30 sometimes won't re-enumerate until
  you power it off and on with the cable connected.

## License

MIT — see [LICENSE](LICENSE).
